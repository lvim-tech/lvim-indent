-- lvim-indent.column: the vertical RULERS — what 'colorcolumn' draws, as an unbroken line.
--
-- Neovim's own colorcolumn is a background cell, and a background loses. Any group with a bg on
-- the same cell paints over it, so the ruler disappears on the cursor line, inside a visual
-- selection, on a diff row — exactly the rows the eye is on. Drawing it ourselves puts the
-- priority in our hands.
--
-- Why not virtual text everywhere. A `virt_text_win_col` overlay REPLACES the cell it lands on:
-- given a buffer holding `7890123` and an overlay at that column, the screen showed `789|123` —
-- the `0` is gone, not covered. So a glyph is only ever drawn where the line does not reach the
-- ruler; where the text crosses it, the cell takes a background instead and the character stays
-- readable. That is the whole trick: glyph in the open, wash under the text, one continuous
-- vertical line either way.
--
-- (virt-column.nvim, which this follows, stops at the glyph: `if width < column then` and nothing
-- otherwise, so its ruler breaks at every line long enough to reach it.)
--
---@module "lvim-indent.column"

local config = require("lvim-indent.config")

local api = vim.api
local fn = vim.fn

local M = {}

--- The state of `own_option`: the spec we took over per window, and the flag that keeps our own
--- writes from re-entering the OptionSet handler.
---@type { augroup: integer|nil, applying: boolean, spec: table<integer, string> }
local state = { augroup = nil, applying = false, spec = {} }

--- Take 'colorcolumn' over for one window: remember what it asked for, then blank it so Neovim
--- draws no background band. The value is remembered per WINDOW because that is where it is
--- written — a control panel that sets a display option sets it on the window.
---@param win integer
---@return nil
local function seize(win)
    if not api.nvim_win_is_valid(win) then
        return
    end
    local spec = vim.wo[win].colorcolumn
    if spec ~= "" then
        state.spec[win] = spec
    end
    if spec == "" then
        return
    end
    state.applying = true
    vim.wo[win].colorcolumn = ""
    state.applying = false
end

--- Give 'colorcolumn' back exactly as it was found.
---@return nil
local function release()
    for win, spec in pairs(state.spec) do
        if api.nvim_win_is_valid(win) then
            state.applying = true
            vim.wo[win].colorcolumn = spec
            state.applying = false
        end
    end
    state.spec = {}
end

--- Start (or stop) owning the option.
---
--- Without this the ruler is drawn ON TOP of Neovim's own background band and both are visible;
--- with it the option keeps its value everywhere it is configured — the control panel that owns
--- it, `:set colorcolumn=100`, a modeline — and only the DRAWING moves here. That is the whole
--- point: one source of truth for WHERE the ruler is, a different module for WHAT it looks like.
---
--- The blanking cannot happen in the decoration provider: that runs inside a redraw, where
--- changing a window option is not allowed. It happens on the events that set the option instead,
--- with `applying` guarding against our own write coming back as OptionSet.
---@param on boolean
---@return nil
function M.own(on)
    if state.augroup then
        api.nvim_del_augroup_by_id(state.augroup)
        state.augroup = nil
    end
    if not on then
        release()
        return
    end
    state.augroup = api.nvim_create_augroup("LvimIndentColumn", { clear = true })
    api.nvim_create_autocmd({ "WinNew", "WinEnter", "BufWinEnter", "VimEnter" }, {
        group = state.augroup,
        callback = function()
            seize(api.nvim_get_current_win())
        end,
        desc = "lvim-indent: take 'colorcolumn' over so only the drawn ruler shows",
    })
    api.nvim_create_autocmd("OptionSet", {
        group = state.augroup,
        pattern = "colorcolumn",
        callback = function()
            -- Anything that sets the option — the control panel re-applying its stored value on
            -- WinEnter, a :set, a modeline — lands here, and the new spec is adopted rather than
            -- fought. Without the flag our own blanking would re-enter and remember "".
            if not state.applying then
                seize(api.nvim_get_current_win())
            end
        end,
        desc = "lvim-indent: adopt a newly set 'colorcolumn' and keep the band off",
    })
    for _, win in ipairs(api.nvim_list_wins()) do
        seize(win)
    end
end

