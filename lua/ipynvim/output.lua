--- output.lua - Render cell outputs as virt_lines below code cells.
---
--- Supports MIME types (priority order):
---   image/png   -> cached PNG file + text placeholder
---   text/latex  -> mathpng (LaTeX -> PNG via Typst), with text fallback
---   text/plain  -> virt_lines with IpynvimOutput highlight
---   stream      -> same as text/plain
---   error       -> virt_lines with IpynvimError highlight
---
--- Output is rendered as virtual lines (virt_lines) on an extmark placed at
--- the code fence closing marker (```). Virtual lines are inherently read-only:
--- they cannot be selected, edited, or deleted by the user.

local M = {}

local uv = vim.uv or vim.loop

-- ---------------------------------------------------------------------------
-- Internal helpers
-- ---------------------------------------------------------------------------

local function output_ns()
  return require("ipynvim.extmarks").output_ns()
end

local function get_config()
  return require("ipynvim").get_config()
end

local _cache_dir = nil
local function cache_dir()
  if not _cache_dir then
    _cache_dir = vim.fn.stdpath("cache") .. "/ipynvim"
    vim.fn.mkdir(_cache_dir, "p")
    -- Clean up stale PNG files from previous sessions (e.g. after crash).
    -- Must be synchronous: async deletes race with new writes that reuse
    -- the same counter-based filenames (counter resets each session).
    local handle = uv.fs_scandir(_cache_dir)
    if handle then
      while true do
        local name, typ = uv.fs_scandir_next(handle)
        if not name then break end
        if (typ == "file" or not typ) and name:match("%.png$") then
          uv.fs_unlink(_cache_dir .. "/" .. name)
        end
      end
    end
  end
  return _cache_dir
end

local _img_counter = 0

-- Propagate IPYNVIM_DIRECT_TRANSMIT to luapng's kitty module so that
-- viewer.lua and other luapng consumers also use direct transmit.
if os.getenv("IPYNVIM_DIRECT_TRANSMIT") then
  local ok_kitty, k = pcall(require, "luapng.kitty")
  if ok_kitty then
    k.set_direct_transmit(true)
  end
end

local function strip_ansi(s)
  return (s:gsub("\x1b%[[%d;]*[A-Za-z]", ""):gsub("\x1b%[[%d;]*m", ""))
end

local function truncate(s, max_width)
  if #s <= max_width then
    return s
  end
  return s:sub(1, max_width - 3) .. "..."
end

--- Append a single line to virt_chunks and plain_texts.
---@param virt_chunks table[]
---@param plain_texts string[]
---@param raw_line string
---@param hl string
---@param max_width integer
local function append_line_chunk(virt_chunks, plain_texts, raw_line, hl, max_width)
  local clean = strip_ansi(raw_line)
  local display = truncate(clean, max_width)
  table.insert(virt_chunks, { { display, hl } })
  table.insert(plain_texts, clean)
end

--- Build the output separator virt_line chunk.
---@return table[] virt_chunk  Single-element array: { { sep, hl } }
local function make_output_sep()
  local sep_width = math.min(get_config().max_output_width, 40)
  return { { string.rep("\u{2504}", sep_width), "IpynvimOutputSep" } }
end

-- ---------------------------------------------------------------------------
-- Lazy module references (resolved once on first use)
-- ---------------------------------------------------------------------------

local _kitty = nil   ---@type table|false  false = not available
local _png   = nil   ---@type table|false

--- Return luapng.kitty module or nil.
local function get_kitty()
  if _kitty == nil then
    local ok, mod = pcall(require, "luapng.kitty")
    _kitty = ok and mod or false
  end
  return _kitty or nil
end

--- Return luapng.png module or nil.
local function get_png()
  if _png == nil then
    local ok, mod = pcall(require, "luapng.png")
    _png = ok and mod or false
  end
  return _png or nil
end

-- ---------------------------------------------------------------------------
-- Per-cell state (single table keyed by uuid)
-- ---------------------------------------------------------------------------

---@class InlineImage
---@field kitty_id integer
---@field img_path string
---@field transmitted boolean
---@field display_cols integer
---@field display_rows integer
---@field virt_offset integer|nil  nil until set by render()

---@class CellState
---@field mark_id integer?
---@field output_texts string[]?
---@field image_paths string[]?
---@field inline_images InlineImage[]?

---@type table<string, CellState>
local cell_states = {}

--- Get or create the cell state for a UUID.
---@param uuid string
---@return CellState
local function ensure_cell_state(uuid)
  local cs = cell_states[uuid]
  if not cs then
    cs = {}
    cell_states[uuid] = cs
  end
  return cs
end

-- Forward declaration (defined after helpers).
local set_virt_lines

-- ---------------------------------------------------------------------------
-- virt_lines builder helpers
-- ---------------------------------------------------------------------------

--- Build virt_line chunks for plain text output.
---@param text string
---@return table[] virt_chunks  Each element is { { text, hl } }
---@return string[] plain_texts  Plain text lines for yank cache
local function build_text_chunks(text)
  local cfg = get_config()
  local lines = vim.split(text, "\n", { plain = true })
  if lines[#lines] == "" then
    table.remove(lines)
  end

  local virt_chunks = {}
  local plain_texts = {}
  for i, line in ipairs(lines) do
    if i > cfg.max_output_height then
      local overflow = string.format("... (%d more lines)", #lines - cfg.max_output_height + 1)
      table.insert(virt_chunks, { { overflow, "IpynvimOutput" } })
      table.insert(plain_texts, overflow)
      break
    end
    append_line_chunk(virt_chunks, plain_texts, line, "IpynvimOutput", cfg.max_output_width)
  end

  return virt_chunks, plain_texts
end

--- Build virt_line chunks for error output.
---@param output table  Error output with ename, evalue, traceback
---@return table[] virt_chunks
---@return string[] plain_texts
local function build_error_chunks(output)
  local cfg = get_config()
  local virt_chunks = {}
  local plain_texts = {}

  local header = string.format("%s: %s", output.ename or "Error", output.evalue or "")
  append_line_chunk(virt_chunks, plain_texts, header, "IpynvimError", cfg.max_output_width)

  local traceback = output.traceback or {}
  local max_tb = math.max(0, cfg.max_output_height - 1)
  for i, tb_line in ipairs(traceback) do
    if i > max_tb then
      local overflow = string.format("... (%d more)", #traceback - max_tb)
      table.insert(virt_chunks, { { overflow, "IpynvimError" } })
      table.insert(plain_texts, overflow)
      break
    end
    append_line_chunk(virt_chunks, plain_texts, tb_line, "IpynvimError", cfg.max_output_width)
  end

  return virt_chunks, plain_texts
end

--- Build inline image spacer virt_lines. Transmission is deferred to place_images().
---@param img_path string  Absolute path to cached PNG file
---@param cell_range table  CellRange
---@return table[] virt_chunks  Empty spacer rows
---@return string[] plain_texts
local function build_inline_image(img_path, cell_range)
  local kitty = get_kitty()
  local png_mod = get_png()
  if not png_mod then
    local text = "[image/png] :IpynvimViewImage to view"
    return { { { text, "IpynvimOutputImage" } } }, { text }
  end

  local hdr = png_mod.read_header(img_path)
  if not hdr then
    local text = "[image: read error]"
    return { { { text, "IpynvimOutputImage" } } }, { text }
  end

  local cfg = get_config()
  local display_cols = math.min(cfg.max_output_width, vim.api.nvim_win_get_width(0) - 2)
  local display_rows = kitty.calc_display_rows(hdr.width, hdr.height, display_cols)
  display_rows = math.min(display_rows, cfg.max_output_height)

  local kid = kitty.next_id()

  -- Empty spacer virt_lines to reserve screen space for the image.
  local virt_chunks = {}
  for _ = 1, display_rows do
    table.insert(virt_chunks, { { "", "" } })
  end

  local cs = ensure_cell_state(cell_range.uuid)
  if not cs.inline_images then
    cs.inline_images = {}
  end
  table.insert(cs.inline_images, {
    kitty_id = kid,
    img_path = img_path,      -- transmit deferred to place_images()
    transmitted = false,
    display_cols = display_cols,
    display_rows = display_rows,
    virt_offset = nil,  -- set by render()
  })

  local text = string.format("[image/png %dx%d]", hdr.width, hdr.height)
  return virt_chunks, { text }
end

--- Decode base64 PNG, save to cache, and build virt_line chunks.
--- Uses inline mode (Kitty protocol) or placeholder text depending on config.
---@param b64_data string  Base64 encoded PNG data
---@param cell_range table  CellRange
---@return table[]|nil virt_chunks  nil on decode failure
---@return string[]|nil plain_texts
local function build_image_chunks(b64_data, cell_range)
  local ok_b64, png_bytes = pcall(vim.base64.decode, b64_data)
  if not ok_b64 or not png_bytes or #png_bytes == 0 then
    return nil, nil
  end

  _img_counter = _img_counter + 1
  local img_path = string.format("%s/%s_%d.png", cache_dir(), cell_range.uuid, _img_counter)
  local fd = uv.fs_open(img_path, "w", 384)
  if not fd then
    return nil, nil
  end
  uv.fs_write(fd, png_bytes)
  uv.fs_close(fd)

  local cs = ensure_cell_state(cell_range.uuid)
  if not cs.image_paths then
    cs.image_paths = {}
  end
  table.insert(cs.image_paths, img_path)

  -- Try inline mode via Kitty Graphics Protocol.
  local cfg = get_config()
  if cfg.image_display == "inline" then
    local kitty = get_kitty()
    if kitty and kitty.detect_protocol() then
      return build_inline_image(img_path, cell_range)
    end
  end

  -- Fallback: text placeholder.
  local size_str = ""
  local png_mod = get_png()
  if png_mod then
    local hdr = png_mod.read_header(img_path)
    if hdr then
      size_str = string.format(" %dx%d", hdr.width, hdr.height)
    end
  end

  local text = string.format("[image/png%s] :IpynvimViewImage to view", size_str)
  return { { { text, "IpynvimOutputImage" } } }, { text }
end

--- Build virt_line chunks for LaTeX output.
---@param bufnr integer
---@param cell_range table
---@param latex string
---@return table[] virt_chunks
---@return string[] plain_texts
local function build_latex_chunks(bufnr, cell_range, latex)
  local ok_mathpng, typst = pcall(require, "mathpng.typst")
  if not ok_mathpng then
    return build_text_chunks(latex)
  end

  local cfg = get_config()
  local entries = typst.prepare(
    { { math = latex, display = true } },
    {
      font_size = cfg.latex_font_size or 12,
      inline_font_size = cfg.latex_font_size or 12,
      dpi = cfg.latex_dpi or 150,
    }
  )
  local entry = entries[1]

  if entry.cached then
    local img_chunks, img_texts = build_image_chunks(
      vim.base64.encode(vim.fn.readblob(entry.cache_path)), cell_range
    )
    if img_chunks then
      return img_chunks, img_texts
    end
  end

  -- Render asynchronously; show raw LaTeX as placeholder.
  typst.render_batch({ entry }, { dpi = cfg.latex_dpi or 150 }, function(success, err)
    if not success then
      vim.notify("[ipynvim output] LaTeX render failed: " .. (err or "?"), vim.log.levels.WARN)
      return
    end
    vim.schedule(function()
      if not vim.api.nvim_buf_is_valid(bufnr) then
        return
      end
      -- Re-render with the cached image.
      local fresh_chunks, fresh_texts = build_image_chunks(
        vim.base64.encode(vim.fn.readblob(entry.cache_path)), cell_range
      )
      if fresh_chunks then
        set_virt_lines(bufnr, cell_range, fresh_chunks, fresh_texts)
      end
    end)
  end)

  return build_text_chunks(latex)
end

-- ---------------------------------------------------------------------------
-- Core: set / clear virt_lines extmarks
-- ---------------------------------------------------------------------------

--- Place or replace virt_lines on a cell's fence_end line.
---@param bufnr integer
---@param cell_range table
---@param virt_chunks table[]
---@param plain_texts string[]|nil
local function set_virt_lines(bufnr, cell_range, virt_chunks, plain_texts)
  if #virt_chunks == 0 then
    return
  end

  local ns = output_ns()
  local fence_end = cell_range.fence_end
  if not fence_end then
    return
  end

  local cs = ensure_cell_state(cell_range.uuid)

  -- Delete existing extmark if any.
  if cs.mark_id then
    pcall(vim.api.nvim_buf_del_extmark, bufnr, ns, cs.mark_id)
  end

  cs.mark_id = vim.api.nvim_buf_set_extmark(bufnr, ns, fence_end, 0, {
    virt_lines = virt_chunks,
    virt_lines_above = false,
  })

  if plain_texts then
    cs.output_texts = plain_texts
  end
end

--- Append virt_lines to an existing extmark (for streaming).
---@param bufnr integer
---@param cell_range table
---@param new_chunks table[]
---@param new_texts string[]|nil
local function append_virt_lines(bufnr, cell_range, new_chunks, new_texts)
  if #new_chunks == 0 then
    return
  end

  local uuid = cell_range.uuid
  local ns = output_ns()
  local cs = cell_states[uuid]
  local mark_id = cs and cs.mark_id

  -- Gather existing virt_lines.
  local existing = {}
  if mark_id then
    local ok, details = pcall(vim.api.nvim_buf_get_extmark_by_id, bufnr, ns, mark_id, { details = true })
    if ok and details and details[3] and details[3].virt_lines then
      existing = vim.deepcopy(details[3].virt_lines)
    end
  end

  vim.list_extend(existing, new_chunks)
  set_virt_lines(bufnr, cell_range, existing, nil)

  -- Append to text cache.
  if new_texts then
    local state = ensure_cell_state(uuid)
    if not state.output_texts then
      state.output_texts = {}
    end
    vim.list_extend(state.output_texts, new_texts)
  end
end

-- ---------------------------------------------------------------------------
-- Dispatch: build chunks for a single output object
-- ---------------------------------------------------------------------------

---@param bufnr integer
---@param cell_range table
---@param output table
---@return table[] virt_chunks
---@return string[] plain_texts
local function build_chunks_for_one(bufnr, cell_range, output)
  local t = output.type or ""

  if t == "stream" then
    return build_text_chunks(output.text or "")

  elseif t == "execute_result" or t == "display_data" then
    local data = output.data or {}
    if data["image/png"] then
      local chunks, texts = build_image_chunks(data["image/png"], cell_range)
      if chunks then
        return chunks, texts
      end
      return {}, {}
    elseif data["text/latex"] then
      local latex = type(data["text/latex"]) == "table"
        and table.concat(data["text/latex"], "")
        or tostring(data["text/latex"])
      return build_latex_chunks(bufnr, cell_range, latex)
    elseif data["text/plain"] then
      local plain = type(data["text/plain"]) == "table"
        and table.concat(data["text/plain"], "")
        or tostring(data["text/plain"])
      return build_text_chunks(plain)
    end

  elseif t == "error" then
    return build_error_chunks(output)
  end

  return {}, {}
end

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

--- Remove cached PNG files for a cell state (async, fire-and-forget).
---@param cs CellState
local function delete_cached_pngs(cs)
  if cs.image_paths then
    for _, path in ipairs(cs.image_paths) do
      uv.fs_unlink(path, function() end)
    end
  end
end

--- Clear output for a specific cell.
---@param bufnr integer
---@param cell_range table
function M.clear(bufnr, cell_range)
  local uuid = cell_range.uuid
  local cs = cell_states[uuid]
  if cs then
    if cs.mark_id then
      pcall(vim.api.nvim_buf_del_extmark, bufnr, output_ns(), cs.mark_id)
    end
    if cs.inline_images then
      local kitty = get_kitty()
      if kitty then
        for _, img in ipairs(cs.inline_images) do
          kitty.delete(img.kitty_id)
        end
      end
    end
    delete_cached_pngs(cs)
  end
  cell_states[uuid] = nil
end

--- Render all outputs for a cell (replaces any existing output).
--- Returns true if inline images were added (caller should schedule place_images).
---@param bufnr integer
---@param cell_range table
---@param outputs table[]
---@return boolean has_inline_images
function M.render(bufnr, cell_range, outputs)
  M.clear(bufnr, cell_range)
  if #outputs == 0 then
    return false
  end

  local all_chunks = { make_output_sep() }
  local all_texts = {}
  local virt_count = 1  -- output separator line

  local img_index = 1  -- tracks next inline_image needing virt_offset
  for _, output in ipairs(outputs) do
    local chunks, texts = build_chunks_for_one(bufnr, cell_range, output)
    -- Set virt_offset for any new inline images added by this output.
    local cs = cell_states[cell_range.uuid]
    if cs and cs.inline_images then
      while img_index <= #cs.inline_images and cs.inline_images[img_index].virt_offset == nil do
        cs.inline_images[img_index].virt_offset = virt_count
        img_index = img_index + 1
      end
    end
    virt_count = virt_count + #chunks
    vim.list_extend(all_chunks, chunks)
    if texts then
      vim.list_extend(all_texts, texts)
    end
  end

  set_virt_lines(bufnr, cell_range, all_chunks, all_texts)

  local cs = cell_states[cell_range.uuid]
  return cs ~= nil and cs.inline_images ~= nil and #cs.inline_images > 0
end

--- Append a single streaming output (does not clear existing).
---@param bufnr integer
---@param cell_range table
---@param output table
function M.render_stream(bufnr, cell_range, output)
  local chunks, texts = build_chunks_for_one(bufnr, cell_range, output)
  append_virt_lines(bufnr, cell_range, chunks, texts)
end

--- Delete all Kitty images from terminal memory across all cell states.
local function delete_all_kitty_images()
  local kitty = get_kitty()
  if not kitty then return end
  for _, cs in pairs(cell_states) do
    if cs.inline_images then
      for _, img in ipairs(cs.inline_images) do
        kitty.delete(img.kitty_id)
      end
    end
  end
end

--- Clear all output for a buffer.
---@param bufnr integer
function M.clear_all(bufnr)
  delete_all_kitty_images()
  for _, cs in pairs(cell_states) do
    delete_cached_pngs(cs)
  end
  local ns = output_ns()
  local marks = vim.api.nvim_buf_get_extmarks(bufnr, ns, 0, -1, {})
  for _, mark in ipairs(marks) do
    pcall(vim.api.nvim_buf_del_extmark, bufnr, ns, mark[1])
  end
  cell_states = {}
end

--- Show "Running..." indicator for a cell.
---@param bufnr integer
---@param cell_range table
function M.set_running(bufnr, cell_range)
  M.clear(bufnr, cell_range)
  set_virt_lines(bufnr, cell_range, {
    make_output_sep(),
    { { "Running...", "IpynvimExecRunning" } },
  }, nil)
end

--- Get cached image paths for a cell.
---@param uuid string
---@return string[]
function M.get_image_paths(uuid)
  local cs = cell_states[uuid]
  return (cs and cs.image_paths) or {}
end

--- Get cached output text lines for a cell (for YankOutput).
---@param uuid string
---@return string[]
function M.get_output_texts(uuid)
  local cs = cell_states[uuid]
  return (cs and cs.output_texts) or {}
end

--- Place (or re-place) all inline images at their screen positions.
--- Transmits images lazily on first placement.
--- Called after render, on WinScrolled, VimResized, and FocusGained.
---@param bufnr integer
---@param opts? { retransmit: boolean }  retransmit=true forces re-send (e.g. after terminal switch)
---@return integer placed  -1 = not applicable, 0 = placement failed, N = placed count
function M.place_images(bufnr, opts)
  if not bufnr or bufnr == 0 then
    bufnr = vim.api.nvim_get_current_buf()
  end

  local kitty = get_kitty()
  if not kitty or not kitty.detect_protocol() then
    return -1
  end

  local winid = vim.fn.bufwinid(bufnr)
  if winid == -1 then
    return -1
  end

  local retransmit = opts and opts.retransmit or false

  -- Collect cells with inline images, transmit untransmitted, and build placement list.
  -- Single pass over cell_states to avoid repeated iteration.
  local to_place = {}
  local has_images = false
  for uuid, cs in pairs(cell_states) do
    if cs.inline_images and #cs.inline_images > 0 then
      has_images = true
      for _, img in ipairs(cs.inline_images) do
        if retransmit then
          img.transmitted = false
        end
        if not img.transmitted then
          kitty.smart_transmit(img.kitty_id, img.img_path)
          img.transmitted = true
        end
      end
      to_place[uuid] = cs
    end
  end
  if not has_images then
    return -1  -- no images to place (distinct from 0 = images exist but placement failed)
  end

  kitty.sync_start()

  -- Delete and re-place in a single pass over ranges.
  local placed = 0
  local ranges = require("ipynvim.extmarks").get_ranges(bufnr)
  for _, range in ipairs(ranges) do
    if not range.fence_end then
      goto continue
    end
    local cs = to_place[range.uuid]
    if not cs then
      goto continue
    end

    -- Delete existing placements for this cell's images.
    for _, img in ipairs(cs.inline_images) do
      kitty.delete_placements(img.kitty_id)
    end

    -- Skip placement if the output area is inside a closed fold.
    local fence_end_1 = range.fence_end + 1  -- 1-indexed
    if vim.fn.foldclosed(fence_end_1) ~= -1 then
      goto continue
    end

    -- Place at current screen position.
    local pos = vim.fn.screenpos(winid, fence_end_1, 1)
    if pos.row <= 0 then
      goto continue
    end

    for _, img in ipairs(cs.inline_images) do
      local img_row = pos.row + 1 + (img.virt_offset or 0)
      kitty.place(img.kitty_id, img_row, pos.col, img.display_cols, img.display_rows)
      placed = placed + 1
    end

    ::continue::
  end

  kitty.sync_end()
  return placed
end

return M
