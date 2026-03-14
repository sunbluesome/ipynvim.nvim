--- extmarks.lua - Extmark management for cell boundaries and decorations
---
--- Three namespaces:
---   ipynvim_cells  : one extmark per cell header line, carries cell metadata
---   ipynvim_output : virtual lines for cell output (placed at fence_end line)
---   ipynvim_decor  : header overlay decoration (separator + type badge)

local M = {}

-- Namespace IDs, created lazily once during setup().
local ns_cells = nil
local ns_output = nil
local ns_decor = nil

--- Initialise (or retrieve) the three namespaces.
--- Safe to call multiple times.
local function ensure_namespaces()
  if ns_cells then
    return
  end
  ns_cells = vim.api.nvim_create_namespace("ipynvim_cells")
  ns_output = vim.api.nvim_create_namespace("ipynvim_output")
  ns_decor = vim.api.nvim_create_namespace("ipynvim_decor")
end

--- Return the separator text for the overlay.
--- Fills the window width with a thin horizontal rule.
---@param cell_type string
---@param execution_count integer|nil
---@return table[]  virt_text chunks for nvim_buf_set_extmark
local function build_overlay_virt_text(cell_type, execution_count)
  local badge
  local badge_hl

  if cell_type == "code" then
    badge = " [code]"
    badge_hl = "IpynvimBadgeCode"
  elseif cell_type == "markdown" then
    badge = " [md]"
    badge_hl = "IpynvimBadgeMd"
  else
    badge = " [raw]"
    badge_hl = "IpynvimBadgeRaw"
  end

  local prefix = string.rep("\u{2501}", 4)  -- "━━━━"

  local chunks = {
    { prefix, "IpynvimSepLine" },
    { badge,  badge_hl },
  }

  local used = #prefix + #badge

  if cell_type == "code" and execution_count ~= nil then
    local count_str = string.format(" [%d]", execution_count)
    table.insert(chunks, { count_str, "IpynvimExecCount" })
    used = used + #count_str
  end

  local win_width = vim.api.nvim_win_get_width(0)
  local pad_len = math.max(0, win_width - used - 1)
  if pad_len > 0 then
    table.insert(chunks, { " " .. string.rep("\u{2501}", pad_len), "IpynvimSepLine" })
  end

  return chunks
end

--- Parse a `# %% <id> <type>` header line.
--- Cell IDs may contain hyphens (e.g. "cell-0-t" from nbformat 4.5 human-readable IDs).
---@param line string
---@return string|nil id
---@return string|nil cell_type
local function parse_header(line)
  local id, cell_type = line:match("^# %%%% ([%w%-]+) (%a+)$")
  return id, cell_type
end

--- Clear all extmarks in the cells and decor namespaces for bufnr.
---@param bufnr integer
local function clear_all(bufnr)
  vim.api.nvim_buf_clear_namespace(bufnr, ns_cells, 0, -1)
  vim.api.nvim_buf_clear_namespace(bufnr, ns_decor, 0, -1)
end

