# ipynvim

Jupyter Notebook editor for Neovim. Edit `.ipynb` files natively with cell execution, inline image display, and full LSP support.

## Features

- **Native `.ipynb` editing** -- Open and save `.ipynb` files directly. Cells are rendered as Markdown with `# %%` headers and code fences.
- **Cell execution** -- Execute cells via Jupyter kernel (`jupyter_client`). Streaming output displayed in real-time as virtual lines.
- **Inline image display** -- Render matplotlib plots and other PNG outputs directly in the terminal via Kitty Graphics Protocol. Supports Ghostty, Kitty, WezTerm, iTerm2, and cmux.
- **LaTeX math rendering** -- Render `text/latex` output to PNG via Typst (requires [mathpng](https://github.com/sunbluesome/mathpng)).
- **Dual LSP** -- Python diagnostics/completion for code cells, Markdown for markdown cells. Hidden scratch buffers with 1:1 line mapping.
- **Cell operations** -- Add, delete, move, and convert cells. All operations keep the model, buffer, and extmarks in sync.
- **Folding** -- Custom `foldexpr` for cell-level folding. Each cell collapses as a single unit.
- **Output caching** -- Yank cell output to clipboard. View images in a floating window.

## Requirements

- Neovim >= 0.10
- Python >= 3.13 with `jupyter` (`pip install jupyter`)
- Terminal with Kitty Graphics Protocol support (for inline images)

### Lua plugin dependencies

| Plugin | Purpose |
|--------|---------|
| [luapng](https://github.com/sunbluesome/luapng) | Kitty Graphics Protocol image display |
| [mathpng](https://github.com/sunbluesome/mathpng) | LaTeX math rendering via Typst |

### Optional

| Plugin | Purpose |
|--------|---------|
| [nvim-cmp](https://github.com/hrsh7th/nvim-cmp) | Completion integration |
| [nvim-treesitter](https://github.com/nvim-treesitter/nvim-treesitter) | Syntax highlighting (python, markdown parsers) |

## Installation

### lazy.nvim

```lua
{
  "sunbluesome/ipynvim",
  dependencies = { "sunbluesome/luapng", "sunbluesome/mathpng" },
  event = { "BufReadCmd *.ipynb" },
  opts = {},
  config = function(_, opts)
    require("ipynvim").setup(opts)
  end,
}
```

### Python environment

```bash
# Create venv in your project directory
cd /path/to/your/project
python3 -m venv .venv
.venv/bin/pip install jupyter
```

Then configure ipynvim to find it:

```lua
require("ipynvim").setup({
  python_venv = ".venv",  -- relative to cwd, or absolute path
})
```

Relative paths are resolved from Neovim's current working directory,
so each project can have its own `.venv` with `jupyter` installed.

If `python_venv` is not set, ipynvim uses the system `python3`.

If you use the same dotfiles on both host and Docker, you can switch automatically:

```lua
require("ipynvim").setup({
  python_venv = vim.fn.filereadable("/.dockerenv") == 1
    and nil        -- container: use system python3
    or ".venv",    -- host: use venv
})
```

## Configuration

```lua
require("ipynvim").setup({
  -- Maximum width (columns) for output text.
  max_output_width = 80,

  -- Maximum height (rows) for output.
  max_output_height = 30,

  -- Font size for LaTeX rendering.
  latex_font_size = 12,

  -- DPI for LaTeX rendering.
  latex_dpi = 150,

  -- Python venv path (relative to plugin root or absolute). nil = system python3.
  python_venv = nil,

  -- Image display mode: "inline" (Kitty Graphics Protocol) or "placeholder" (text only).
  image_display = "inline",
})
```

## Keymaps

All keymaps are buffer-local, set automatically when a `.ipynb` file is opened.

### Navigation

| Key | Description |
|-----|-------------|
| `]]` | Next cell |
| `[[` | Previous cell |

### Cell operations

| Key | Description |
|-----|-------------|
| `<leader>jo` | Add code cell below |
| `<leader>jm` | Add markdown cell below |
| `<leader>jd` | Delete cell |
| `<leader>jk` | Move cell up |
| `<leader>jj` | Move cell down |
| `<leader>jc` | Convert to code cell |
| `<leader>jM` | Convert to markdown cell |

### Execution

| Key | Description |
|-----|-------------|
| `<S-CR>` | Run cell (auto-starts kernel if needed) |
| `<leader>jr` | Run cell |
| `<leader>jR` | Run all cells |

### Kernel

| Key | Description |
|-----|-------------|
| `<leader>js` | Start kernel |
| `<leader>jq` | Stop kernel |
| `<leader>ji` | Interrupt execution |

### Output

| Key | Description |
|-----|-------------|
| `<leader>jv` | View output image (floating window) |
| `<leader>jp` | Peek math formula |
| `<leader>jy` | Yank cell output |

## Commands

| Command | Description |
|---------|-------------|
| `:IpynvimCellNext` | Move to next cell |
| `:IpynvimCellPrev` | Move to previous cell |
| `:IpynvimAddCodeBelow` | Add code cell below |
| `:IpynvimAddMdBelow` | Add markdown cell below |
| `:IpynvimDeleteCell` | Delete current cell |
| `:IpynvimMoveUp` | Move cell up |
| `:IpynvimMoveDown` | Move cell down |
| `:IpynvimToCode` | Convert to code cell |
| `:IpynvimToMarkdown` | Convert to markdown cell |
| `:IpynvimRun` | Execute current cell |
| `:IpynvimRunAll` | Execute all cells |
| `:IpynvimKernelStart` | Start Jupyter kernel |
| `:IpynvimKernelStop` | Stop kernel |
| `:IpynvimKernelInterrupt` | Interrupt execution |
| `:IpynvimKernelRestart` | Restart kernel |
| `:IpynvimViewImage` | View output image |
| `:IpynvimPeekMath` | Peek math formula |
| `:IpynvimYankOutput` | Yank cell output |

## Architecture

```
.ipynb file
    |
    v
parser.lua  --->  NotebookModel (cells, metadata, kernelspec)
    |                    |
    v                    v
buffer.lua          serializer.lua  --->  .ipynb file
    |
    v
Neovim buffer (Markdown + # %% headers + code fences)
    |
    +---> extmarks.lua   (cell boundaries, header badges, output areas)
    +---> lsp.lua        (hidden Python/Markdown buffers for diagnostics)
    +---> output.lua     (virt_lines rendering, Kitty image placement)
    +---> cells.lua      (add/delete/move/convert operations)
    +---> bridge.lua --- bridge.py --- Jupyter kernel
              (JSON Lines over stdin/stdout)
```

### Buffer format

Each cell is represented as:

```
# %% a1b2c3d4 code        <- header (concealed, shows badge)
```python                  <- fence (concealed)
print("hello")             <- content
```                        <- fence (concealed)
                           <- output (virt_lines, not in buffer)
```

Cell types: `code` (fenced with ` ```python `), `markdown` (no fences), `raw` (fenced with ` ```raw `).

### Bridge protocol

ipynvim communicates with the Jupyter kernel via `bridge.py`, a Python subprocess using JSON Lines over stdin/stdout:

```
Neovim (Lua)  <--stdin/stdout-->  bridge.py  <--ZMQ-->  Jupyter kernel
```

Streaming outputs (stdout, images, errors) are delivered via callbacks as they arrive from the kernel's IOPub channel.

## Docker / DevContainer

Kitty Graphics Protocol escape sequences pass through Docker's PTY to the host terminal, so inline image display works inside containers.

### Image transmission

ipynvim automatically detects Docker (`/.dockerenv`) and Podman (`/run/.containerenv`) and switches to inline image transmission. For other container runtimes, set `IPYNVIM_DIRECT_TRANSMIT=1`.

### Terminal detection

The host terminal must be detected for Kitty Graphics Protocol. Either forward `TERM_PROGRAM` from the host, or use luapng's `terminal` config option (recommended for containers where env var forwarding is unreliable):

```lua
require("luapng").setup({ terminal = "ghostty" })
```

### devcontainer.json

```json
{
  "remoteEnv": {
    "TERM": "${localEnv:TERM}",
    "TERM_PROGRAM": "${localEnv:TERM_PROGRAM}",
    "GHOSTTY_RESOURCES_DIR": "${localEnv:GHOSTTY_RESOURCES_DIR}"
  }
}
```

### docker-compose.yml

```yaml
environment:
  - TERM=${TERM}
  - TERM_PROGRAM=${TERM_PROGRAM}
  - GHOSTTY_RESOURCES_DIR=${GHOSTTY_RESOURCES_DIR}
```

## License

MIT
