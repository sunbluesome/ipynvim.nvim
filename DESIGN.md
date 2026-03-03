# ipynvim -- Jupyter Notebook Editor for Neovim

## Context

Neovim 上で `.ipynb` ファイルを直接編集・実行するプラグイン。Jupyter kernel protocol で Python コードを実行し、出力（テキスト、画像、LaTeX 数式、エラー）をインライン表示する。既存の luapng（Kitty Graphics Protocol）と mathpng（LaTeX→PNG）に依存してリッチな出力レンダリングを実現する。

## 設計方針

- **バッファ形式**: Markdown（`filetype=markdown`）+ `# %%` セルヘッダー
- **LSP**: 自前の隠し Python バッファ（otter.nvim 不使用）、行番号 1:1 マッピング
- **セル管理**: UUID + extmark
- **REPL**: `bridge.py`（jupyter_client）← stdin/stdout JSON lines → Lua
- **出力**: `text/plain` → virt_lines, `image/png` → luapng.kitty, `text/latex` → mathpng, `error` → virt_lines

---

## ファイル構成

```
~/Projects/ipynvim/
├── plugin/
│   └── ipynvim.lua          -- BufReadCmd/BufWriteCmd + ユーザーコマンド
├── lua/ipynvim/
│   ├── init.lua             -- setup(), open(), save(), per-buffer state
│   ├── parser.lua           -- .ipynb JSON → NotebookModel
│   ├── serializer.lua       -- NotebookModel → .ipynb JSON
│   ├── buffer.lua           -- NotebookModel ↔ バッファテキスト変換
│   ├── cells.lua            -- セル操作 (追加/削除/移動/型変更)
│   ├── extmarks.lua         -- extmark 管理 (セル境界, 出力領域, 装飾)
│   ├── lsp.lua              -- 隠し Python バッファ + 診断/補完転送
│   ├── bridge.lua           -- bridge.py との通信 (jobstart + JSON lines)
│   ├── output.lua           -- MIME type 別出力レンダリング
│   └── highlight.lua        -- ハイライトグループ定義
├── python/
│   └── bridge.py            -- Jupyter kernel ブリッジ
├── doc/
│   └── ipynvim.txt
└── README.md
```

---

## 1. バッファ表現

### セルヘッダー形式

```
# %% {8桁hex UUID} {cell_type}
```

### バッファ全体の例

```markdown
# %% a1b2c3d4 markdown
## Introduction

This notebook demonstrates...

# %% e5f6g7h8 code
```python
import numpy as np
x = np.linspace(0, 2*np.pi, 100)
```
> array([0.   , 0.063, ...])         ← virt_lines (出力, バッファテキスト外)

# %% i9j0k1l2 code
```python
plt.plot(x, np.sin(x))
```
  [inline image via kitty]           ← virt_lines + kitty 画像配置
```

- code セル: ` ```python ... ``` ` で囲む → treesitter injection でハイライト
- markdown セル: そのまま markdown テキスト
- raw セル: ` ```raw ... ``` ` で囲む
- `# %%` ヘッダー行: `virt_text_pos = "overlay"` でセル境界装飾に置き換え（conceal）

### Extmark 戦略

3つの namespace:
1. **`ipynvim_cells`**: セルヘッダー行に1つずつ。UUID、cell_type、cell_index を保持
2. **`ipynvim_output`**: 出力表示用 virt_lines。コードセルの閉じ ` ``` ` 行に配置
3. **`ipynvim_decor`**: ヘッダー行の conceal/overlay、実行カウントバッジ

---

## 2. データモデル

```lua
---@class NotebookModel
---@field metadata table        -- kernelspec, language_info 等
---@field nbformat integer      -- 4
---@field nbformat_minor integer
---@field cells CellModel[]

---@class CellModel
---@field id string             -- 8桁 hex UUID
---@field cell_type string      -- "code"|"markdown"|"raw"
---@field source string[]       -- .ipynb 形式 (各行末 \n)
---@field metadata table
---@field outputs table[]       -- code セルのみ
---@field execution_count integer|nil

