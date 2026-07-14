-- lvim-indent: :checkhealth lvim-indent.
-- Answers the questions that otherwise look like bugs: WHY does the current buffer show no
-- guides (the guard's exact reason), WHICH scope engine actually runs here (treesitter via
-- lvim-ts vs the indent fallback — and whether a parser exists for this filetype), whether the
-- glyphs are single-width, and what one repaint of the current viewport costs (measured, not
-- guessed). Read-only reporting — never mutates config or state.
--
---@module "lvim-indent.health"

local config = require("lvim-indent.config")
local guard = require("lvim-indent.guard")
local cache = require("lvim-indent.cache")
local scope = require("lvim-indent.scope")

local M = {}

--- Report one glyph's display width.
---@param health table  the vim.health reporter
---@param name string
---@param glyph string|nil
---@return nil
local function check_glyph(health, name, glyph)
    if glyph == nil or glyph == "" then
        return
    end
    local w = vim.fn.strdisplaywidth(glyph)
    if w == 1 then
        health.ok(("%s = %q (single width)"):format(name, glyph))
    else
        health.error(("%s = %q is %d cells wide — guides would shift the text"):format(name, glyph, w))
    end
end

--- The scope engine the CURRENT buffer would resolve with, plus the parser situation.
---@param health table
---@param buf integer
---@return nil
local function check_engine(health, buf)
    if not config.scope.enabled then
        health.info("scope is disabled (scope.enabled = false)")
        return
    end
    if config.scope.engine == "indent" then
        health.ok("scope engine: indent (configured — no parser needed)")
        return
    end
    local ft = vim.bo[buf].filetype
    local ok_ts, lts = pcall(require, "lvim-ts")
    if not ok_ts then
        health.warn("lvim-ts not found — the treesitter engine always falls back to the indent engine")
        return
    end
    local lang = lts.lang_for_buf(buf)
    if vim.treesitter.highlighter.active[buf] then
        health.ok(("scope engine here: treesitter (lvim-ts lang %q for filetype %q)"):format(lang, ft))
    else
        local hint = lang and ("no active parser for lang %q"):format(lang) or ("no lang for filetype %q"):format(ft)
        health.info(("scope engine here: indent fallback — %s"):format(hint))
    end
end

--- Measure one full viewport paint of the current window (the provider's real per-redraw
--- cost): rebuild the cache ctx and walk every visible line's stops.
---@param health table
---@param buf integer
---@return nil
local function check_cost(health, buf)
    -- The measured range: the buffer's own viewport when a window shows it (checkhealth opens
    -- its own window), otherwise its first screenful.
    local wins = vim.fn.win_findbuf(buf)
    local top, bot
    if #wins > 0 then
        top = vim.fn.line("w0", wins[1]) - 1
        bot = vim.fn.line("w$", wins[1]) - 1
    else
        top = 0
        bot = math.min(vim.api.nvim_buf_line_count(buf), vim.o.lines) - 1
    end
    cache.invalidate(buf)
    local t0 = vim.uv.hrtime()
    local ctx = cache.ctx(buf)
    local cells = 0
    for row = top, bot do
        local info = cache.info(ctx, buf, row)
        if info.blank then
            cells = cells + math.ceil(cache.blank_depth(ctx, buf, row, config.smart_indent_cap) / ctx.sw)
        else
            cells = cells + #info.stops
        end
    end
    local ms = (vim.uv.hrtime() - t0) / 1e6
    health.ok(("cold repaint of %d visible lines: %.2f ms (%d guide cells)"):format(bot - top + 1, ms, cells))
end

--- Run the health report.
---@return nil
function M.check()
    local health = vim.health
    health.start("lvim-indent")

    if vim.fn.has("nvim-0.10") == 1 then
        health.ok("Neovim >= 0.10")
    else
        health.error("Neovim >= 0.10 is required (ephemeral decoration provider, virt_text_repeat_linebreak)")
    end

    local ok_utils = pcall(require, "lvim-utils.utils")
    local ok_hl, hl = pcall(require, "lvim-utils.highlight")
    if ok_utils and ok_hl and type(hl.bind) == "function" then
        health.ok("lvim-utils found (palette-bound highlights + merge)")
    else
        health.error("lvim-utils is required (highlight.bind, colors, utils.merge)")
    end

    check_glyph(health, "char", config.char)
    check_glyph(health, "tab_char", config.tab_char)
    check_glyph(health, "blank_char", config.blank_char)
    check_glyph(health, "chunk.open", config.chunk.open)
    check_glyph(health, "chunk.body", config.chunk.body)
    check_glyph(health, "chunk.close", config.chunk.close)
    check_glyph(health, "chunk.tail", config.chunk.tail)

    -- The exclusion decision for the buffer checkhealth was invoked FROM ("why no guides
    -- here?"). :checkhealth itself opens its own window, so resolve the previous buffer.
    local buf = vim.fn.bufnr("#")
    if buf == -1 or not vim.api.nvim_buf_is_valid(buf) then
        buf = vim.api.nvim_get_current_buf()
    end
    local allowed, reason = guard.decide(buf)
    local name = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(buf), ":~:.")
    if name == "" then
        name = "[No Name]"
    end
    if allowed then
        health.ok(("buffer %s gets guides"):format(name))
    else
        health.warn(("buffer %s gets NO guides: %s"):format(name, reason))
    end

    check_engine(health, buf)

    local st = scope.active
    if st then
        health.info(
            ("resolved scope: lines %d–%d, column %d (%s engine)"):format(st.srow + 1, st.erow + 1, st.col, st.engine)
        )
    end

    if allowed then
        check_cost(health, buf)
    end
end

return M
