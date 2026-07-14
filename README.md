# lvim-indent

Indent guides that know what you are inside of — every indent level drawn (including through blank lines), the enclosing scope lit, and, optionally, the scope's **shape** drawn as a chunk bracket. One decoration provider paints only the visible lines, at true display columns, themed live from the lvim-utils palette.

[![License: BSD-3-Clause](https://img.shields.io/badge/License-BSD--3--Clause-blue.svg)](https://github.com/lvim-tech/lvim-indent/blob/main/LICENSE)

## Features

- **Indent guides** — a vertical glyph at every indent level of every visible line, computed in **display columns**: tab-indented buffers, `'vartabstop'` and mixed tab+space indentation all land on the true screen cells. A guide never overwrites a real character.
- **Blank-line continuation** — the guide runs through blank lines as long as the block does; with `smart_indent_cap` a gap between blocks takes the **shallower** neighbour's depth, so no phantom guides sprout between a deep block and a top-level statement.
- **Rainbow levels** (optional) — a palette accent cycled per depth; off by default (a single muted colour).
- **Scope** — the innermost enclosing block of the cursor gets a brighter guide, with optional underlines on its first/last line. Two engines:
  - `treesitter` — the enclosing node via **lvim-ts** (the set's parser seam), filtered by per-language node-type lists; injected languages honoured;
  - `indent` — pure indentation, no parser needed (YAML, logs, plain text) — also the automatic fallback whenever no parser is active.
- **Chunk bracket** (optional) — the scope's shape drawn as `╭`/`│`/`╰` with a `─` run pointing into the code, hugging the block's own guide column. Takes a "folded" accent while the scope contains a closed fold.
- **Animated scope** (optional) — the scope guide/bracket grows from the cursor line outward over a few frames.
- **Diagnostics-aware levels** (optional) — a level whose block contains an error/warning takes the diagnostic accent: the block being debugged is the one that lights up.
- **Fold-aware** — a closed fold's display line draws nothing (foldtext is never painted over), and folded-away lines cost nothing.
- **The guard by construction** — a buffer with `buftype ~= ""` (panels, trees, terminals, quickfix, prompts) never gets guides; the config lists only carry the exceptions among real files, plus a hard `max_file_lines` cap.
- **Statuscolumn component** (optional) — the scope bracket can live in the gutter instead of over the text.
- **One decoration provider** — ephemeral extmarks, visible lines only, per-buffer indent cache keyed by `changedtick`: ~0.3 ms per repaint even on a 50k-line file.
- **Self-themed** — every highlight group derives from the live lvim-utils palette and rebuilds on `ColorScheme`/palette sync.
- `:LvimIndent` command, a full Lua API, a `LvimIndentChanged` User event and `:checkhealth lvim-indent` (including *why* the current buffer shows no guides and the measured repaint cost).

## Installation

Requires Neovim >= 0.10 and [lvim-utils](https://github.com/lvim-tech/lvim-utils) (palette-bound highlights and the shared config merge). [lvim-ts](https://github.com/lvim-tech/lvim-ts) is optional — with it the scope's treesitter engine resolves the buffer's language through the set's parser registry; without it (or without a parser) the scope falls back to the indent engine.

### lvim-installer (recommended)

Install and manage it from the LVIM package manager — open the **Plugins** tab and install / update / pin it:

```vim
:LvimInstaller plugins
```

lvim-installer installs plugins through Neovim's built-in `vim.pack`, so no external plugin manager is needed.

### Native (vim.pack)

```lua
vim.pack.add({
    { src = "https://github.com/lvim-tech/lvim-utils" },
    { src = "https://github.com/lvim-tech/lvim-indent" },
})
require("lvim-indent").setup({})
```

## Setup

Call `setup()` optionally with a config table. The full default config:

```lua
require("lvim-indent").setup({
    enabled = true,
    char = "▏", -- the guide glyph (single display width)
    tab_char = nil, -- the glyph on a TAB stop; nil = char
    blank_char = "▏", -- what a BLANK line draws ("" = nothing)
    -- Blank-line depth comes from the surrounding non-blank lines: the DEEPER neighbour keeps
    -- the guide running through gaps inside a block; smart_indent_cap caps it to the SHALLOWER
    -- neighbour, so the gap between a deep block and a top-level statement sprouts no phantom
    -- guides.
    smart_indent_cap = true,
    max_indent_level = 20, -- levels beyond this are not drawn
    max_file_lines = 20000, -- a buffer with more lines is skipped entirely (0 = no limit)

    levels = {
        rainbow = false, -- cycle a colour per depth (off: every level uses `accent`)
        accent = "fg_dark", -- palette key (or "#rrggbb") for ALL guides when rainbow is off
        accents = { "blue", "yellow", "green", "purple", "orange", "cyan" }, -- the rainbow cycle
        tint = 1, -- fg blend toward the bg (1 = full accent, lower fades the guides)
        diagnostics = false, -- a level whose block contains an error/warning takes the diag accent
        diag_accents = { error = "red", warn = "orange" },
    },

    scope = {
        enabled = true,
        engine = "treesitter", -- "treesitter" (via lvim-ts) | "indent" (no parser needed)
        style = "guide", -- "guide" | "chunk" | "both"
        accent = "yellow", -- palette key for the scope guide / chunk / underlines
        tint = 1, -- fg blend toward the bg (1 = full accent)
        show_start = true, -- underline the scope's first line
        show_end = true, -- underline the scope's last line
        debounce = 50, -- ms after a cursor move before the scope is re-resolved
        animate = { frames = 0, easing = "out" }, -- 0 = instant; easing: "linear"|"out"|"in_out"
        -- Node types that COUNT as a scope, per language ("*" language = every language,
        -- "*" type = every multi-line node), and those that never do (grammar roots).
        include = { ["*"] = { "*" } },
        exclude = {
            ["*"] = { "chunk", "module", "program", "source_file", "document", "translation_unit", "stream" },
        },
    },

    chunk = {
        open = "╭", -- first body line
        body = "│", -- down the body
        close = "╰", -- last body line
        tail = "─", -- the run from a corner toward the code
        folded_accent = "comment", -- the bracket while the scope contains a closed fold
    },

    exclude = {
        -- Non-file buffers are excluded by CONSTRUCTION (buftype ~= ""), never by name.
        -- These are the exceptions among REAL files.
        filetypes = { "checkhealth", "gitcommit", "help", "log", "man", "markdown", "org", "text" },
        buftypes = {}, -- extra, on top of the built-in rule
    },

    statuscolumn = { enabled = false }, -- scope in the gutter instead of over the text
})
```

### Notes on the options

- **Tints are foreground blends** — a guide is a thin glyph, so `tint` blends the accent toward the background: `1` is the full accent, `0.5` a half-faded guide. With `rainbow = true` a lower tint (e.g. `0.5`) keeps the hues subtle.
- **`smart_indent_cap`** decides only what BLANK lines draw. `true` (shallower neighbour) keeps gaps between blocks clean; `false` (deeper neighbour) draws the maximum plausible continuation.
- **Scope semantics** — the scope is the innermost multi-line node that *owns* deeper lines (a header line with an indented body). Header-less wrapper nodes (a Python `block`, a Lua `chunk`) are skipped up to the statement that owns them, so the lit guide always has a column to live on. On delimiter languages (`end`, `}`) the closing line takes the `show_end` underline and the bracket closes one line above; delimiter-less blocks (Python, YAML) close the bracket on their last line.
- **`scope.include` / `scope.exclude`** are maps `language → node types`. The default includes every multi-line node and excludes only grammar roots. To restrict the scope to real blocks in Lua, for example: `include = { lua = { "function_declaration", "if_statement", "for_statement", "while_statement" } }`.
- **`statuscolumn.enabled`** suppresses the over-text scope *guide* and exposes the bracket as a gutter component instead — see below.

## Commands

```
:LvimIndent                       " toggle globally
:LvimIndent enable|disable|toggle " flip the global switch
:LvimIndent enable buffer         " …only for the current buffer
:LvimIndent refresh [buffer]      " drop the cache, re-resolve, repaint
```

## API

```lua
local li = require("lvim-indent")
li.enable(buf) -- buf: nil = global, 0/bufnr = per buffer
li.disable(buf)
li.toggle(buf)
li.refresh(buf)
li.enabled(buf) -- boolean; nil = the global switch, 0/bufnr = effective for that buffer
```

Every state change fires a `User` autocmd:

```lua
vim.api.nvim_create_autocmd("User", {
    pattern = "LvimIndentChanged",
    callback = function(ev)
        -- ev.data = { buf = <bufnr>|nil, enabled = <boolean> }  (buf = nil → global switch)
    end,
})
```

## Statuscolumn

With `statuscolumn = { enabled = true }` the scope bracket moves to the gutter. Host the component in a `'statuscolumn'` expression:

```lua
vim.o.statuscolumn = "%{%v:lua.require'lvim-indent.statuscolumn'.component()%}%s%l "
```

The component renders one cell — the bracket inside the scope body, a space elsewhere (the gutter width never jumps).

## Highlights

All groups are built from the live lvim-utils palette (accents and tints from the config) and rebuild on `ColorScheme`/palette sync:

| Group                                       | Paints                                        |
| ------------------------------------------- | --------------------------------------------- |
| `LvimIndentGuide`                            | every level (rainbow off)                     |
| `LvimIndentGuide1` … `LvimIndentGuideN`      | the rainbow cycle (one per `levels.accents`)  |
| `LvimIndentScope`                            | the scope guide                               |
| `LvimIndentScopeStart` / `LvimIndentScopeEnd` | the first / last scope line underline         |
| `LvimIndentChunk` / `LvimIndentChunkFolded`  | the chunk bracket / while a fold is inside    |
| `LvimIndentDiagError` / `LvimIndentDiagWarn` | the diagnostics-aware level tint              |

## Health

`:checkhealth lvim-indent` reports the dependency state, every glyph's display width, **the exclusion decision for the current buffer** (the exact reason when it gets no guides), the scope engine that actually runs there (treesitter via lvim-ts vs the indent fallback), the currently resolved scope, and the measured cost of one cold repaint of the visible lines.

## License

BSD 3-Clause — see [LICENSE](LICENSE).
