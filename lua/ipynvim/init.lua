--- init.lua - Main entry point for ipynvim
---
--- Provides setup(), open(), save(), cell navigation, and cell execution.
--- Per-buffer state is stored in the module-level buf_states table.

local M = {}

local parser = require("ipynvim.parser")
local buffer = require("ipynvim.buffer")
local serializer = require("ipynvim.serializer")
local extmarks = require("ipynvim.extmarks")
local highlight = require("ipynvim.highlight")
local lsp = require("ipynvim.lsp")

--- Default configuration values.
local default_config = {
  -- Maximum width (columns) for output text rendering.
  max_output_width = 80,
  -- Maximum height (rows) for output rendering.
  max_output_height = 30,
  -- Font size for LaTeX→PNG rendering (Phase 4).
  latex_font_size = 12,
  -- DPI for LaTeX→PNG rendering (Phase 4).
  latex_dpi = 150,
  -- Path to Python venv directory (relative to plugin root or absolute).
  -- e.g. ".venv", ".venv-host", "/path/to/venv"
  -- nil means use system python3.
  python_venv = nil,
  -- Image display mode: "inline" (Kitty Graphics Protocol) or "placeholder" (text only).
  image_display = "inline",
}

--- Active configuration (merged with user opts in setup()).
local config = vim.deepcopy(default_config)

--- Per-buffer state table.
--- Key: bufnr (integer)
--- Value: { model: NotebookModel, filepath: string, ranges: CellRange[] }
---@type table<integer, table>
local buf_states = {}

--- Retrieve or create the state table for a buffer.
---@param bufnr integer
---@return table
local function get_state(bufnr)
  if not buf_states[bufnr] then
    buf_states[bufnr] = {
      model = nil,
      filepath = nil,
      ranges = {},
    }
  end
  return buf_states[bufnr]
end

--- Remove state for a buffer (called when the buffer is wiped).
---@param bufnr integer
local function drop_state(bufnr)
  buf_states[bufnr] = nil
end