---@class CellRange
---@field uuid string
---@field cell_type string
---@field cell_index integer
---@field start_line integer    -- 0-indexed: # %% 行
---@field end_line integer      -- 0-indexed: セル最終行
---@field fence_start integer|nil -- ```python 行
---@field fence_end integer|nil   -- ``` 行
```

---

## 3. 隠し Python バッファ (LSP)

### 行番号保存マッピング（otter.nvim の手法）

notebook バッファと同じ行数の隠しバッファを作成。コードセル内の行だけコピーし、それ以外は空行:

```
Notebook buf (markdown)     Hidden buf (python)
─────────────────────────   ────────────────────
L1: # %% ... markdown       L1: (空)
L2: ## Heading               L2: (空)
L3:                          L3: (空)
L4: # %% ... code            L4: (空)
L5: ```python                L5: (空)
L6: import numpy as np       L6: import numpy as np   ← コピー
L7: x = np.array([1,2])     L7: x = np.array([1,2]) ← コピー
L8: ```                      L8: (空)
```

→ **行番号が 1:1 対応**。pyright の診断を行番号変換なしで notebook バッファに転送可能。

### 同期

- `nvim_buf_attach` の `on_bytes` でコードセル内の編集を検出 → 隠しバッファの同行を更新
- セル構造変更時は全体リビルド

### 診断転送

`DiagnosticChanged` autocmd で隠しバッファの診断を取得 → コードセル行のみフィルタ → `vim.diagnostic.set()` で notebook バッファに設定

### 補完転送

コードセル内でカーソルがある場合、隠しバッファの LSP クライアントに `textDocument/completion` を転送（行番号は同一なのでそのまま）。cmp source として実装。

---

## 4. bridge.py プロトコル (JSON Lines)

### 起動

```lua
vim.system({ python, bridge_path }, { stdin = true, stdout = callback })
```

### リクエスト (Lua → Python)

```json
{"id": "req_001", "method": "kernel_start", "params": {"kernel_name": "python3", "cwd": "/path"}}
{"id": "req_002", "method": "execute", "params": {"code": "print('hello')", "cell_id": "a1b2c3d4"}}
{"id": "req_003", "method": "kernel_interrupt", "params": {}}
{"id": "req_004", "method": "kernel_restart", "params": {}}
{"id": "req_005", "method": "kernel_shutdown", "params": {}}
{"id": "req_006", "method": "is_alive", "params": {}}
```

### レスポンス (Python → Lua)

ストリーミング出力は `"stream": true`:
```json
{"id": "req_002", "stream": true, "output": {"type": "status", "state": "busy"}}
{"id": "req_002", "stream": true, "output": {"type": "stream", "name": "stdout", "text": "hello\n"}}
{"id": "req_002", "stream": true, "output": {"type": "execute_result", "data": {"text/plain": ["42"]}, "execution_count": 5}}
{"id": "req_002", "stream": true, "output": {"type": "display_data", "data": {"image/png": "iVBOR..."}, "metadata": {}}}
{"id": "req_002", "stream": true, "output": {"type": "error", "ename": "ValueError", "evalue": "...", "traceback": [...]}}
{"id": "req_002", "ok": true, "result": {"execution_count": 5, "status": "ok"}}
```

### bridge.py 概要

- `jupyter_client.KernelManager` でカーネル起動/管理
- `iopub` チャンネルをバックグラウンドスレッドで監視
- `parent_header.msg_id` → `request_id` マッピングで出力をリクエストに紐付け
- stdin を1行ずつ読み、JSON デコードしてメソッドディスパッチ

---

## 5. 出力レンダリング (output.lua)

### MIME type 優先順位

`image/png` > `text/latex` > `text/plain` > `text/html`(text/plain fallback)

### text/plain, stream

virt_lines + `Comment` hl。ANSI エスケープコードは strip。

### image/png

1. base64 デコード → tmp file (`stdpath("cache")/ipynvim/`)
2. `luapng.png.read_header()` で寸法取得
3. `luapng.kitty.calc_display_rows()` で表示行数算出
4. virt_lines で空行確保（スペース予約）
5. `kitty.transmit()` + `kitty.place()` で画像配置
6. スクロール時に `kitty.delete_placements()` + `kitty.place()` で再配置

### text/latex

1. `mathpng.typst.prepare()` でキャッシュチェック
2. キャッシュヒット → PNG パスを image/png と同様に表示
3. キャッシュミス → `typst.render_batch()` で非同期レンダリング → 完了後に再表示
4. レンダリング中は raw LaTeX を virt_lines で表示

### error

virt_lines + `DiagnosticError` hl。traceback も表示。

---

## 6. round-trip シリアライゼーション

### .ipynb → バッファ (open)

```
parser.parse(path)           -- JSON → NotebookModel
buffer.to_buffer_lines(model) -- NotebookModel → string[] + CellRange[]
nvim_buf_set_lines()         -- バッファに書き込み
extmarks.rebuild()           -- セル境界 extmark 設定
output.render_all()          -- 既存出力を virt_lines + kitty で表示
lsp.create_hidden_buf()      -- 隠し Python バッファ作成
```

### バッファ → .ipynb (save)

```
extmarks.get_ranges()        -- 現在のセル境界を extmark から取得
buffer.from_buffer()         -- バッファテキスト → CellSource[]
serializer.serialize(model, cell_sources) -- NotebookModel 更新 → JSON 文字列
vim.fn.writefile()           -- ファイル書き出し
```

**保持するもの**: metadata, outputs, execution_count, cell metadata (全て NotebookModel 内に保持)
**更新するもの**: source テキスト (バッファから最新を取得)

---

## 7. コマンド・キーマップ

| キー | コマンド | 動作 |
|------|---------|------|
| `<S-CR>` / `<leader>jr` | `:IpynvimRun` | セル実行 |
| `<leader>jR` | `:IpynvimRunAll` | 全セル実行 |
| `]]` / `[[` | `:IpynvimCellNext/Prev` | セル間移動 |
| `<leader>jo` | `:IpynvimAddCodeBelow` | コードセル追加 |
| `<leader>jm` | `:IpynvimAddMdBelow` | マークダウンセル追加 |
| `<leader>jd` | `:IpynvimDeleteCell` | セル削除 |
| `<leader>jk/jj` | `:IpynvimMoveUp/Down` | セル移動 |
| `<leader>jc/jM` | `:IpynvimToCode/Markdown` | セル型変更 |
| `<leader>js` | `:IpynvimKernelStart` | カーネル起動 |
| `<leader>jq` | `:IpynvimKernelStop` | カーネル停止 |
| `<leader>ji` | `:IpynvimKernelInterrupt` | 実行中断 |
| `<leader>jv` | `:IpynvimViewImage` | 出力画像を luapng viewer で表示 |

---

## 8. 実装フェーズ

### Phase 1: .ipynb 読み書き + バッファ表現 (MVP)

**ファイル**: `plugin/ipynvim.lua`, `init.lua`, `parser.lua`, `serializer.lua`, `buffer.lua`, `extmarks.lua`, `highlight.lua`

- `.ipynb` を開く → markdown バッファに変換
- treesitter で Python + Markdown ハイライト
- `:w` で `.ipynb` に書き戻し (メタデータ・出力保持)
- `]]`/`[[` でセル間移動
- セルヘッダーの conceal 装飾

**検証**: 実際の .ipynb を開いて `:w` → diff で round-trip 確認

### Phase 2: セル操作

**ファイル**: `cells.lua`

- セル追加/削除/移動/型変更
- extmark 自動更新

### Phase 3: LSP 統合

**ファイル**: `lsp.lua`

- 隠し Python バッファ作成・同期
- 診断転送 (DiagnosticChanged)
- 補完転送 (cmp source)

### Phase 4: カーネル実行 + 出力表示

**ファイル**: `bridge.py`, `bridge.lua`, `output.lua`

- Jupyter kernel の起動/停止/再起動
- セル実行 + ストリーミング出力
- image/png → luapng.kitty, text/latex → mathpng
- 実行カウント表示, running インジケータ

---

## 9. dotfiles spec

```lua
-- nvim/lua/plugins/ipynvim.lua
return {
  dir = "~/Projects/ipynvim",
  name = "ipynvim",
  dev = true,
  dependencies = { "luapng", "mathpng" },
  cond = not vim.g.vscode,
  event = { "BufReadCmd *.ipynb", "BufNewFile *.ipynb" },
  cmd = { "IpynvimRun", "IpynvimRunAll", "IpynvimKernelStart" },
  opts = {
    max_output_width = 60,
    max_output_height = 30,
    latex_font_size = 12,
    latex_dpi = 150,
  },
  config = function(_, opts)
    require("ipynvim").setup(opts)
  end,
}
```

---

## 10. 依存関係

- **Neovim**: >= 0.10
- **luapng**: Kitty Graphics Protocol (kitty.lua, png.lua, viewer.lua)
- **mathpng**: LaTeX→PNG (typst.lua)
- **Python**: jupyter_client (`uv add jupyter-client`)
- **ターミナル**: Kitty/Ghostty/iTerm2 (画像表示用)
