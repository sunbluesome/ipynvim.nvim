--- serializer.lua - Serialize NotebookModel back to .ipynb JSON
---
--- Takes the current NotebookModel (which holds outputs/metadata) and
--- fresh CellSource[] (which holds updated source from the buffer) and
--- produces a Jupyter-compatible JSON string.

local M = {}

--- Build a lookup table from cell UUID -> CellSource for efficient access.
---@param cell_sources CellSource[]
---@return table<string, CellSource>
local function build_source_map(cell_sources)
  local map = {}
  for _, cs in ipairs(cell_sources) do
    map[cs.id] = cs
  end
  return map
end

--- Produce a complete cell table suitable for JSON encoding.
--- Merges updated source with the preserved metadata/outputs.
---@param cell CellModel
---@param source_map table<string, CellSource>
---@return table
local function build_cell_table(cell, source_map)
  local cs = source_map[cell.id]
  local source = cs and cs.source or cell.source

  -- Ensure source is always an array (never nil) for valid ipynb.
  if not source then
    source = {}
  end

  local t = {
    id = cell.id,
    cell_type = cell.cell_type,
    metadata = cell.metadata or {},
    source = source,
  }

  if cell.cell_type == "code" then
    t.outputs = cell.outputs or {}
    t.execution_count = cell.execution_count
  end

  return t
end

--- Serialize a NotebookModel (with updated sources) to a pretty-printed JSON string.
---
--- Uses python3 json.dumps for pretty-printing so the output exactly matches
--- the standard Jupyter nbformat style (2-space indent, sorted keys). This
--- ensures round-trip diffs are minimal when compared against the original.
---
---@param model NotebookModel
---@param cell_sources CellSource[]  Updated source lines keyed by UUID
---@return string|nil json_str
---@return string|nil err
function M.serialize(model, cell_sources)
  local source_map = build_source_map(cell_sources)

  -- Build the top-level notebook dict.
  local notebook = {
    nbformat = model.nbformat,
    nbformat_minor = model.nbformat_minor,
    metadata = model.metadata or {},
    cells = {},
  }

  for _, cell in ipairs(model.cells) do
    table.insert(notebook.cells, build_cell_table(cell, source_map))
  end

  -- First encode with vim.json.encode to produce valid JSON, then
  -- pretty-print through python3 to match Jupyter's standard formatting.
  local ok, raw_json = pcall(vim.json.encode, notebook)
  if not ok then
    return nil, "vim.json.encode failed: " .. tostring(raw_json)
  end

  -- Pretty-print via python3.
  local result = vim.fn.system(
    { "python3", "-c", "import sys,json; d=json.load(sys.stdin); print(json.dumps(d, indent=1, sort_keys=True, ensure_ascii=False))" },
    raw_json
  )

  if vim.v.shell_error ~= 0 then
    -- Fall back to the compact JSON if python3 is unavailable.
    vim.notify("[ipynvim] python3 pretty-print failed, using compact JSON", vim.log.levels.WARN)
    return raw_json, nil
  end

  -- json.dumps does not append a trailing newline; add one for POSIX compliance.
  if result:sub(-1) ~= "\n" then
    result = result .. "\n"
  end

  return result, nil
end

return M