--- Check if a line is a cell header (# %% <id> <type>).
---@param line string
---@return boolean
local function is_header(line)
  return line:match("^# %%%% %w%w%w%w%w%w%w%w %a+$") ~= nil
end

--- Check if a line is a fence (```python, ```raw, ```).
---@param line string
---@return boolean
local function is_fence(line)
  return line == "```python" or line == "```raw" or line == "```"
end

--- Check if a line is a structural element (header or fence) that should be protected.
---@param line string
---@return boolean
local function is_structural(line)
  return is_header(line) or is_fence(line)
end

--- Convert bridge output objects to ipynb output format for model persistence.
---@param bridge_outputs table[]
---@return table[]
local function to_ipynb_outputs(bridge_outputs)
  local results = {}
  for _, out in ipairs(bridge_outputs) do
    local t = out.type or ""
    if t == "stream" then
      local text = out.text or ""
      -- ipynb stream text: array where each line except last ends with "\n".
      local split = vim.split(text, "\n", { plain = true })
      local ipynb_text = {}
      for i, ln in ipairs(split) do
        if i < #split then
          ipynb_text[i] = ln .. "\n"
        elseif ln ~= "" then
          ipynb_text[#ipynb_text + 1] = ln
        end
      end
      table.insert(results, {
        output_type = "stream",
        name = out.name or "stdout",
        text = ipynb_text,
      })
    elseif t == "execute_result" then
      table.insert(results, {
        output_type = "execute_result",
        data = out.data or {},
        metadata = {},
        execution_count = out.execution_count,
      })
    elseif t == "display_data" then
      table.insert(results, {
        output_type = "display_data",
        data = out.data or {},
        metadata = {},
      })
    elseif t == "error" then
      table.insert(results, {
        output_type = "error",
        ename = out.ename or "Error",
        evalue = out.evalue or "",
        traceback = out.traceback or {},
      })
    end
  end
  return results
end

--- Configure ipynvim with user options.
--- Must be called before the first .ipynb file is opened (typically in the
--- lazy.nvim config function).
---@param opts? table  Partial config table; merged with defaults
function M.setup(opts)
  config = vim.tbl_deep_extend("force", default_config, opts or {})
  highlight.setup()
  -- Register markdown treesitter parser for ipynb filetype.
  vim.treesitter.language.register("markdown", "ipynb")
  -- Register cmp source for LSP completion forwarding.
  local ok_cmp, cmp = pcall(require, "cmp")
  if ok_cmp then
    cmp.register_source("ipynvim_lsp", require("ipynvim.cmp_source").new())
  end
end

--- Open a .ipynb file into bufnr.
---
--- Called from the BufReadCmd autocmd. We take full ownership of reading:
--- parse the JSON, convert to buffer text, and set up extmarks.
---
---@param bufnr? integer  Defaults to the current buffer
---@param filepath? string  Defaults to the buffer's file name
function M.open(bufnr, filepath)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  filepath = filepath or vim.api.nvim_buf_get_name(bufnr)

  if filepath == "" then
    vim.notify("[ipynvim] Buffer has no associated file path", vim.log.levels.ERROR)
    return
  end

  -- Normalise to absolute path.
  filepath = vim.fn.fnamemodify(filepath, ":p")

  -- Parse the notebook file.
  local model, err = parser.parse(filepath)
  if not model then
    vim.notify("[ipynvim] Parse error: " .. (err or "unknown"), vim.log.levels.ERROR)
    return
  end

  -- Convert the model to buffer lines.
  local lines, ranges = buffer.to_buffer_lines(model)

  -- Write lines into the buffer. BufReadCmd leaves the buffer empty/modifiable.
  vim.bo[bufnr].modifiable = true
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)

  -- Clear undo history: the initial buffer population is a "read" operation and
  -- must not be undoable (undoing would empty the buffer and corrupt extmarks).
  local saved_undolevels = vim.bo[bufnr].undolevels
  vim.bo[bufnr].undolevels = -1
  vim.api.nvim_buf_set_lines(bufnr, 0, 1, false, { lines[1] })
  vim.bo[bufnr].undolevels = saved_undolevels

  -- Mark the buffer as unmodified (we just "read" it).
  vim.bo[bufnr].modified = false

  -- Set custom filetype. Treesitter uses markdown parser via language.register().
  vim.bo[bufnr].filetype = "ipynb"

  -- The .ipynb file on disk includes base64 image data, making it much larger
  -- than the actual buffer text. User configs often disable treesitter for large
  -- files (e.g. >100KB). Defer the check so FileType autocmds run first; only
  -- start treesitter ourselves if no other config has done so.
  vim.schedule(function()
    if vim.api.nvim_buf_is_valid(bufnr) and not vim.treesitter.highlighter.active[bufnr] then
      pcall(vim.treesitter.start, bufnr)
    end
  end)

  -- Augroup per buffer: clear = true prevents autocmd leaks on re-entry.
  local augroup = vim.api.nvim_create_augroup("ipynvim_buf_" .. bufnr, { clear = true })

  -- Hide line numbers on structural lines (headers, fences) via statuscolumn.
  vim.api.nvim_create_autocmd("BufWinEnter", {
    group = augroup,
    buffer = bufnr,
    once = true,
    callback = function()
      local winid = vim.fn.bufwinid(bufnr)
      if winid ~= -1 then
        vim.wo[winid].statuscolumn = "%!v:lua.require('ipynvim').statuscolumn()"
        vim.wo[winid].foldmethod = "expr"
        vim.wo[winid].foldexpr = "v:lua.require('ipynvim').foldexpr()"
      end
    end,
  })

  -- Build extmarks for cell boundaries and header overlays.
  extmarks.rebuild(bufnr, model)

  -- Render existing outputs from the notebook model.
  -- virt_lines don't modify buffer text, so order doesn't matter.
  local output = require("ipynvim.output")
  for i, cell in ipairs(model.cells) do
    if cell.cell_type == "code" and cell.outputs and #cell.outputs > 0 then
      -- Convert ipynb output format to bridge output format for rendering.
      local bridge_outputs = {}
      for _, out in ipairs(cell.outputs) do
        local o = { type = out.output_type }
        if out.output_type == "stream" then
          o.text = type(out.text) == "table" and table.concat(out.text, "") or (out.text or "")
          o.name = out.name
        elseif out.output_type == "execute_result" or out.output_type == "display_data" then
          o.data = out.data or {}
          o.execution_count = out.execution_count
        elseif out.output_type == "error" then
          o.ename = out.ename
          o.evalue = out.evalue
          o.traceback = out.traceback
        end
        table.insert(bridge_outputs, o)
      end
      output.render(bufnr, ranges[i], bridge_outputs)
    end
  end

  -- Enable mathpng for LaTeX math preview in markdown cells.
  local ok_mathpng, mathpng = pcall(require, "mathpng")
  if ok_mathpng then
    local ok, err = pcall(mathpng.enable_buffer, bufnr)
    if not ok then
      vim.notify("[ipynvim] mathpng: " .. tostring(err), vim.log.levels.WARN)
    end
  end

  -- Create hidden Python + Markdown buffers for dual LSP support.
  lsp.create(bufnr)

  -- Configure cmp to use ipynvim_lsp source for this buffer.
  local ok_cmp, cmp = pcall(require, "cmp")
  if ok_cmp then
    cmp.setup.buffer({
      sources = cmp.config.sources({
        { name = "copilot" },
        { name = "ipynvim_lsp" },
        { name = "nvim_lsp_signature_help" },
        { name = "buffer" },
        { name = "path" },
      }, {
        { name = "luasnip" },
      }),
    })
  end

  -- Set buffer-local keymaps.
  local map = function(lhs, rhs, desc)
    vim.keymap.set("n", lhs, rhs, { buffer = bufnr, desc = desc })
  end
  -- Navigation
  map("]]",          "<cmd>IpynvimCellNext<cr>",     "Next notebook cell")
  map("[[",          "<cmd>IpynvimCellPrev<cr>",     "Previous notebook cell")
  -- Cell operations
  map("<leader>jo",  "<cmd>IpynvimAddCodeBelow<cr>", "Add code cell below")
  map("<leader>jm",  "<cmd>IpynvimAddMdBelow<cr>",   "Add markdown cell below")
  map("<leader>jd",  "<cmd>IpynvimDeleteCell<cr>",   "Delete cell")
  map("<leader>jk",  "<cmd>IpynvimMoveUp<cr>",       "Move cell up")
  map("<leader>jj",  "<cmd>IpynvimMoveDown<cr>",     "Move cell down")
  map("<leader>jc",  "<cmd>IpynvimToCode<cr>",       "Convert to code cell")
  map("<leader>jM",  "<cmd>IpynvimToMarkdown<cr>",   "Convert to markdown cell")
  -- Execution
  map("<S-CR>",      "<cmd>IpynvimRun<cr>",          "Run cell")
  map("<leader>jr",  "<cmd>IpynvimRun<cr>",          "Run cell")
  map("<leader>jR",  "<cmd>IpynvimRunAll<cr>",       "Run all cells")
  -- Kernel
  map("<leader>js",  "<cmd>IpynvimKernelStart<cr>",  "Start kernel")
  map("<leader>jq",  "<cmd>IpynvimKernelStop<cr>",   "Stop kernel")
  map("<leader>ji",  "<cmd>IpynvimKernelInterrupt<cr>", "Interrupt execution")
  -- Image / Math preview
  map("<leader>jv",  "<cmd>IpynvimViewImage<cr>",    "View output image")
  map("<leader>jp",  "<cmd>IpynvimPeekMath<cr>",     "Peek math formula")
  -- Output
  map("<leader>jy",  "<cmd>IpynvimYankOutput<cr>",   "Yank cell output")

  -- Re-place inline images after fold operations (Kitty placements become stale).
  for _, key in ipairs({ "zc", "zo", "za", "zC", "zO", "zA", "zM", "zR" }) do
    map(key, function()
      pcall(vim.cmd, "normal! " .. key)
      output.place_images(bufnr)
      vim.cmd("redraw")
    end, "Fold")
  end

  -- Prevent insert mode on structural lines (headers, fences).
  vim.api.nvim_create_autocmd("InsertEnter", {
    group = augroup,
    buffer = bufnr,
    callback = function()
      local row = vim.api.nvim_win_get_cursor(0)[1]
      local line = vim.api.nvim_buf_get_lines(bufnr, row - 1, row, false)[1] or ""
      if is_structural(line) then
        vim.schedule(function()
          vim.cmd("stopinsert")
        end)
      end
    end,
  })

  -- Skip structural lines (headers, fences) when the cursor lands on them.
  -- Track previous row to detect movement direction.
  local prev_cursor_row = nil
  local skip_cursor_check = false
  vim.api.nvim_create_autocmd("CursorMoved", {
    group = augroup,
    buffer = bufnr,
    callback = function()
      if skip_cursor_check then return end
      local row = vim.api.nvim_win_get_cursor(0)[1]
      local line = vim.api.nvim_buf_get_lines(bufnr, row - 1, row, false)[1] or ""
      -- Only skip fence lines (```python, ```, ```raw). Headers show overlay
      -- badges and must be cursor-reachable for fold operations.
      if not is_fence(line) then
        prev_cursor_row = row
        return
      end
      skip_cursor_check = true
      local total = vim.api.nvim_buf_line_count(bufnr)
      local dir = (prev_cursor_row and row < prev_cursor_row) and -1 or 1
      local target = row + dir
      while target >= 1 and target <= total do
        local tline = vim.api.nvim_buf_get_lines(bufnr, target - 1, target, false)[1] or ""
        if not is_fence(tline) then
          vim.api.nvim_win_set_cursor(0, { target, 0 })
          prev_cursor_row = target
          skip_cursor_check = false
          return
        end
        target = target + dir
      end
      -- Reverse direction as fallback.
      dir = -dir
      target = row + dir
      while target >= 1 and target <= total do
        local tline = vim.api.nvim_buf_get_lines(bufnr, target - 1, target, false)[1] or ""
        if not is_fence(tline) then
          vim.api.nvim_win_set_cursor(0, { target, 0 })
          prev_cursor_row = target
          skip_cursor_check = false
          return
        end
        target = target + dir
      end
      skip_cursor_check = false
      prev_cursor_row = row
    end,
  })

  -- Re-place inline images on scroll or resize.
  vim.api.nvim_create_autocmd({ "WinScrolled", "VimResized" }, {
    group = augroup,
    buffer = bufnr,
    callback = function()
      output.place_images(bufnr)
    end,
  })

  -- Persist state.
  local state = get_state(bufnr)
  state.model = model
  state.filepath = filepath
  state.ranges = ranges

  -- Clean up state when the buffer is eventually deleted.
  vim.api.nvim_buf_attach(bufnr, false, {
    on_detach = function(_, b)
      -- Delete FocusGained autocmd (global, not buffer-local).
      local s = buf_states[b]
      if s and s.focus_au_id then
        pcall(vim.api.nvim_del_autocmd, s.focus_au_id)
      end
      -- Clear buffer-local augroup.
      pcall(vim.api.nvim_del_augroup_by_name, "ipynvim_buf_" .. b)
      output.clear_all(b)
      lsp.destroy(b)
      drop_state(b)
    end,
  })

  vim.notify(
    string.format("[ipynvim] Opened %d cells from %s", #model.cells, vim.fn.fnamemodify(filepath, ":t")),
    vim.log.levels.INFO
  )

  -- Place inline images after Neovim finishes rendering the buffer,
  -- then register FocusGained to handle terminal switch recovery.
  -- Retry if screenpos() is not ready yet (returns 0 for all images).
  -- After Kitty image operations, the terminal may send ACK responses
  -- (e.g. "\x1b_Gi=1;OK\x1b\\") that Neovim processes as keystrokes.
  -- The 'i' in the response triggers insert mode; this guard recovers from that.
  local function ensure_normal_mode()
    vim.defer_fn(function()
      if vim.api.nvim_buf_is_valid(bufnr) and vim.fn.mode():sub(1, 1) == "i" then
        vim.cmd("stopinsert")
      end
    end, 80)
  end

  local function try_place_images(attempt)
    if not vim.api.nvim_buf_is_valid(bufnr) then return end
    vim.cmd("redraw")
    local placed = output.place_images(bufnr)
    ensure_normal_mode()
    if placed == 0 and attempt < 5 then
      vim.defer_fn(function() try_place_images(attempt + 1) end, 100)
      return
    end
    -- Register FocusGained AFTER initial placement to avoid interference.
    -- FocusGained is global; check buffer manually and delay for terminal redraw.
    state.focus_au_id = vim.api.nvim_create_autocmd("FocusGained", {
      callback = function()
        if not vim.api.nvim_buf_is_valid(bufnr) then return end
        if vim.api.nvim_get_current_buf() ~= bufnr then return end
        vim.defer_fn(function()
          if vim.api.nvim_buf_is_valid(bufnr) then
            output.place_images(bufnr, { retransmit = true })
            ensure_normal_mode()
          end
        end, 50)
      end,
    })
  end
  vim.defer_fn(function() try_place_images(1) end, 100)
end

--- Save the current buffer back to its .ipynb file.
---
--- Called from the BufWriteCmd autocmd. We take full ownership of writing:
--- extract source from the buffer, merge into the model, serialise, write.
---
---@param bufnr? integer  Defaults to the current buffer
function M.save(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()

  local state = buf_states[bufnr]
  if not state or not state.model then
    vim.notify("[ipynvim] No notebook state for this buffer", vim.log.levels.ERROR)
    return
  end

  -- Get fresh cell ranges from extmarks (lines may have shifted due to edits).
  local current_ranges = extmarks.get_ranges(bufnr)

  -- Extract updated source text from buffer.
  local cell_sources = buffer.from_buffer(bufnr, current_ranges)

  -- Serialise to JSON.
  local json_str, err = serializer.serialize(state.model, cell_sources)
  if not json_str then
    vim.notify("[ipynvim] Serialization error: " .. (err or "unknown"), vim.log.levels.ERROR)
    return
  end

  -- Write to file.
  local write_lines = vim.split(json_str, "\n", { plain = true })
  -- If the last element is empty (due to trailing newline split), remove it
  -- to avoid writefile adding an extra blank line.
  if write_lines[#write_lines] == "" then
    table.remove(write_lines)
  end

  local write_ok, write_err = pcall(vim.fn.writefile, write_lines, state.filepath)
  if not write_ok then
    vim.notify("[ipynvim] Write error: " .. tostring(write_err), vim.log.levels.ERROR)
    return
  end

  -- Update cached ranges.
  state.ranges = current_ranges

  -- BufWriteCmd requires us to clear the modified flag ourselves.
  vim.bo[bufnr].modified = false

  vim.notify(
    string.format("[ipynvim] Saved %s", vim.fn.fnamemodify(state.filepath, ":t")),
    vim.log.levels.INFO
  )
end

--- Jump cursor to the content area of a cell range.
---@param bufnr integer
---@param range CellRange
local function jump_to_cell(bufnr, range)
  local target
  if range.fence_start then
    target = range.fence_start + 1  -- first line inside fence
  else
    target = range.start_line + 1   -- first line after header
  end
  local line_count = vim.api.nvim_buf_line_count(bufnr)
  if target >= line_count then
    target = range.start_line
  end
  vim.api.nvim_win_set_cursor(0, { target + 1, 0 })  -- 1-indexed
end

--- Move the cursor to the next cell.
function M.goto_next_cell()
  local bufnr = vim.api.nvim_get_current_buf()
  local ranges = extmarks.get_ranges(bufnr)
  if #ranges == 0 then
    return
  end

  local cell_index = extmarks.find_cell_at_cursor(bufnr)
  if not cell_index or cell_index >= #ranges then
    return
  end

  jump_to_cell(bufnr, ranges[cell_index + 1])
end

--- Move the cursor to the previous cell.
function M.goto_prev_cell()
  local bufnr = vim.api.nvim_get_current_buf()
  local ranges = extmarks.get_ranges(bufnr)
  if #ranges == 0 then
    return
  end

  local cell_index = extmarks.find_cell_at_cursor(bufnr)
  if not cell_index or cell_index <= 1 then
    return
  end

  jump_to_cell(bufnr, ranges[cell_index - 1])
end

--- Finalize cell execution: update model, rebuild extmarks, place images.
---@param bufnr integer
---@param output_mod table
---@param range CellRange
---@param collected table[]
---@param result table
local function finalize_execution(bufnr, output_mod, range, collected, result)
  local has_images = output_mod.render(bufnr, range, collected)
  local state = buf_states[bufnr]
  if state and state.model and state.model.cells[range.cell_index] then
    state.model.cells[range.cell_index].execution_count = result.execution_count
    state.model.cells[range.cell_index].outputs = to_ipynb_outputs(collected)
    extmarks.rebuild(bufnr, state.model)
  end
  if has_images then
    vim.schedule(function()
      if vim.api.nvim_buf_is_valid(bufnr) then
        vim.cmd("redraw")
        output_mod.place_images(bufnr)
      end
    end)
  end
end

--- Execute the code cell under the cursor.
function M.execute_cell()
  local bridge = require("ipynvim.bridge")
  local output = require("ipynvim.output")

  if not bridge.is_alive() then
    vim.notify("[ipynvim] Starting kernel...", vim.log.levels.INFO)
    bridge.start({ on_ready = function() M.execute_cell() end })
    return
  end

  local bufnr = vim.api.nvim_get_current_buf()
  local ranges = extmarks.get_ranges(bufnr)
  local cell_index = extmarks.find_cell_at_cursor(bufnr)
  if not cell_index then
    vim.notify("[ipynvim] Cursor is not inside a cell", vim.log.levels.WARN)
    return
  end

  local range = ranges[cell_index]
  if range.cell_type ~= "code" then
    vim.notify("[ipynvim] Not a code cell", vim.log.levels.WARN)
    return
  end

  -- Extract code from the buffer.
  if not range.fence_start or not range.fence_end then
    return
  end
  local code_lines = vim.api.nvim_buf_get_lines(bufnr, range.fence_start + 1, range.fence_end, false)
  local code = table.concat(code_lines, "\n")
  if code == "" then
    return
  end

  -- Show running indicator.
  output.set_running(bufnr, range)

  local state = buf_states[bufnr]
  local uuid = range.uuid

  -- Helper to find the current range by UUID (avoids stale references in callbacks).
  local function find_range()
    for _, r in ipairs(extmarks.get_ranges(bufnr)) do
      if r.uuid == uuid then
        return r
      end
    end
    return nil
  end

  -- Collect all outputs during execution for final re-render.
  local collected = {}

  bridge.execute(code, uuid, function(out)
    table.insert(collected, out)
    -- Live preview during execution.
    local r = find_range()
    if r then
      output.render_stream(bufnr, r, out)
    end
  end, function(result)
    local r = find_range()
    if r then
      finalize_execution(bufnr, output, r, collected, result)
    end
  end)
end

--- Execute all code cells in order.
function M.execute_all()
  local bridge = require("ipynvim.bridge")
  local output_mod = require("ipynvim.output")

  if not bridge.is_alive() then
    vim.notify("[ipynvim] Starting kernel...", vim.log.levels.INFO)
    bridge.start({ on_ready = function() M.execute_all() end })
    return
  end

  local bufnr = vim.api.nvim_get_current_buf()
  local ranges = extmarks.get_ranges(bufnr)
  local state = buf_states[bufnr]
  if not state or not state.model then
    return
  end

  -- Collect code cell UUIDs and their code at the time of invocation.
  local code_cells = {}
  for _, range in ipairs(ranges) do
    if range.cell_type == "code" and range.fence_start and range.fence_end then
      local code_lines = vim.api.nvim_buf_get_lines(bufnr, range.fence_start + 1, range.fence_end, false)
      local code = table.concat(code_lines, "\n")
      if code ~= "" then
        table.insert(code_cells, { uuid = range.uuid, code = code })
      end
    end
  end

  -- Execute sequentially. Re-fetch ranges in each callback to avoid stale references.
  local function run_next(i)
    if i > #code_cells then
      return
    end
    local cell = code_cells[i]

    -- Find the current range for this cell by UUID.
    local fresh_ranges = extmarks.get_ranges(bufnr)
    local range
    for _, r in ipairs(fresh_ranges) do
      if r.uuid == cell.uuid then
        range = r
        break
      end
    end
    if not range then
      run_next(i + 1)
      return
    end

    output_mod.set_running(bufnr, range)

    local collected = {}

    bridge.execute(cell.code, cell.uuid, function(out)
      table.insert(collected, out)
      local sr = extmarks.get_ranges(bufnr)
      for _, r in ipairs(sr) do
        if r.uuid == cell.uuid then
          output_mod.render_stream(bufnr, r, out)
          break
        end
      end
    end, function(result)
      local fr = extmarks.get_ranges(bufnr)
      for _, r in ipairs(fr) do
        if r.uuid == cell.uuid then
          finalize_execution(bufnr, output_mod, r, collected, result)
          break
        end
      end
      run_next(i + 1)
    end)
  end

  run_next(1)
end

--- Return the active config (read-only; callers must not mutate).
---@return table
function M.get_config()
  return config
end

--- Return the per-buffer state for external modules (e.g. cells.lua).
---@param bufnr integer
---@return table|nil
function M.get_state(bufnr)
  return buf_states[bufnr]
end

--- Custom foldexpr: each cell is one fold level (header = boundary).
--- Prevents fences from creating nested folds in code cells.
---@return string
function M.foldexpr()
  local lnum = vim.v.lnum
  local bufnr = vim.api.nvim_get_current_buf()
  local line = vim.api.nvim_buf_get_lines(bufnr, lnum - 1, lnum, false)[1] or ""
  -- Cell headers start a new fold.
  if is_header(line) then
    return ">1"
  end
  return "1"
end

--- Custom statuscolumn: hide line numbers on structural lines (headers, fences).
--- Called via statuscolumn option set in open().
---@return string
function M.statuscolumn()
  local lnum = vim.v.lnum
  local bufnr = vim.api.nvim_get_current_buf()
  local line = vim.api.nvim_buf_get_lines(bufnr, lnum - 1, lnum, false)[1] or ""
  if is_structural(line) then
    return ""
  end
  if vim.wo.number then
    local w = vim.wo.numberwidth
    local num
    if vim.wo.relativenumber then
      num = vim.v.relnum == 0 and lnum or vim.v.relnum
    else
      num = lnum
    end
    local s = tostring(num)
    local pad = w - #s
    if pad > 0 then
      return string.rep(" ", pad) .. s .. " "
    end
    return s .. " "
  end
  return ""
end

return M
