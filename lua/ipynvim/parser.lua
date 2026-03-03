--- parser.lua - Parse .ipynb JSON files into NotebookModel
---
--- Reads a Jupyter notebook file and converts it into the internal
--- NotebookModel representation. Uses vim.json.decode (built-in).

local M = {}

-- Seed the RNG once at module load time.
math.randomseed(os.time())

--- Generate an 8-character hex ID suitable for a cell UUID.
---@return string
local function gen_id()
  return string.format("%08x", math.random(0, 0xFFFFFFFF))
end

--- Normalise a raw cell from the .ipynb JSON into a CellModel.
--- Generates a cell ID when the notebook does not provide one (nbformat < 4.5).
---@param raw table  Raw cell table from JSON decode
---@param index integer  1-based cell index (used for fallback ID seed)
---@return CellModel
local function normalise_cell(raw, index)
  -- nbformat 4.5+ stores "id"; older notebooks do not have it.
  local id = raw.id
  if not id or id == "" then
    id = gen_id()
  end
  -- Truncate to 8 chars in case a full UUID was stored.
  id = id:sub(1, 8)

  -- source can be a JSON array of strings or a single string.
  local source = raw.source or {}
  if type(source) == "string" then
    -- Split single string into lines, re-adding the \n that ipynb expects.
    local lines = vim.split(source, "\n", { plain = true })
    source = {}
    for i, line in ipairs(lines) do
      if i < #lines then
        table.insert(source, line .. "\n")
      elseif line ~= "" then
        -- Last line has no trailing newline in ipynb format.
        table.insert(source, line)
      end
    end
  end

  ---@type CellModel
  return {
    id = id,
    cell_type = raw.cell_type or "code",
    source = source,
    metadata = raw.metadata or {},
    outputs = raw.outputs or {},
    execution_count = raw.execution_count,
  }
end

--- Parse a .ipynb file and return a NotebookModel.
---@param filepath string  Absolute path to the .ipynb file
---@return NotebookModel|nil model
---@return string|nil err  Error message if parsing failed
function M.parse(filepath)
  -- Read the file contents.
  local lines = vim.fn.readfile(filepath)
  if not lines or #lines == 0 then
    return nil, "Failed to read file: " .. filepath
  end

  local raw_json = table.concat(lines, "\n")

  -- Decode JSON using the built-in decoder.
  local ok, decoded = pcall(vim.json.decode, raw_json, { luanil = { object = true, array = false } })
  if not ok then
    return nil, "JSON decode error: " .. tostring(decoded)
  end

  if type(decoded) ~= "table" then
    return nil, "Invalid notebook: root is not a JSON object"
  end

  -- Validate minimum structure.
  if not decoded.nbformat then
    return nil, "Invalid notebook: missing nbformat"
  end

  -- Normalise each cell.
  local raw_cells = decoded.cells or {}
  local cells = {}
  for i, raw_cell in ipairs(raw_cells) do
    cells[i] = normalise_cell(raw_cell, i)
  end

  ---@type NotebookModel
  local model = {
    metadata = decoded.metadata or {},
    nbformat = decoded.nbformat or 4,
    nbformat_minor = decoded.nbformat_minor or 0,
    cells = cells,
  }

  return model, nil
end

return M
