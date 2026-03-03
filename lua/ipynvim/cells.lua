--- cells.lua - Cell manipulation operations for ipynvim (Phase 2)
---
--- Provides add, delete, move, and type-change operations on notebook cells.
--- All operations keep the NotebookModel, buffer content, and extmarks in sync.

local M = {}

local extmarks = require("ipynvim.extmarks")
local ipynvim  = require("ipynvim")

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

--- Convert an ipynb source array to display lines (no trailing \n).
---@param source string[]
---@return string[]
local function source_to_lines(source)
  if not source or #source == 0 then
    return {}
  end
  local joined = table.concat(source):gsub("\r?\n$", "")
  if joined == "" then
    return {}
  end
  return vim.split(joined, "\n", { plain = true })
end

--- Convert display lines back to ipynb source format.
---@param lines string[]
---@return string[]
local function lines_to_source(lines)
  if not lines or #lines == 0 then
    return {}
  end
  local result = {}
  for i, line in ipairs(lines) do
    result[i] = (i < #lines) and (line .. "\n") or line
  end
  return result
end

--- Build the buffer lines that represent a single cell (no leading blank separator).
--- Returns the lines list, fence_start (0-indexed within lines), fence_end.
---@param cell CellModel
---@param base_row integer  0-indexed row where the header will land
---@return string[] lines
---@return integer|nil fence_start  0-indexed absolute row
---@return integer|nil fence_end    0-indexed absolute row
local function cell_to_lines(cell, base_row)
  local lines = {}
  local header = string.format("# %%%% %s %s", cell.id, cell.cell_type)
  table.insert(lines, header)

  local content = source_to_lines(cell.source)
  local fence_start = nil
  local fence_end   = nil

  if cell.cell_type == "code" then
    fence_start = base_row + #lines  -- absolute row of ```python
    table.insert(lines, "```python")
    for _, l in ipairs(content) do
      table.insert(lines, l)
    end
    fence_end = base_row + #lines    -- absolute row of closing ```
    table.insert(lines, "```")

  elseif cell.cell_type == "raw" then
    fence_start = base_row + #lines
    table.insert(lines, "```raw")
    for _, l in ipairs(content) do
      table.insert(lines, l)
    end
    fence_end = base_row + #lines
    table.insert(lines, "```")

  else
    for _, l in ipairs(content) do
      table.insert(lines, l)
    end
  end

  return lines, fence_start, fence_end
end

--- Resolve state and current cell range, emitting a notification on failure.
---@param bufnr integer
---@return table|nil state
---@return CellRange|nil range
---@return CellRange[]|nil ranges
local function resolve_current(bufnr)
  local state = ipynvim.get_state(bufnr)
  if not state or not state.model then
    vim.notify("[ipynvim] No notebook state for this buffer", vim.log.levels.ERROR)
    return nil, nil, nil
  end

  local ranges = extmarks.get_ranges(bufnr)
  local cell_index = extmarks.find_cell_at_cursor(bufnr)
  if not cell_index then
    vim.notify("[ipynvim] Cursor is not inside a cell", vim.log.levels.WARN)
    return nil, nil, nil
  end

  local range = ranges[cell_index]
  return state, range, ranges
end

--- Move cursor into the content area of a cell (line after header, or fence+1).
---@param range CellRange
local function jump_to_content(range)
  local target
  if range.fence_start then
    target = range.fence_start + 1  -- first line inside the fence
  else
    target = range.start_line + 1   -- first content line after header
  end
  -- Clamp to buffer length.
  local line_count = vim.api.nvim_buf_line_count(0)
  if target >= line_count then
    target = line_count - 1
  end
  vim.api.nvim_win_set_cursor(0, { target + 1, 0 })  -- nvim uses 1-indexed rows
end

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

--- Add a new empty cell below the current cell.
---@param bufnr? integer  Defaults to the current buffer
---@param cell_type? string  "code"|"markdown"|"raw" (default "code")
function M.add_cell_below(bufnr, cell_type)
  bufnr     = bufnr or vim.api.nvim_get_current_buf()
  cell_type = cell_type or "code"

  local state, range = resolve_current(bufnr)
  if not state then
    return
  end

  -- Generate new cell model.
  local new_id = string.format("%08x", math.random(0, 0xFFFFFFFF))
  ---@type CellModel
  local new_cell = {
    id              = new_id,
    cell_type       = cell_type,
    source          = {},
    metadata        = {},
    outputs         = {},
    execution_count = nil,
  }

  -- Insert into model after current cell.
  local insert_pos = range.cell_index + 1
  table.insert(state.model.cells, insert_pos, new_cell)

  -- Build buffer lines for the new cell.
  local insert_row = range.end_line + 1
  local cell_lines, _, _ = cell_to_lines(new_cell, insert_row)

  -- Insert into buffer (end is exclusive).
  vim.api.nvim_buf_set_lines(bufnr, insert_row, insert_row, false, cell_lines)

  -- Sync extmarks and cached ranges.
  extmarks.rebuild(bufnr, state.model)
  state.ranges = extmarks.get_ranges(bufnr)

  -- Move cursor into the new cell.
  local new_range = state.ranges[insert_pos]
  if new_range then
    jump_to_content(new_range)
  end
end

--- Delete the current cell. Refuses to delete the last remaining cell.
---@param bufnr? integer  Defaults to the current buffer
function M.delete_cell(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()

  local state, range, ranges = resolve_current(bufnr)
  if not state then
    return
  end

  if #state.model.cells <= 1 then
    vim.notify("[ipynvim] Cannot delete the only remaining cell", vim.log.levels.WARN)
    return
  end

  local del_start = range.start_line
  local del_end   = range.end_line

  -- Clear output state for the deleted cell.
  require("ipynvim.output").clear(bufnr, range)

  -- Remove from model.
  table.remove(state.model.cells, range.cell_index)

  -- Delete buffer lines (end is exclusive, so del_end+1).
  vim.api.nvim_buf_set_lines(bufnr, del_start, del_end + 1, false, {})

  extmarks.rebuild(bufnr, state.model)
  state.ranges = extmarks.get_ranges(bufnr)
end

--- Swap the current cell with the one above it.
---@param bufnr? integer  Defaults to the current buffer
function M.move_cell_up(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()

  local state, range, ranges = resolve_current(bufnr)
  if not state then
    return
  end

  local idx = range.cell_index
  if idx <= 1 then
    vim.notify("[ipynvim] Already at the first cell", vim.log.levels.WARN)
    return
  end

  -- Swap in model.
  local above = idx - 1
  state.model.cells[idx], state.model.cells[above] = state.model.cells[above], state.model.cells[idx]

  -- Determine the combined line range covering both cells.
  local range_above = ranges[above]
  local combined_start = range_above.start_line
  local combined_end   = range.end_line

  -- Collect lines for the two cells in new order (current cell first, then above).
  local cur_lines, _, _   = cell_to_lines(state.model.cells[above], combined_start)
  local above_lines, _, _ = cell_to_lines(state.model.cells[idx],   combined_start + #cur_lines)

  local new_lines = {}
  vim.list_extend(new_lines, cur_lines)
  vim.list_extend(new_lines, above_lines)

  vim.api.nvim_buf_set_lines(bufnr, combined_start, combined_end + 1, false, new_lines)

  extmarks.rebuild(bufnr, state.model)
  state.ranges = extmarks.get_ranges(bufnr)

  -- Follow the moved cell (now at position `above`).
  local new_range = state.ranges[above]
  if new_range then
    jump_to_content(new_range)
  end
end

--- Swap the current cell with the one below it.
---@param bufnr? integer  Defaults to the current buffer
function M.move_cell_down(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()

  local state, range, ranges = resolve_current(bufnr)
  if not state then
    return
  end

  local idx = range.cell_index
  if idx >= #ranges then
    vim.notify("[ipynvim] Already at the last cell", vim.log.levels.WARN)
    return
  end

  local below = idx + 1

  -- Swap in model.
  state.model.cells[idx], state.model.cells[below] = state.model.cells[below], state.model.cells[idx]

  local range_below    = ranges[below]
  local combined_start = range.start_line
  local combined_end   = range_below.end_line

  -- New order: below cell first, then current cell.
  local below_lines, _, _ = cell_to_lines(state.model.cells[idx],   combined_start)
  local cur_lines, _, _   = cell_to_lines(state.model.cells[below],  combined_start + #below_lines)

  local new_lines = {}
  vim.list_extend(new_lines, below_lines)
  vim.list_extend(new_lines, cur_lines)

  vim.api.nvim_buf_set_lines(bufnr, combined_start, combined_end + 1, false, new_lines)

  extmarks.rebuild(bufnr, state.model)
  state.ranges = extmarks.get_ranges(bufnr)

  -- Follow the moved cell (now at position `below`).
  local new_range = state.ranges[below]
  if new_range then
    jump_to_content(new_range)
  end
end

--- Change the type of the current cell, adjusting buffer fences as needed.
---@param bufnr? integer  Defaults to the current buffer
---@param new_type string  "code"|"markdown"|"raw"
function M.change_cell_type(bufnr, new_type)
  bufnr = bufnr or vim.api.nvim_get_current_buf()

  local state, range = resolve_current(bufnr)
  if not state then
    return
  end

  local old_type = range.cell_type
  if old_type == new_type then
    return
  end

  local cell = state.model.cells[range.cell_index]

  -- Extract current content from the buffer.
  local content_lines
  if old_type == "code" or old_type == "raw" then
    if range.fence_start and range.fence_end then
      local first = range.fence_start + 1
      local last  = range.fence_end - 1
      if first <= last then
        content_lines = vim.api.nvim_buf_get_lines(bufnr, first, last + 1, false)
      else
        content_lines = {}
      end
    else
      content_lines = {}
    end
  else
    -- markdown: content after header
    local first = range.start_line + 1
    local last  = range.end_line
    if first <= last then
      content_lines = vim.api.nvim_buf_get_lines(bufnr, first, last + 1, false)
    else
      content_lines = {}
    end
  end

  -- Update model.
  cell.cell_type = new_type
  cell.source    = lines_to_source(content_lines)

  -- Rebuild buffer lines for just this cell.
  local new_cell_lines, _, _ = cell_to_lines(cell, range.start_line)

  vim.api.nvim_buf_set_lines(bufnr, range.start_line, range.end_line + 1, false, new_cell_lines)

  extmarks.rebuild(bufnr, state.model)
  state.ranges = extmarks.get_ranges(bufnr)
end

return M
