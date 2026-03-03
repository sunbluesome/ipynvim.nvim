--- plugin/ipynvim.lua - Entry point loaded by Neovim's plugin loader
---
--- Registers BufReadCmd / BufWriteCmd autocmds for *.ipynb files and
--- creates the user-facing commands for cell navigation.
---
--- Guard against double-loading (standard Neovim plugin convention).
if vim.g.loaded_ipynvim then
  return
end
vim.g.loaded_ipynvim = true

--- BufReadCmd: Neovim fires this instead of reading the file itself.
--- We take full control: parse the .ipynb and populate the buffer.
vim.api.nvim_create_autocmd("BufReadCmd", {
  group = vim.api.nvim_create_augroup("ipynvim_read", { clear = true }),
  pattern = "*.ipynb",
  nested = true,
  callback = function(args)
    require("ipynvim").open(args.buf, args.file)
  end,
  desc = "ipynvim: open .ipynb files as editable notebook buffers",
})

--- BufWriteCmd: Neovim fires this instead of writing the file itself.
--- We take full control: serialise the buffer back to .ipynb JSON.
vim.api.nvim_create_autocmd("BufWriteCmd", {
  group = vim.api.nvim_create_augroup("ipynvim_write", { clear = true }),
  pattern = "*.ipynb",
  callback = function(args)
    require("ipynvim").save(args.buf)
  end,
  desc = "ipynvim: save .ipynb buffers back to notebook format",
})

-- Phase 1: Cell navigation
vim.api.nvim_create_user_command("IpynvimCellNext", function()
  require("ipynvim").goto_next_cell()
end, { desc = "ipynvim: move to next cell" })

vim.api.nvim_create_user_command("IpynvimCellPrev", function()
  require("ipynvim").goto_prev_cell()
end, { desc = "ipynvim: move to previous cell" })

-- Phase 2: Cell operations
vim.api.nvim_create_user_command("IpynvimAddCodeBelow", function()
  require("ipynvim.cells").add_cell_below(nil, "code")
end, { desc = "ipynvim: add code cell below" })

vim.api.nvim_create_user_command("IpynvimAddMdBelow", function()
  require("ipynvim.cells").add_cell_below(nil, "markdown")
end, { desc = "ipynvim: add markdown cell below" })

vim.api.nvim_create_user_command("IpynvimDeleteCell", function()
  require("ipynvim.cells").delete_cell()
end, { desc = "ipynvim: delete current cell" })

vim.api.nvim_create_user_command("IpynvimMoveUp", function()
  require("ipynvim.cells").move_cell_up()
end, { desc = "ipynvim: move cell up" })

vim.api.nvim_create_user_command("IpynvimMoveDown", function()
  require("ipynvim.cells").move_cell_down()
end, { desc = "ipynvim: move cell down" })

vim.api.nvim_create_user_command("IpynvimToCode", function()
  require("ipynvim.cells").change_cell_type(nil, "code")
end, { desc = "ipynvim: convert to code cell" })

vim.api.nvim_create_user_command("IpynvimToMarkdown", function()
  require("ipynvim.cells").change_cell_type(nil, "markdown")
end, { desc = "ipynvim: convert to markdown cell" })

-- Phase 4: Execution
vim.api.nvim_create_user_command("IpynvimRun", function()
  require("ipynvim").execute_cell()
end, { desc = "ipynvim: run current cell" })

vim.api.nvim_create_user_command("IpynvimRunAll", function()
  require("ipynvim").execute_all()
end, { desc = "ipynvim: run all cells" })

-- Phase 4: Kernel management
vim.api.nvim_create_user_command("IpynvimKernelStart", function()
  require("ipynvim.bridge").start()
end, { desc = "ipynvim: start Jupyter kernel" })

vim.api.nvim_create_user_command("IpynvimKernelStop", function()
  require("ipynvim.bridge").stop()
end, { desc = "ipynvim: stop Jupyter kernel" })

vim.api.nvim_create_user_command("IpynvimKernelInterrupt", function()
  require("ipynvim.bridge").interrupt()
end, { desc = "ipynvim: interrupt execution" })

vim.api.nvim_create_user_command("IpynvimKernelRestart", function()
  require("ipynvim.bridge").restart()
end, { desc = "ipynvim: restart Jupyter kernel" })

