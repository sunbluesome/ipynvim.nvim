--- lsp.lua - Dual LSP support via hidden Python and Markdown buffers
---
--- Creates two hidden scratch buffers that mirror cell content from the
--- notebook buffer with a 1:1 line mapping:
---   - Python buffer (filetype "python"): code cell lines only
---   - Markdown buffer (filetype "markdown"): markdown cell lines only
---
--- Non-matching lines are empty strings so that LSP diagnostic line numbers
--- align directly with the notebook buffer without any translation.
---
--- LSP keymaps (K, gd) are routed to the appropriate hidden buffer based
--- on which cell type the cursor is in.
---
--- Public API:
---   M.create(notebook_bufnr)             -> { python, markdown }
---   M.destroy(notebook_bufnr)
---   M.get_hidden_bufnr(notebook_bufnr)   -> { python, markdown } | nil
---   M.get_active_hidden_bufnr(notebook_bufnr) -> integer | nil

local M = {}

local extmarks = require("ipynvim.extmarks")

--- Map from notebook_bufnr -> { python = bufnr, markdown = bufnr }.
---@type table<integer, { python: integer, markdown: integer }>
local state = {}

--- Diagnostic namespace used when forwarding to the notebook buffer.
local ns_diag = vim.api.nvim_create_namespace("ipynvim_diagnostics")

--- Per-buffer debounce timers for on_lines sync.
---@type table<integer, uv_timer_t>
local sync_timers = {}

--- Build the line array for a hidden buffer.
---
--- Returns a table with exactly `total_lines` entries. Lines that fall inside
--- cells of the target type are copied; all other lines are set to "".
---
---@param nb_lines string[]        All lines from the notebook buffer (1-indexed)
---@param ranges CellRange[]       Cell ranges from extmarks.get_ranges()
---@param total_lines integer      Total number of lines in the notebook buffer
---@param target_type string       "code" or "markdown"
---@return string[]                Lines for the hidden buffer
local function build_hidden_lines(nb_lines, ranges, total_lines, target_type)
  local result = {}
  for i = 1, total_lines do
    result[i] = ""
  end

  for _, range in ipairs(ranges) do
    if range.cell_type == target_type then
      if target_type == "code" and range.fence_start and range.fence_end then
        -- Copy only the Python source lines (between fence markers).
        local first = range.fence_start + 2  -- 1-indexed line after ```python
        local last  = range.fence_end        -- 1-indexed line before closing ```
        for lnum = first, last do
          if nb_lines[lnum] ~= nil then
            result[lnum] = nb_lines[lnum]
          end
        end
      elseif target_type == "markdown" then
        -- Copy markdown cell content (lines after the header).
        local first = range.start_line + 2  -- 1-indexed line after # %% header
        local last  = range.end_line + 1    -- 1-indexed
        for lnum = first, last do
          if nb_lines[lnum] ~= nil then
            result[lnum] = nb_lines[lnum]
          end
        end
      end
    end
  end

  return result
end

--- Perform a full synchronisation: rebuild a hidden buffer from scratch.
---@param notebook_bufnr integer
---@param hidden_bufnr integer
---@param target_type string  "code" or "markdown"
local function full_sync(notebook_bufnr, hidden_bufnr, target_type)
  local total_lines = vim.api.nvim_buf_line_count(notebook_bufnr)
  local nb_lines    = vim.api.nvim_buf_get_lines(notebook_bufnr, 0, total_lines, false)
  local ranges      = extmarks.get_ranges(notebook_bufnr)

  local hidden_lines = build_hidden_lines(nb_lines, ranges, total_lines, target_type)

  vim.bo[hidden_bufnr].modifiable = true
  vim.api.nvim_buf_set_lines(hidden_bufnr, 0, -1, false, hidden_lines)
end

--- Determine whether a given 0-indexed line falls inside a cell of the given type.
---@param row integer          0-indexed line number
---@param ranges CellRange[]
---@param target_type string   "code" or "markdown"
---@return boolean
local function is_target_line(row, ranges, target_type)
  for _, range in ipairs(ranges) do
    if range.cell_type == target_type then
      if target_type == "code" and range.fence_start and range.fence_end then
        if row > range.fence_start and row < range.fence_end then
          return true
        end
      elseif target_type == "markdown" then
        if row > range.start_line and row <= range.end_line then
          return true
        end
      end
    end
  end
  return false