--- The ruler's display columns for a window, 0-based, or nil when there are none.
---
--- `columns` in the config wins; otherwise the window's own 'colorcolumn' is read, falling back
--- to the global one. Reading the option rather than a copy means `:set colorcolumn=100` still
--- moves the ruler, and a host that keeps the global in sync (lvim-common, the control center)
--- keeps working untouched.
---
--- A `+N` entry is relative to 'textwidth', as Neovim defines it, and is dropped when textwidth
--- is 0 — the same rule the built-in applies, so turning this module on never moves a ruler the
--- user had somewhere else.
---@param win integer
---@param buf integer
---@return integer[]|nil
function M.columns(win, buf)
    local cfg = config.column
    if cfg.columns and #cfg.columns > 0 then
        local out = {}
        for _, c in ipairs(cfg.columns) do
            out[#out + 1] = c - 1
        end
        return out
    end

    -- With `own_option` on, the live option has been blanked by us on purpose, so the spec that
    -- was asked for lives in `state.spec` — reading the option here would return our own blank
    -- and the ruler would disappear the moment it took the option over.
    local spec = state.spec[win] or vim.wo[win].colorcolumn
    if spec == "" then
        spec = vim.go.colorcolumn
    end
    if spec == "" then
        return nil
    end

    local tw = vim.bo[buf].textwidth
    local out = {}
    for item in vim.gsplit(spec, ",", { trimempty = true }) do
        local rel = item:match("^%+(%d+)$")
        if rel then
            if tw > 0 then
                out[#out + 1] = tw + tonumber(rel) - 1
            end
        else
            local n = tonumber(item)
            if n and n > 0 then
                out[#out + 1] = n - 1
            end
        end
    end
    return #out > 0 and out or nil
end

--- Paint every ruler on one row.
---
--- The row's own DISPLAY width decides each ruler's branch, and it is measured here rather than
--- taken from the indent cache: that cache's `width` is the leading whitespace — the first text
--- column — not the length of the line. Passing it made every ruler take the empty-cell branch and
--- the glyph overwrote real characters: a line reading `789abc` came back from the screen as
--- `78|ab`, with the `9` gone. Measured once per row and shared by all the rulers on it.
---@param buf integer
---@param win integer
---@param ns integer
---@param row integer      0-based
---@param columns integer[]  0-based display columns of the rulers
---@param leftcol integer  Horizontal scroll of the window
---@param priority integer
---@return nil
function M.paint_row(buf, win, ns, row, columns, leftcol, priority)
    local line = api.nvim_buf_get_lines(buf, row, row + 1, false)[1]
    if not line then
        return
    end
    local width = fn.strdisplaywidth(line)
    for _, col in ipairs(columns) do
        M.paint(buf, win, ns, row, col, line, width, leftcol, priority)
    end
end

--- Paint one ruler cell on one row.
---
--- `col >= width` means the line stops short of the ruler and the cell is empty, so the glyph goes
--- there. Otherwise the character at that display column keeps its place and only gains a
--- background.
---@param buf integer
---@param win integer
---@param ns integer
---@param row integer     0-based
---@param col integer     0-based display column of the ruler
---@param line string     The row's text
---@param width integer   Display width of that text
---@param leftcol integer Horizontal scroll of the window
---@param priority integer
---@return nil
function M.paint(buf, win, ns, row, col, line, width, leftcol, priority)
    local cfg = config.column

    if col >= width then
        local wincol = col - leftcol
        -- A ruler scrolled off the left edge would otherwise be drawn AT the edge, which reads as
        -- a second ruler in the wrong place.
        if wincol < 0 then
            return
        end
        api.nvim_buf_set_extmark(buf, ns, row, 0, {
            virt_text = { { cfg.char, "LvimIndentColumn" } },
            virt_text_win_col = wincol,
            hl_mode = "combine",
            ephemeral = true,
            priority = priority,
        })
        return
    end

    if not cfg.crossing then
        return
    end

    -- The byte range of the single character sitting at that DISPLAY column. It cannot be derived
    -- from the column: a tab is one byte and many cells, and "й" is two bytes and one cell.
    -- virtcol2col answers with the character's byte index, and strcharpart gives its length —
    -- verified on ASCII, on tab-indented lines and on Cyrillic, where the naive arithmetic split
    -- the character in half and painted a broken glyph.
    local ok, byte = pcall(fn.virtcol2col, win, row + 1, col + 1)
    if not ok or byte <= 0 then
        return
    end
    local char = fn.strcharpart(line:sub(byte), 0, 1)
    if char == "" then
        return
    end
    api.nvim_buf_set_extmark(buf, ns, row, byte - 1, {
        end_col = byte - 1 + #char,
        hl_group = "LvimIndentColumnCrossing",
        hl_mode = "combine",
        ephemeral = true,
        priority = priority,
    })
end

return M