-- Math preview (peek)
vim.api.nvim_create_user_command("IpynvimPeekMath", function()
  local ok, mathpng = pcall(require, "mathpng")
  if not ok then
    vim.notify("[ipynvim] mathpng not available", vim.log.levels.WARN)
    return
  end
  mathpng.peek()
end, { desc = "ipynvim: peek math formula under cursor" })

-- Yank cell output to clipboard
vim.api.nvim_create_user_command("IpynvimYankOutput", function()
  local bufnr = vim.api.nvim_get_current_buf()
  local cell_index = require("ipynvim.extmarks").find_cell_at_cursor(bufnr)
  if not cell_index then
    vim.notify("[ipynvim] Cursor is not inside a cell", vim.log.levels.WARN)
    return
  end
  local ranges = require("ipynvim.extmarks").get_ranges(bufnr)
  local texts = require("ipynvim.output").get_output_texts(ranges[cell_index].uuid)
  if not texts or #texts == 0 then
    vim.notify("[ipynvim] No output for this cell", vim.log.levels.INFO)
    return
  end
  vim.fn.setreg("+", table.concat(texts, "\n"))
  vim.notify(string.format("[ipynvim] Yanked %d output lines", #texts), vim.log.levels.INFO)
end, { desc = "ipynvim: yank cell output to clipboard" })

-- Image viewer
vim.api.nvim_create_user_command("IpynvimViewImage", function()
  local bufnr = vim.api.nvim_get_current_buf()
  local extmarks = require("ipynvim.extmarks")
  local output = require("ipynvim.output")

  local cell_index = extmarks.find_cell_at_cursor(bufnr)
  if not cell_index then
    vim.notify("[ipynvim] Cursor is not inside a cell", vim.log.levels.WARN)
    return
  end

  local ranges = extmarks.get_ranges(bufnr)
  local range = ranges[cell_index]
  local paths = output.get_image_paths(range.uuid)
  if #paths == 0 then
    vim.notify("[ipynvim] No images for this cell", vim.log.levels.INFO)
    return
  end

  local img_path = paths[#paths]

  -- Try to read PNG header for sizing.
  local width_cells, height_cells
  local ok_png, png_mod = pcall(require, "luapng.png")
  if ok_png then
    local hdr = png_mod.read_header(img_path)
    if hdr then
      local cell_w = math.ceil(hdr.width / 8)
      local cell_h = math.ceil(hdr.height / 16)
      local max_w = math.floor(vim.o.columns * 0.8)
      local max_h = math.floor(vim.o.lines * 0.8)
      width_cells = math.min(cell_w, max_w)
      height_cells = math.min(cell_h, max_h)
    end
  end

  -- Open the most recent image using luapng viewer (float window).
  local ok_viewer, viewer = pcall(require, "luapng.viewer")
  if ok_viewer then
    viewer.open(img_path, {
      width = width_cells,
      height = height_cells,
      title = false,
      label = string.format("Cell [%d] Output", cell_index),
    })
  else
    -- Fallback: open with system viewer.
    vim.ui.open(img_path)
  end
end, { desc = "ipynvim: view cell output image" })

-- New notebook creation
vim.api.nvim_create_user_command("IpynvimNew", function(args)
  local path = args.fargs[1]
  if not path or path == "" then
    path = "Untitled.ipynb"
  end
  if not path:match("%.ipynb$") then
    path = path .. ".ipynb"
  end
  path = vim.fn.fnamemodify(path, ":p")
  if vim.fn.filereadable(path) == 1 then
    vim.notify("[ipynvim] File already exists: " .. path, vim.log.levels.ERROR)
    return
  end
  -- Copy blank template.
  local plugin_root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h:h")
  local template = plugin_root .. "/template/blank.ipynb"
  if vim.fn.filereadable(template) ~= 1 then
    vim.notify("[ipynvim] Template not found: " .. template, vim.log.levels.ERROR)
    return
  end
  vim.fn.writefile(vim.fn.readfile(template), path)
  vim.cmd("edit " .. vim.fn.fnameescape(path))
end, {
  nargs = "?",
  complete = "file",
  desc = "ipynvim: create a new empty notebook",
})