--- Scan the buffer for `# %%` header lines and (re)build all cell extmarks
--- and header overlay decorations.
---
---@param bufnr integer
---@param model NotebookModel  Used only to look up execution_count per cell ID
function M.rebuild(bufnr, model)
  ensure_namespaces()
  clear_all(bufnr)

  -- Build a UUID -> CellModel lookup for execution_count.
  local cell_map = {}
  for _, cell in ipairs(model.cells) do
    cell_map[cell.id] = cell
  end

  local total_lines = vim.api.nvim_buf_line_count(bufnr)
  local all_lines = vim.api.nvim_buf_get_lines(bufnr, 0, total_lines, false)

  local cell_index = 0
  for lnum, line in ipairs(all_lines) do
    local row = lnum - 1  -- 0-indexed
    local id, cell_type = parse_header(line)
    if id and cell_type then
      cell_index = cell_index + 1
      local cell = cell_map[id]
      local exec_count = cell and cell.execution_count or nil

      -- 1. Cell marker extmark: stores UUID + cell_type + cell_index as metadata.
      --    We set hl_mode = "combine" so other decorations can stack on top.
      vim.api.nvim_buf_set_extmark(bufnr, ns_cells, row, 0, {
        id = cell_index,  -- stable ID == cell_index for easy lookup
        sign_text = nil,
        hl_mode = "combine",
        -- Store extra data in the user data field (available via get_extmark_by_id).
        -- We encode it as a packed string to keep things simple.
        -- Actual data is accessed by scanning all extmarks in the namespace.
      })

      -- 2. Header overlay: conceal the raw `# %%` line and show the badge instead.
      --    For cells after the first, add a virt_line above the header for spacing
      --    (replaces the old real blank separator line).
      local overlay_chunks = build_overlay_virt_text(cell_type, exec_count)
      local decor_opts = {
        virt_text = overlay_chunks,
        virt_text_pos = "overlay",
        hl_mode = "combine",
      }
      if cell_index > 1 then
        decor_opts.virt_lines_above = true
        decor_opts.virt_lines = { { { " ", "" } } }
      end
      vim.api.nvim_buf_set_extmark(bufnr, ns_decor, row, 0, decor_opts)
    end
  end

  -- Conceal fence lines (```python, ```raw, ```) with a space overlay.
  for lnum2, line2 in ipairs(all_lines) do
    local row2 = lnum2 - 1
    if line2 == "```python" or line2 == "```raw" or line2 == "```" then
      vim.api.nvim_buf_set_extmark(bufnr, ns_decor, row2, 0, {
        virt_text = { { string.rep(" ", #line2), "" } },
        virt_text_pos = "overlay",
        hl_mode = "combine",
      })
    end
  end
end

--- Get the current CellRange[] by scanning cell extmarks and buffer content.
---
--- Because extmarks track line movements automatically, this always returns
--- up-to-date positions even after the user has inserted or deleted lines.
---
---@param bufnr integer
---@return CellRange[]
function M.get_ranges(bufnr)
  ensure_namespaces()

  local total_lines = vim.api.nvim_buf_line_count(bufnr)
  local all_lines = vim.api.nvim_buf_get_lines(bufnr, 0, total_lines, false)

  -- Collect header line numbers (0-indexed) and parse metadata.
  local headers = {}  -- { row, id, cell_type }
  for lnum, line in ipairs(all_lines) do
    local row = lnum - 1
    local id, cell_type = parse_header(line)
    if id and cell_type then
      table.insert(headers, { row = row, id = id, cell_type = cell_type })
    end
  end

  local ranges = {}
  for i, h in ipairs(headers) do
    local start_line = h.row
    -- end_line: one line before the next header, or the last line of the buffer.
    local end_line
    if i < #headers then
      end_line = math.max(start_line, headers[i + 1].row - 1)
    else
      end_line = total_lines - 1
    end

    -- Locate fence markers within the cell's line range.
    local fence_start = nil
    local fence_end = nil
    if h.cell_type == "code" or h.cell_type == "raw" then
      local fence_open = h.cell_type == "code" and "```python" or "```raw"
      for lnum = start_line + 1, end_line do
        local l = all_lines[lnum + 1]  -- all_lines is 1-indexed
        if l == fence_open and fence_start == nil then
          fence_start = lnum
        elseif l == "```" and fence_start ~= nil and fence_end == nil then
          fence_end = lnum
        end
      end
    end

    ranges[#ranges + 1] = {
      uuid = h.id,
      cell_type = h.cell_type,
      cell_index = i,
      start_line = start_line,
      end_line = end_line,
      fence_start = fence_start,
      fence_end = fence_end,
    }
  end

  return ranges
end

--- Return the 1-based cell index whose range contains the current cursor row.
--- Returns nil if the cursor is not inside any cell.
---@param bufnr integer
---@return integer|nil cell_index
function M.find_cell_at_cursor(bufnr)
  ensure_namespaces()

  local cursor_row = vim.api.nvim_win_get_cursor(0)[1] - 1  -- 0-indexed
  local ranges = M.get_ranges(bufnr)

  for _, range in ipairs(ranges) do
    if cursor_row >= range.start_line and cursor_row <= range.end_line then
      return range.cell_index
    end
  end

  return nil
end

--- Return the ns_output namespace ID so callers can place output virt_lines.
---@return integer
function M.output_ns()
  ensure_namespaces()
  return ns_output
end

--- Clear all output virt_lines for a buffer.
---@param bufnr integer
function M.clear_output(bufnr)
  ensure_namespaces()
  vim.api.nvim_buf_clear_namespace(bufnr, ns_output, 0, -1)
end

return M