end

--- Forward diagnostics from a hidden buffer to the notebook buffer.
---@param notebook_bufnr integer
---@param hidden_bufnr integer
---@param target_type string  "code" or "markdown"
local function forward_diagnostics(notebook_bufnr, hidden_bufnr, target_type)
  local raw_diags = vim.diagnostic.get(hidden_bufnr)
  if not raw_diags then
    return
  end

  local ranges = extmarks.get_ranges(notebook_bufnr)

  local forwarded = {}
  for _, diag in ipairs(raw_diags) do
    if is_target_line(diag.lnum, ranges, target_type) then
      local d = vim.deepcopy(diag)
      d.bufnr = notebook_bufnr
      forwarded[#forwarded + 1] = d
    end
  end

  return forwarded
end

--- Collect and set diagnostics from both hidden buffers.
---@param notebook_bufnr integer
local function update_all_diagnostics(notebook_bufnr)
  local s = state[notebook_bufnr]
  if not s then return end

  local all_diags = {}

  if s.python and vim.api.nvim_buf_is_valid(s.python) then
    local py_diags = forward_diagnostics(notebook_bufnr, s.python, "code")
    if py_diags then
      vim.list_extend(all_diags, py_diags)
    end
  end

  if s.markdown and vim.api.nvim_buf_is_valid(s.markdown) then
    local md_diags = forward_diagnostics(notebook_bufnr, s.markdown, "markdown")
    if md_diags then
      vim.list_extend(all_diags, md_diags)
    end
  end

  vim.diagnostic.set(ns_diag, notebook_bufnr, all_diags)
end

--- Create a hidden scratch buffer for a specific language.
---
--- Uses buftype=nofile so the buffer never triggers save prompts on :q.
--- LSP is started explicitly via vim.lsp.start() rather than auto-attach.
---
---@param notebook_bufnr integer
---@param filetype string  "python" or "markdown"
---@param ext string       File extension for the buffer name (".py" or ".md")
---@return integer hidden_bufnr
local function create_hidden_buf(notebook_bufnr, filetype, ext)
  local hidden_bufnr = vim.api.nvim_create_buf(false, true)  -- scratch: nofile, noswap

  -- File-path-like name so LSP URI and root_dir detection work correctly.
  local notebook_path = vim.api.nvim_buf_get_name(notebook_bufnr)
  local notebook_dir = vim.fn.fnamemodify(notebook_path, ":h")
  local buf_name = string.format("%s/.ipynvim_%d%s", notebook_dir, notebook_bufnr, ext)

  -- Evict any orphaned buffer still holding this name.  This can happen when
  -- BufReadCmd fires a second time (external edit) and LSP state was cleared
  -- without the hidden buffer being deleted (E95 guard).
  local orphan = vim.fn.bufnr(buf_name)
  if orphan ~= -1 then
    pcall(vim.api.nvim_buf_delete, orphan, { force = true })
  end

  vim.api.nvim_buf_set_name(hidden_bufnr, buf_name)

  vim.bo[hidden_bufnr].bufhidden = "wipe"

  -- Filetype for treesitter highlighting; LSP is started explicitly.
  vim.bo[hidden_bufnr].filetype = filetype

  return hidden_bufnr
end

--- Determine which hidden buffer is active based on cursor position.
---@param notebook_bufnr integer
---@return integer|nil hidden_bufnr
function M.get_active_hidden_bufnr(notebook_bufnr)
  local s = state[notebook_bufnr]
  if not s then return nil end

  local row = vim.api.nvim_win_get_cursor(0)[1] - 1  -- 0-indexed
  local ranges = extmarks.get_ranges(notebook_bufnr)

  for _, range in ipairs(ranges) do
    if row >= range.start_line and row <= range.end_line then
      if range.cell_type == "code" then return s.python end
      if range.cell_type == "markdown" then return s.markdown end
    end
  end

  return nil
end

--- Return the first ready (initialized, not stopped) LSP client on a buffer.
---@param bufnr integer
---@return table|nil client
function M.get_ready_client(bufnr)
  local clients = vim.lsp.get_clients({ bufnr = bufnr })
  if #clients == 0 then return nil end
  local client = clients[1]
  if client:is_stopped() or not client.initialized then return nil end
  return client
end

--- Sync, resolve active hidden buffer, and return ready client + position params.
--- Returns nil on any failure (no hidden buffer, no client, etc.).
---@param notebook_bufnr integer
---@return integer|nil hidden_bufnr
---@return table|nil client
---@return table|nil params
local function prepare_lsp_request(notebook_bufnr)
  M.sync_now(notebook_bufnr)
  local hidden = M.get_active_hidden_bufnr(notebook_bufnr)
  if not hidden then return nil, nil, nil end
  local client = M.get_ready_client(hidden)
  if not client then return nil, nil, nil end
  local params = vim.lsp.util.make_position_params(0, client.offset_encoding or "utf-16")
  return hidden, client, params
end

--- Set up LSP keymaps that route to the appropriate hidden buffer.
---@param notebook_bufnr integer
local function setup_lsp_keymaps(notebook_bufnr)
  -- Hover (K)
  vim.keymap.set("n", "K", function()
    local hidden, client, params = prepare_lsp_request(notebook_bufnr)
    if not hidden then return end

    vim.lsp.buf_request(hidden, "textDocument/hover", params, function(err, result)
      if err or not result or not result.contents then return end
      local contents = result.contents
      local lines
      if type(contents) == "string" then
        lines = vim.split(contents, "\n")
      elseif contents.value then
        lines = vim.split(contents.value, "\n")
      else
        return
      end
      vim.lsp.util.open_floating_preview(lines, "markdown", { border = "rounded" })
    end)
  end, { buffer = notebook_bufnr, desc = "ipynvim: LSP hover" })

  -- Go to definition (gd)
  vim.keymap.set("n", "gd", function()
    local hidden, client, params = prepare_lsp_request(notebook_bufnr)
    if not hidden then return end

    vim.lsp.buf_request(hidden, "textDocument/definition", params, function(err, result)
      if err or not result then return end
      if not vim.islist(result) then
        result = { result }
      end
      if #result == 0 then return end

      local loc = result[1]
      local target_uri = loc.uri or loc.targetUri
      if target_uri then
        local hidden_uri = vim.uri_from_bufnr(hidden)
        if target_uri == hidden_uri then
          local target_line = (loc.range or loc.targetRange).start.line
          vim.api.nvim_win_set_cursor(0, { target_line + 1, 0 })
          return
        end
      end

      vim.lsp.util.show_document(loc, client.offset_encoding or "utf-16")
    end)
  end, { buffer = notebook_bufnr, desc = "ipynvim: LSP go to definition" })
end

--- Detect Python interpreter path for pyright.
---@param root string  Project root directory
---@return string|nil python_path
local function resolve_python_path(root)
  if vim.env.NVIM_PYTHON_PATH then
    return vim.env.NVIM_PYTHON_PATH
  end
  if vim.env.VIRTUAL_ENV then
    return vim.env.VIRTUAL_ENV .. "/bin/python"
  end
  for _, name in ipairs({ ".venv", ".venv-host", "venv", ".env" }) do
    local p = root .. "/" .. name .. "/bin/python"
    if vim.uv.fs_stat(p) then
      return p
    end
  end
  local system = vim.fn.exepath("python3")
  if system ~= "" then return system end
  system = vim.fn.exepath("python")
  if system ~= "" then return system end
  return nil
end

--- Build a pyright LSP config with proper capabilities, settings, and Python path.
---
--- Priority order:
---   1. Clone config from an existing running pyright client
---   2. Read from vim.lsp.config (Neovim 0.11+)
---   3. Comprehensive fallback with capabilities, settings, Python path detection
---
---@param root string  Project root directory
---@param cmd_path string  Path to pyright-langserver binary
---@return table py_cfg  Config table for vim.lsp.start()
local function build_pyright_config(root, cmd_path)
  local py_cfg = nil

  -- Priority 1: Reuse existing pyright client's config.
  local existing = vim.lsp.get_clients({ name = "pyright" })
  if #existing > 0 then
    local ec = existing[1].config
    py_cfg = {
      name = "pyright",
      capabilities = ec.capabilities and vim.deepcopy(ec.capabilities) or nil,
      settings = ec.settings and vim.deepcopy(ec.settings) or nil,
      before_init = ec.before_init,
      on_init = ec.on_init,
    }
  end

  -- Priority 2: vim.lsp.config table.
  if not py_cfg then
    pcall(function()
      local cfg = vim.lsp.config["pyright"]
      if cfg and type(cfg) == "table" then
        py_cfg = vim.deepcopy(cfg)
      end
    end)
  end

  -- Priority 3: Comprehensive fallback.
  if not py_cfg or type(py_cfg) ~= "table" then
    local capabilities = vim.lsp.protocol.make_client_capabilities()
    pcall(function()
      local cmp_caps = require("cmp_nvim_lsp").default_capabilities()
      capabilities = vim.tbl_deep_extend("force", capabilities, cmp_caps)
    end)

    local python_path = resolve_python_path(root)

    py_cfg = {
      name = "pyright",
      capabilities = capabilities,
      settings = {
        python = {
          pythonPath = python_path,
          analysis = {
            typeCheckingMode = "basic",
            autoImportCompletions = true,
            diagnosticMode = "openFilesOnly",
            useLibraryCodeForTypes = true,
          },
        },
      },
    }
  end

  py_cfg.cmd = { cmd_path, "--stdio" }
  py_cfg.root_dir = root
  return py_cfg
end

--- Create the hidden Python and Markdown buffers for a notebook buffer.
---
---@param notebook_bufnr integer
---@return table { python: integer, markdown: integer }
function M.create(notebook_bufnr)
  if state[notebook_bufnr] then
    return state[notebook_bufnr]
  end

  local python_bufnr = create_hidden_buf(notebook_bufnr, "python", ".py")
  local markdown_bufnr = create_hidden_buf(notebook_bufnr, "markdown", ".md")

  state[notebook_bufnr] = {
    python = python_bufnr,
    markdown = markdown_bufnr,
  }

  -- Initial sync (populate content before LSP attaches).
  full_sync(notebook_bufnr, python_bufnr, "code")
  full_sync(notebook_bufnr, markdown_bufnr, "markdown")

  -- Explicitly start LSP servers on hidden buffers.
  -- vim.lsp.enable's FileType autocmd does not fire reliably for buffers
  -- created programmatically (non-current buffer). Use vim.lsp.start() directly.
  -- Defer to ensure Mason has added its bin to PATH.
  vim.defer_fn(function()
    if not vim.api.nvim_buf_is_valid(python_bufnr) then return end

    local root = vim.fs.root(notebook_bufnr, {
      "pyproject.toml", "setup.py", "setup.cfg",
      "requirements.txt", "Pipfile", "pyrightconfig.json", ".git",
    }) or vim.fn.getcwd()

    -- Resolve pyright-langserver path (Mason may not be in PATH yet).
    local cmd_path = vim.fn.exepath("pyright-langserver")
    if cmd_path == "" then
      local mason_bin = vim.fn.stdpath("data") .. "/mason/bin/pyright-langserver"
      if vim.uv.fs_stat(mason_bin) then
        cmd_path = mason_bin
      end
    end
    if cmd_path == "" then
      return  -- pyright not available
    end

    local py_cfg = build_pyright_config(root, cmd_path)

    -- Use nvim_buf_call so vim.lsp.start() sees the hidden buffer as current.
    -- This ensures client attachment and textDocument/didOpen work correctly.
    vim.api.nvim_buf_call(python_bufnr, function()
      vim.lsp.start(py_cfg)
    end)
  end, 100)

  -- Attach to notebook buffer for incremental sync (debounced).
  vim.api.nvim_buf_attach(notebook_bufnr, false, {
    on_lines = function(_, bufnr)
      local s = state[bufnr]
      if not s then
        return true  -- detach
      end

      local py_valid = vim.api.nvim_buf_is_valid(s.python)
      local md_valid = vim.api.nvim_buf_is_valid(s.markdown)
      if not py_valid and not md_valid then
        return true  -- detach
      end

      -- Debounce: batch rapid edits into one sync (reduces didChange spam).
      if sync_timers[bufnr] then
        sync_timers[bufnr]:stop()
      else
        sync_timers[bufnr] = vim.uv.new_timer()
      end
      sync_timers[bufnr]:start(80, 0, vim.schedule_wrap(function()
        if not vim.api.nvim_buf_is_valid(bufnr) then return end
        local s2 = state[bufnr]
        if not s2 then return end
        if vim.api.nvim_buf_is_valid(s2.python) then
          full_sync(bufnr, s2.python, "code")
        end
        if vim.api.nvim_buf_is_valid(s2.markdown) then
          full_sync(bufnr, s2.markdown, "markdown")
        end
      end))
    end,

    on_detach = function(_, bufnr)
      M.destroy(bufnr)
    end,
  })

  -- Forward diagnostics from both hidden buffers.
  for _, info in ipairs({
    { buf = python_bufnr, cell_type = "code" },
    { buf = markdown_bufnr, cell_type = "markdown" },
  }) do
    vim.api.nvim_create_autocmd("DiagnosticChanged", {
      buffer = info.buf,
      callback = function()
        if not vim.api.nvim_buf_is_valid(notebook_bufnr) then
          return
        end
        update_all_diagnostics(notebook_bufnr)
      end,
      desc = string.format("ipynvim: forward %s diagnostics to notebook buf %d",
        info.cell_type, notebook_bufnr),
    })
  end

  -- Set up LSP keymaps on the notebook buffer.
  setup_lsp_keymaps(notebook_bufnr)

  return state[notebook_bufnr]
end

--- Destroy hidden buffers and clean up state.
---@param notebook_bufnr integer
function M.destroy(notebook_bufnr)
  local s = state[notebook_bufnr]
  if not s then
    return
  end

  state[notebook_bufnr] = nil

  -- Clean up debounce timer.
  if sync_timers[notebook_bufnr] then
    sync_timers[notebook_bufnr]:stop()
    sync_timers[notebook_bufnr]:close()
    sync_timers[notebook_bufnr] = nil
  end

  vim.diagnostic.set(ns_diag, notebook_bufnr, {})

  -- BufUnload/BufDelete callback cannot call nvim_buf_delete directly (E565)
  local py_buf = s.python
  local md_buf = s.markdown
  vim.schedule(function()
    if py_buf and vim.api.nvim_buf_is_valid(py_buf) then
      vim.api.nvim_buf_delete(py_buf, { force = true })
    end
    if md_buf and vim.api.nvim_buf_is_valid(md_buf) then
      vim.api.nvim_buf_delete(md_buf, { force = true })
    end
  end)
end

--- Immediately sync hidden buffers, cancelling any pending debounce.
---
--- Call this before sending LSP requests (completion, hover, etc.) to ensure
--- the hidden buffer content matches the notebook buffer.
---@param notebook_bufnr integer
function M.sync_now(notebook_bufnr)
  local s = state[notebook_bufnr]
  if not s then return end

  -- Cancel pending debounce timer.
  if sync_timers[notebook_bufnr] then
    sync_timers[notebook_bufnr]:stop()
  end

  if s.python and vim.api.nvim_buf_is_valid(s.python) then
    full_sync(notebook_bufnr, s.python, "code")
  end
  if s.markdown and vim.api.nvim_buf_is_valid(s.markdown) then
    full_sync(notebook_bufnr, s.markdown, "markdown")
  end
end

--- Return the hidden buffer table for a notebook buffer, or nil.
---@param notebook_bufnr integer
---@return table|nil  { python: integer, markdown: integer }
function M.get_hidden_bufnr(notebook_bufnr)
  return state[notebook_bufnr]
end

return M
