-- lvim-indent: the live configuration table.
-- Holds the defaults; setup() merges user overrides into it in place (lvim-utils.utils.merge —
-- clean array replace), so every require("lvim-indent.config") reader sees the effective values.
-- Everything here is designed to be flipped at runtime: the decoration provider and the scope
-- resolver read the table live on every redraw / cursor move, so the control center (or the user)
-- can retune guides, scope style, accents and animation without a restart.
--
-- Tints are FOREGROUND blends: a guide is a thin glyph, so its colour is the accent blended
-- toward the background — `1` is the full accent, lower values fade the glyph into the bg.
--
---@module "lvim-indent.config"

---@class LvimIndentLevels
---@field rainbow     boolean   Cycle a colour per indent depth (off: every level uses `accent`)
---@field accent      string    Palette key (or "#rrggbb") for ALL guides when rainbow is off
---@field accents     string[]  Palette keys cycled per depth when rainbow is on
---@field tint        number    Fg blend strength toward bg (1 = full accent, 0 = invisible)
---@field diagnostics boolean   A level whose block contains an error/warning takes the diag accent
---@field diag_accents { error: string, warn: string }  Palette keys for the diagnostic tint

---@class LvimIndentAnimate
---@field frames integer  Grow frames when the scope changes (0 = instant)
---@field easing "linear"|"out"|"in_out"  Frame easing of the grow

---@class LvimIndentScope
---@field enabled   boolean  Resolve + draw the enclosing scope at all
---@field engine    "treesitter"|"indent"  Scope resolution engine (treesitter falls back to indent
---                 automatically when the buffer has no parser)
---@field style     "guide"|"chunk"|"both"  How the scope is drawn: a brighter guide, the chunk
---                 bracket, or both
---@field accent    string   Palette key for the scope guide / chunk / underlines
---@field tint      number   Fg blend strength toward bg (1 = full accent)
---@field show_start boolean Underline the scope's first line
---@field show_end  boolean  Underline the scope's last line
---@field debounce  integer  Ms after a cursor move before the scope is re-resolved
---@field animate   LvimIndentAnimate
---@field include   table<string, string[]>  Per-language node types that COUNT as a scope
---                 ("*" language = every language; "*" type = every multi-line node)
---@field exclude   table<string, string[]>  Node types that never count (roots by default)

---@class LvimIndentChunk
---@field open  string  The bracket's opening corner (first body line)
---@field body  string  The vertical along the body
---@field close string  The closing corner (last body line)
---@field tail  string  The horizontal run from a corner toward the code
---@field folded_accent string  Palette key the bracket takes while the scope contains a closed fold

---@class LvimIndentExclude
---@field filetypes string[]  Real-file filetypes that still want no guides

