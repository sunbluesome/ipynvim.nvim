--- cmp_source.lua - nvim-cmp source for ipynvim LSP completion
---
--- Forwards completion requests to the hidden Python/Markdown buffer's LSP
--- based on cursor position (code cell → Python LSP, markdown cell → Markdown LSP).

local source = {}

function source.new()
  return setmetatable({}, { __index = source })
end

function source:get_keyword_pattern()
  return [[\k\+]]
end

function source:get_trigger_characters()
  return { ".", ":", "(", "[", ",", " " }
end

function source:is_available()
  local bufnr = vim.api.nvim_get_current_buf()
  return vim.bo[bufnr].filetype == "ipynb"
end

function source:complete(params, callback)
  local bufnr = vim.api.nvim_get_current_buf()
  local lsp_mod = require("ipynvim.lsp")

  -- Flush pending sync so the hidden buffer matches the latest edits.
  lsp_mod.sync_now(bufnr)

  local hidden = lsp_mod.get_active_hidden_bufnr(bufnr)
  if not hidden then
    return callback()
  end

  local client = lsp_mod.get_ready_client(hidden)
  if not client then
    return callback()
  end

  local cursor = vim.api.nvim_win_get_cursor(0)
  local row = cursor[1] - 1  -- 0-indexed
  local col = cursor[2]

  -- Build LSP completion params targeting the hidden buffer's document.
  local lsp_params = {
    textDocument = { uri = vim.uri_from_bufnr(hidden) },
    position = { line = row, character = col },
    context = {
      triggerKind = params.completion_context
        and params.completion_context.triggerKind
        or 1,
      triggerCharacter = params.completion_context
        and params.completion_context.triggerCharacter
        or nil,
    },
  }

  vim.lsp.buf_request(hidden, "textDocument/completion", lsp_params, function(err, result)
    if err or not result then
      return callback()
    end
    callback(result)
  end)
end

function source:resolve(completion_item, callback)
  local bufnr = vim.api.nvim_get_current_buf()
  local lsp_mod = require("ipynvim.lsp")
  local hidden = lsp_mod.get_active_hidden_bufnr(bufnr)
  if not hidden then
    return callback(completion_item)
  end

  local client = lsp_mod.get_ready_client(hidden)
  if not client
    or not client.server_capabilities.completionProvider
    or not client.server_capabilities.completionProvider.resolveProvider then
    return callback(completion_item)
  end

  vim.lsp.buf_request(hidden, "completionItem/resolve", completion_item, function(err, result)
    if err or not result then
      return callback(completion_item)
    end
    callback(result)
  end)
end

return source
