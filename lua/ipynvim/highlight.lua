--- highlight.lua - Highlight group definitions for ipynvim
---
--- Defines highlight groups used for cell separators, type badges,
--- execution counts, and output decoration.

local M = {}

--- Define all highlight groups for ipynvim.
--- Called once during setup. Links to built-in groups where possible
--- so the groups adapt automatically to the user's colorscheme.
function M.setup()
  local highlights = {
    -- Cell separator line (the concealed # %% header line background)
    IpynvimCellSep = { link = "Comment" },

    -- Separator line decoration text (e.g. "─────────────────────")
    IpynvimSepLine = { link = "NonText" },

    -- Cell type badge for code cells: [code]
    IpynvimBadgeCode = { link = "Keyword" },

    -- Cell type badge for markdown cells: [md]
    IpynvimBadgeMd = { link = "String" },

    -- Cell type badge for raw cells: [raw]
    IpynvimBadgeRaw = { link = "Comment" },

    -- Execution count badge: [5]
    IpynvimExecCount = { link = "Number" },

    -- Execution count when cell is currently running: [*]
    IpynvimExecRunning = { link = "WarningMsg" },

    -- Output text (stdout / text/plain)
    IpynvimOutput = { link = "String" },

    -- Image placeholder
    IpynvimOutputImage = { link = "SpecialComment" },

    -- Error output (stderr / error type)
    IpynvimError = { link = "DiagnosticError" },

    -- Warning output
    IpynvimWarning = { link = "DiagnosticWarn" },

    -- Output separator (thin line between output and next cell)
    IpynvimOutputSep = { link = "NonText" },
  }

  for name, opts in pairs(highlights) do
    -- default = true: do not override if the user has already defined the group
    vim.api.nvim_set_hl(0, name, vim.tbl_extend("keep", opts, { default = true }))
  end
end

return M
