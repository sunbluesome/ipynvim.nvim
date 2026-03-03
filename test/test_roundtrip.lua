-- test_roundtrip.lua - Headless test for ipynvim parser/buffer/serializer round-trip
--
-- Run: nvim --headless -u NONE --noplugin -l test/test_roundtrip.lua

-- Add the plugin's lua directory to the package path
local plugin_root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h:h")
package.path = plugin_root .. "/lua/?.lua;" .. plugin_root .. "/lua/?/init.lua;" .. package.path

local passed = 0
local failed = 0

local function assert_eq(got, expected, msg)
  if got == expected then
    passed = passed + 1
    print("  PASS: " .. msg)
  else
    failed = failed + 1
    print("  FAIL: " .. msg)
    print("    expected: " .. vim.inspect(expected))
    print("    got:      " .. vim.inspect(got))
  end
end

local function assert_true(val, msg)
  assert_eq(not not val, true, msg)
end

-- ============================================================
-- Test 1: Parser
-- ============================================================
print("\n=== Test: Parser ===")
local parser = require("ipynvim.parser")
local fixture = plugin_root .. "/test/fixtures/sample.ipynb"

local model, err = parser.parse(fixture)
assert_true(model ~= nil, "parser.parse returns a model")
assert_eq(err, nil, "parser.parse returns no error")
assert_eq(model.nbformat, 4, "nbformat is 4")
assert_eq(#model.cells, 4, "4 cells parsed")
assert_eq(model.cells[1].cell_type, "markdown", "cell 1 is markdown")
assert_eq(model.cells[1].id, "aabbccdd", "cell 1 id preserved")
assert_eq(model.cells[2].cell_type, "code", "cell 2 is code")
assert_eq(model.cells[2].execution_count, 1, "cell 2 execution_count is 1")
assert_eq(#model.cells[2].outputs, 1, "cell 2 has 1 output")
assert_eq(model.cells[3].id, "55667788", "cell 3 id preserved")

-- ============================================================
-- Test 2: Buffer conversion
-- ============================================================
print("\n=== Test: Buffer ===")
local buffer = require("ipynvim.buffer")

local lines, ranges = buffer.to_buffer_lines(model)
assert_true(#lines > 0, "to_buffer_lines produces lines")
assert_eq(#ranges, 4, "4 cell ranges")

-- Check that the first line is a cell header
assert_true(lines[1]:match("^# %%%% aabbccdd markdown$") ~= nil, "first line is markdown cell header")

-- Check code cell has fences
local code_range = ranges[2]
assert_eq(code_range.cell_type, "code", "range 2 is code")
assert_true(code_range.fence_start ~= nil, "code cell has fence_start")
assert_true(code_range.fence_end ~= nil, "code cell has fence_end")
-- fence_start line should be ```python (lines is 1-indexed, fence_start is 0-indexed)
assert_eq(lines[code_range.fence_start + 1], "```python", "fence_start line is ```python")
assert_eq(lines[code_range.fence_end + 1], "```", "fence_end line is ```")

-- Check separator: blank line between cells
-- Between cell 1 and cell 2 there should be a blank line
-- ranges use 0-indexed line numbers; lines[] is 1-indexed
-- cell1_end is 0-indexed -> separator is at 0-indexed (cell1_end + 1) -> 1-indexed (cell1_end + 2)
local cell1_end = ranges[1].end_line
local cell2_start = ranges[2].start_line
assert_eq(lines[cell1_end + 2], "", "blank separator between cells")
assert_eq(cell2_start, cell1_end + 2, "cell 2 starts 2 lines after cell 1 end (separator + header)")

-- ============================================================
-- Test 3: Round-trip (from_buffer)
-- ============================================================
print("\n=== Test: Round-trip from_buffer ===")

-- Create a temporary buffer to test from_buffer
local bufnr = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)

local cell_sources = buffer.from_buffer(bufnr, ranges)
assert_eq(#cell_sources, 4, "from_buffer returns 4 cell sources")

-- Check that code cell source is preserved
local code_src = cell_sources[2]
assert_eq(code_src.id, "11223344", "code cell id preserved")
assert_eq(#code_src.source, 1, "code cell has 1 source line")
assert_eq(code_src.source[1], "print('Hello, ipynvim!')", "code source text preserved")

-- Check multi-line code cell
local code_src3 = cell_sources[3]
assert_eq(#code_src3.source, 3, "cell 3 has 3 source lines")
assert_eq(code_src3.source[1], "import numpy as np\n", "cell 3 line 1")
assert_eq(code_src3.source[2], "x = np.array([1, 2, 3])\n", "cell 3 line 2")
assert_eq(code_src3.source[3], "x.sum() + 36", "cell 3 line 3 (no trailing newline)")

-- Check markdown cell
local md_src = cell_sources[1]
assert_eq(md_src.id, "aabbccdd", "markdown cell id preserved")
assert_eq(#md_src.source, 3, "markdown cell has 3 source lines")

-- ============================================================
-- Test 4: Serializer
-- ============================================================
print("\n=== Test: Serializer ===")
local serializer = require("ipynvim.serializer")

local json_str, ser_err = serializer.serialize(model, cell_sources)
assert_true(json_str ~= nil, "serializer produces output")
assert_eq(ser_err, nil, "serializer returns no error")

-- Parse the serialized JSON back
local ok, reparsed = pcall(vim.json.decode, json_str)
assert_true(ok, "serialized JSON is valid")
assert_eq(reparsed.nbformat, 4, "reparsed nbformat is 4")
assert_eq(#reparsed.cells, 4, "reparsed has 4 cells")
assert_eq(reparsed.cells[1].cell_type, "markdown", "reparsed cell 1 type")
assert_eq(reparsed.cells[2].cell_type, "code", "reparsed cell 2 type")

-- Verify outputs are preserved
assert_eq(#reparsed.cells[2].outputs, 1, "reparsed cell 2 outputs preserved")
assert_eq(reparsed.cells[2].execution_count, 1, "reparsed cell 2 execution_count preserved")
assert_eq(reparsed.cells[3].execution_count, 2, "reparsed cell 3 execution_count preserved")

-- Verify metadata is preserved
assert_true(reparsed.metadata.kernelspec ~= nil, "kernelspec metadata preserved")
assert_eq(reparsed.metadata.kernelspec.name, "python3", "kernelspec name preserved")

-- Clean up
vim.api.nvim_buf_delete(bufnr, { force = true })

-- ============================================================
-- Summary
-- ============================================================
print(string.format("\n=== Results: %d passed, %d failed ===", passed, failed))
if failed > 0 then
  vim.cmd("cquit 1")
else
  vim.cmd("qall!")
end