---@class LvimIndentColumn
---@field enabled            boolean  Draw the 'colorcolumn' rulers as an unbroken virtual line
---@field columns            integer[]|nil  Explicit 1-based columns; nil = follow 'colorcolumn'
---@field char               string   The ruler glyph, drawn where the line stops short of it
---@field accent             string   Palette key (or "#rrggbb") for the glyph
---@field tint               number   Fg blend strength toward bg (1 = full accent)
---@field crossing           boolean  Wash the cell where the TEXT crosses the ruler, so the line
---                          never breaks. Off: the ruler stops at the text, as virt-column does
---@field own_option        boolean  Take 'colorcolumn' over: keep its value as the source of
---                          WHERE the ruler is, and blank the option so Neovim draws no
---                          background band under the drawn line. Off: both are drawn
---@field exclude_filetypes string[]  Filetypes with no ruler. Its OWN list: `exclude.filetypes`
---                          is about indentation and says nothing about where column 80 is
---@field crossing_tint      number   Bg blend strength of that wash (a background, so it is kept
---                          far below the glyph's — a ruler is permanent furniture)

---@class LvimIndentStatuscolumn
---@field enabled boolean  Expose the scope in the gutter instead of over the text (suppresses the
---                        in-text scope guide; see lvim-indent.statuscolumn)

---@class LvimIndentConfig
---@field enabled          boolean  Master switch (see :LvimIndent / the API)
---@field char             string   The guide glyph (single display width)
---@field tab_char         string|nil  The glyph on a TAB stop; nil = `char`
---@field blank_char       string   What a BLANK line draws ("" = nothing)
---@field smart_indent_cap boolean  A blank line between blocks takes the SHALLOWER neighbour depth
---@field max_indent_level integer  Levels beyond this are not drawn
---@field max_file_lines   integer  A buffer with more lines is skipped entirely (0 = no limit)
---@field levels           LvimIndentLevels
---@field scope            LvimIndentScope
---@field chunk            LvimIndentChunk
---@field exclude          LvimIndentExclude
---@field statuscolumn     LvimIndentStatuscolumn
---@field column          LvimIndentColumn

---@type LvimIndentConfig
return {
    enabled = true,
    char = "▏",
    -- nil = the tab stop draws `char` too; set e.g. "│" to tell tab levels apart visually.
    tab_char = nil,
    blank_char = "▏",
    -- Blank-line depth is taken from the surrounding non-blank lines: the DEEPER neighbour keeps
    -- the guide running through gaps inside a block; smart_indent_cap caps it to the SHALLOWER
    -- neighbour, so the gap between a deep block and a top-level statement sprouts no phantom
    -- guides.
    smart_indent_cap = true,
    max_indent_level = 20,
    max_file_lines = 20000,

    levels = {
        rainbow = false,
        accent = "fg_dark",
        accents = { "blue", "yellow", "green", "purple", "orange", "cyan" },
        tint = 1,
        -- Opt-in: a level whose block contains an error/warning diagnostic takes the diagnostic
        -- accent instead of its level colour — the block being debugged is the one that lights up.
        diagnostics = false,
        diag_accents = { error = "red", warn = "orange" },
    },

    scope = {
        enabled = true,
        engine = "treesitter",
        style = "guide",
        accent = "yellow",
        tint = 1,
        show_start = true,
        show_end = true,
        debounce = 50,
        animate = { frames = 0, easing = "out" },
        -- Every multi-line node counts as a scope by default ("which block am I in"), except the
        -- per-grammar ROOT nodes below (otherwise the whole file would be one giant scope).
        include = { ["*"] = { "*" } },
        exclude = {
            ["*"] = { "chunk", "module", "program", "source_file", "document", "translation_unit", "stream" },
        },
    },

    chunk = {
        open = "╭",
        body = "│",
        close = "╰",
        tail = "─",
        folded_accent = "comment",
    },

    exclude = {
        -- Non-file buffers (panels, trees, terminals, quickfix, prompts …) are excluded by
        -- CONSTRUCTION (buftype ~= ""), never by name — these are the exceptions among REAL files.
        filetypes = { "checkhealth", "gitcommit", "help", "log", "man", "markdown", "org", "text" },
    },

    -- The 'colorcolumn' rulers, redrawn as a continuous line. Neovim's own is a background
    -- cell, so every group with a bg wins over it and the ruler vanishes on the cursor line;
    -- owning the drawing is what fixes that. Set `vim.opt.colorcolumn` as usual — this reads it.
    column = {
        enabled = true,
        columns = nil,
        char = "│",
        -- "cursorline" takes the cursor line's own colour; a palette key or "#rrggbb" also work.
        accent = "cursorline",
        -- Dims that colour toward the background, so the ruler is the same hue as the band but a
        -- step quieter — which is what tells them apart where they cross.
        tint = 0.75,
        crossing = true,
        -- Off by default: taking an option over is not something a plugin should do unasked.
        -- On, 'colorcolumn' keeps meaning what it always meant — the control panel, `:set`, a
        -- modeline — and only the drawing moves here.
        own_option = false,
        exclude_filetypes = {},
        -- Far weaker than the glyph: the wash sits under real characters on every long line, and
        -- at the glyph's strength it read as a highlighted column rather than as a ruler.
        crossing_tint = 0.22,
    },

    statuscolumn = { enabled = false },
}
