--- buffer.lua - Convert between NotebookModel and Neovim buffer text
---
--- Provides two public functions:
---   to_buffer_lines(model)          -> string[], CellRange[]
---   from_buffer(bufnr, cell_ranges) -> CellSource[]

local M = {}

--- CellSource is what serializer.lua consumes: a UUID + updated source lines.
---@class CellSource
---@field id string
---@field source string[]  ipynb format (each line except last ends with \n)

--- Convert a cell's ipynb source array into display lines (no trailing \n).
--- The ipynb source array has each element ending with \n except the last one.
---@param source string[]
---@return string[]
local function source_to_lines(source)
  if not source or #source == 0 then
    return {}
  end
  -- Join all source fragments then split by newline.
  local joined = table.concat(source)
  -- Strip a single trailing newline if present.
  joined = joined:gsub("\r?\n$", "")
  if joined == "" then
    return {}
  end
  return vim.split(joined, "\n", { plain = true })
end

--- Convert display lines (plain strings, no trailing \n) back to ipynb source format.
--- ipynb format: each line EXCEPT the last ends with "\n".
---@param lines string[]
---@return string[]
local function lines_to_source(lines)
  if not lines or #lines == 0 then
    return {}
  end
  local result = {}
  for i, line in ipairs(lines) do
    if i < #lines then
      result[i] = line .. "\n"
    else
      result[i] = line
    end
  end
  return result
end

--- Build the full buffer line list and CellRange table from a NotebookModel.
---@param model NotebookModel
---@return string[] lines  All buffer lines (0-indexed externally)
---@return CellRange[] ranges  One entry per cell
function M.to_buffer_lines(model)
  local lines = {}
  local ranges = {}

  for cell_index, cell in ipairs(model.cells) do
    local cell_start = #lines  -- 0-indexed start of this cell's header line

    -- Header line: # %% <id> <cell_type>
    local header = string.format("# %%%% %s %s", cell.id, cell.cell_type)
    table.insert(lines, header)

    local content_lines = source_to_lines(cell.source)

    local fence_start = nil
    local fence_end = nil

    if cell.cell_type == "code" then
      -- Wrap in ```python ... ```
      fence_start = #lines  -- 0-indexed line of ```python
      table.insert(lines, "```python")
      for _, l in ipairs(content_lines) do
        table.insert(lines, l)
      end
      fence_end = #lines  -- 0-indexed line of closing ```
      table.insert(lines, "```")

    elseif cell.cell_type == "raw" then
      -- Wrap in ```raw ... ```
      fence_start = #lines
      table.insert(lines, "```raw")
      for _, l in ipairs(content_lines) do
        table.insert(lines, l)
      end
      fence_end = #lines
      table.insert(lines, "```")

    else
      -- markdown: raw content, no fences
      for _, l in ipairs(content_lines) do
        table.insert(lines, l)
      end
    end

    local cell_end = #lines - 1  -- 0-indexed last line of this cell

    ---@type CellRange
    ranges[cell_index] = {
      uuid = cell.id,
      cell_type = cell.cell_type,
      cell_index = cell_index,
      start_line = cell_start,
      end_line = cell_end,
      fence_start = fence_start,
      fence_end = fence_end,
    }

    -- Visual spacing between cells is handled by virt_lines in extmarks.rebuild().
  end

  return lines, ranges
end

--- Extract updated source text from the buffer for each cell.
--- Reads the buffer lines within each CellRange and converts back to ipynb format.
---@param bufnr integer
---@param cell_ranges CellRange[]
---@return CellSource[]
function M.from_buffer(bufnr, cell_ranges)
  local result = {}

  for _, range in ipairs(cell_ranges) do
    local content_lines

    if range.cell_type == "code" or range.cell_type == "raw" then
      -- Content is between the fence markers (exclusive).
      if range.fence_start and range.fence_end then
        local first = range.fence_start + 1  -- line after ```python/```raw
        local last = range.fence_end - 1     -- line before closing ```
        if first <= last then
          -- nvim_buf_get_lines: end is exclusive, 0-indexed start.
          content_lines = vim.api.nvim_buf_get_lines(bufnr, first, last + 1, false)
        else
          content_lines = {}
        end
      else
        content_lines = {}
      end
    else
      -- markdown: content is from line after header to end_line.
      local first = range.start_line + 1
      local last = range.end_line
      if first <= last then
        content_lines = vim.api.nvim_buf_get_lines(bufnr, first, last + 1, false)
      else
        content_lines = {}
      end
    end

    result[#result + 1] = {
      id = range.uuid,
      source = lines_to_source(content_lines),
    }
  end

  return result
end

return M
