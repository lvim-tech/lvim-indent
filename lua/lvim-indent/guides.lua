-- lvim-indent.guides: the ONE decoration provider — everything lvim-indent draws goes through
-- nvim_set_decoration_provider (on_win + on_line) as EPHEMERAL extmarks: work happens per
-- VISIBLE line at redraw time, nothing is scheduled, nothing is left behind, and there is no
-- namespace to clear. Guides use virt_text_win_col — DISPLAY columns from the indent cache —
-- which is what makes tabs / 'vartabstop' / mixed indentation land on the true screen cells.
--
-- Per redraw of a window, on_win decides the guard once, walks the viewport's closed folds
-- (a closed fold's display line draws NOTHING — the guide never overwrites foldtext), snapshots
-- the resolved scope (animation-clamped), and optionally builds the diagnostics map; on_line
-- then paints level guides + the scope guide / chunk bracket / underlines for its single row.
--
---@module "lvim-indent.guides"

local config = require("lvim-indent.config")
local cache = require("lvim-indent.cache")
local guard = require("lvim-indent.guard")
local scope = require("lvim-indent.scope")
local chunk = require("lvim-indent.chunk")
local anim = require("lvim-indent.anim")
local column = require("lvim-indent.column")

local api = vim.api

local M = {}

--- The provider's namespace (ephemeral marks only — never cleared, never persisted).
---@type integer
local ns = api.nvim_create_namespace("lvim-indent")

--- Extmark priorities: the scope/chunk layer must win over a level guide on the same cell, and
--- the ruler sits UNDER both — it is fixed furniture, so an indent guide or a scope that lands on
--- the same column must still be the thing you see. It is nonetheless far above the built-in
--- backgrounds, which is what stops the ruler vanishing under CursorLine.
---@type integer, integer, integer
local PRIO_GUIDE, PRIO_SCOPE, PRIO_COLUMN = 10, 20, 5

---@class LvimIndentWinCtx
---@field skip boolean  This window draws nothing (both guard decisions said no)
---@field skip_guides boolean  Guides/scope are out, but the ruler still draws
---@field buf? integer
---@field win? integer
---@field cache? LvimIndentBufCache
---@field fold_start? table<integer, boolean>  0-based rows that display a CLOSED fold's line
---@field scope? table  Snapshot of the painted scope (rows clamped by the animation)
---@field diag? table<integer, table<integer, string>>  row → col → "error"|"warn"
---@field repeat_lb? boolean  Repeat guides on wrapped lines ('wrap' + 'breakindent')
---@field columns? integer[]  0-based display columns of the rulers (nil = none for this window)
---@field leftcol? integer    The window's horizontal scroll, so a ruler tracks it

--- Per-window paint context, rebuilt by on_win (the provider calls on_win, then that window's
--- on_line rows, strictly in sequence — one slot is enough).
---@type LvimIndentWinCtx
local ctx = { skip = true, skip_guides = true }

--- Severity rank for the diagnostics map (error wins over warn on the same cell).
---@type table<string, integer>
local SEV_RANK = { error = 2, warn = 1 }

--- Mark the guide cells of the block containing one diagnostic. From the diagnostic's line the
--- walk goes up and then down; a non-blank line of width `w` ends the block of every level
--- >= w (blank lines pass through every level). Only rows inside the viewport are marked —
--- the map is rebuilt per redraw, so nothing outside it is ever needed.
---@param map table<integer, table<integer, string>>
---@param buf integer
---@param dline integer  0-based diagnostic row
---@param sev string     "error"|"warn"
---@param top integer    0-based first viewport row
---@param bot integer    0-based last viewport row
---@return nil
local function mark_diag_block(map, buf, dline, sev, top, bot)
    local info = cache.info(ctx.cache, buf, dline)
    if info.blank or #info.stops == 0 then
        return
    end
    local cols = {}
    for _, stop in ipairs(info.stops) do
        cols[#cols + 1] = stop.col
    end
    local shallowest = cols[1]
    for _, dir in ipairs({ -1, 1 }) do
        local minw = math.huge
        local r = dline
        -- One-sided per direction: a diagnostic up to 300 rows OFF-screen (see diag_map) must be able to START
        -- its walk outside [top-1, bot+1] and accumulate toward the viewport. A two-sided bound killed the first
        -- iteration for an off-screen dline, so the ±300 window (and the tint on a partly-visible block) was dead.
        while (dir == -1 and r >= top - 1) or (dir == 1 and r <= bot + 1) do
            if r ~= dline then
                local li = cache.info(ctx.cache, buf, r)
                if not li.blank then
                    if li.width < minw then
                        minw = li.width
                    end
                    if minw <= shallowest then
                        break
                    end
                end
            end
            if r >= top and r <= bot then
                local row_map = map[r]
                if not row_map then
                    row_map = {}
                    map[r] = row_map
                end
                for _, c in ipairs(cols) do
                    if c < minw then
                        local cur = row_map[c]
                        if not cur or SEV_RANK[sev] > SEV_RANK[cur] then
                            row_map[c] = sev
                        end
                    end
                end
            end
            r = r + dir
        end
    end
end

--- Build the row → col → severity map for the viewport (only when levels.diagnostics).
---@param buf integer
---@param top integer  0-based
---@param bot integer  0-based
---@return table<integer, table<integer, string>>|nil
local function diag_map(buf, top, bot)
    local diags = vim.diagnostic.get(buf, { severity = { min = vim.diagnostic.severity.WARN } })
    if #diags == 0 then
        return nil
    end
    local map = {}
    local total = api.nvim_buf_line_count(buf)
    for _, d in ipairs(diags) do
        if d.lnum >= math.max(0, top - 300) and d.lnum <= math.min(total - 1, bot + 300) then
            local sev = d.severity == vim.diagnostic.severity.ERROR and "error" or "warn"
            mark_diag_block(map, buf, math.min(d.lnum, total - 1), sev, top, bot)
        end
    end
    return map
end

--- Place one ephemeral overlay cell (or cell run) at a display column.
---@param buf integer
---@param row integer  0-based
---@param col integer  Display column (virt_text_win_col)
---@param cells table[]  virt_text chunks
---@param priority integer
---@return nil
local function put(buf, row, col, cells, priority)
    api.nvim_buf_set_extmark(buf, ns, row, 0, {
        virt_text = cells,
        virt_text_win_col = col,
        hl_mode = "combine",
        ephemeral = true,
        priority = priority,
        virt_text_repeat_linebreak = ctx.repeat_lb or nil,
    })
end

--- The level guide's highlight for one cell: the diagnostics map first, then the rainbow
--- cycle (or the single guide colour).
---@param level integer  1-based indent level of the cell
---@param row integer
---@param col integer
---@return string
local function guide_hl(level, row, col)
    local d = ctx.diag and ctx.diag[row]
    local sev = d and d[col]
    if sev then
        return sev == "error" and "LvimIndentDiagError" or "LvimIndentDiagWarn"
    end
    local levels = config.levels
    if levels.rainbow and #levels.accents > 0 then
        return "LvimIndentGuide" .. ((level - 1) % #levels.accents + 1)
    end
    return "LvimIndentGuide"
end

--- Snapshot the scope for painting in this window: rows clamped by the grow animation, plus
--- whether the range contains a closed fold (the chunk then wears the folded accent).
---@param win integer
---@param buf integer
---@return table|nil
local function scope_ctx(win, buf)
    local st = scope.active
    if not st or not config.scope.enabled or st.win ~= win or st.buf ~= buf then
        return nil
    end
    local body_s, body_e = anim.clamp(st.body_s, st.body_e, st.origin)
    return {
        srow = st.srow,
        erow = st.erow,
        body_s = body_s,
        body_e = body_e,
        col = st.col,
        folded = false, -- filled by the fold walk in on_win
    }
end

--- on_win: the once-per-window-per-redraw part — guard, fold walk, scope snapshot, diag map.
---@param win integer
---@param buf integer
---@param top integer  0-based first visible row
---@param bot integer  0-based last visible row (approximate)
---@return boolean  false skips on_line for this window entirely
local function on_win(_, win, buf, top, bot)
    ctx.skip = true
    -- Two decisions, not one: a filetype excluded from GUIDES can still want its ruler.
    local guides_ok = guard.allowed(buf)
    local column_ok = guard.column_allowed(buf)
    if not guides_ok and not column_ok then
        return false
    end
    ctx.skip = false
    ctx.skip_guides = not guides_ok
    ctx.win, ctx.buf = win, buf
    ctx.cache = cache.ctx(buf)
    ctx.repeat_lb = vim.wo[win].wrap and vim.wo[win].breakindent
    ctx.scope = scope_ctx(win, buf)
    ctx.fold_start = {}
    -- Closed folds in the viewport: their display lines draw nothing, and a fold inside the
    -- scope switches the chunk to the folded accent.
    api.nvim_win_call(win, function()
        local l = top + 1
        while l <= bot + 1 do
            local fc = vim.fn.foldclosed(l)
            if fc ~= -1 then
                local fe = vim.fn.foldclosedend(l)
                ctx.fold_start[fc - 1] = true
                if ctx.scope and fc - 1 <= ctx.scope.erow and fe - 1 >= ctx.scope.srow then
                    ctx.scope.folded = true
                end
                l = fe + 1
            else
                l = l + 1
            end
        end
    end)
    ctx.columns = column_ok and column.columns(win, buf) or nil
    -- Resolved once per window per redraw rather than per row: it is a window property, and
    -- on_line runs for every visible line.
    ctx.leftcol = ctx.columns and api.nvim_win_call(win, function()
        return vim.fn.winsaveview().leftcol
    end) or 0
    ctx.diag = config.levels.diagnostics and diag_map(buf, top, bot) or nil
    return true
end

--- on_line: paint one visible row — level guides, then the scope guide / chunk / underlines.
---@param win integer
---@param buf integer
---@param row integer  0-based
---@return nil
local function on_line(_, win, buf, row)
    if ctx.skip or ctx.fold_start[row] then
        return
    end

    -- ── Rulers ('colorcolumn') ──────────────────────────────────────────────────────────────
    -- First, and before the guides' own exclusions are consulted: the ruler is drawn in
    -- filetypes that get no guides at all, and it needs nothing from the indent cache.
    if ctx.columns then
        column.paint_row(buf, win, ns, row, ctx.columns, ctx.leftcol, PRIO_COLUMN)
    end
    if ctx.skip_guides then
        return
    end

    local info = cache.info(ctx.cache, buf, row)
    local sc = ctx.scope
    local sw = ctx.cache.sw

    -- The scope layer's cell on this row (the level guide there is skipped, not fought).
    local scope_col = nil
    if sc and row >= sc.body_s and row <= sc.body_e then
        scope_col = sc.col
    end

    -- ── Level guides ────────────────────────────────────────────────────────────────────────
    local max_level = config.max_indent_level
    if info.blank then
        local ch = config.blank_char
        if ch ~= "" then
            -- Draw on the REAL stops of whichever neighbour supplied this row's depth, so a blank
            -- row inside a tab-indented block lines up with the guides above and below it. Multiples
            -- of 'shiftwidth' only coincide with the true columns when `sw == ts` and 'vartabstop' is
            -- unset; elsewhere they drifted (one tab with `sw=4 ts=8` drew guides at 0 AND 4, where
            -- the surrounding lines have a single guide at 0).
            local depth, stops = cache.blank_stops(ctx.cache, buf, row, config.smart_indent_cap)
            if stops then
                for level, stop in ipairs(stops) do
                    if level > max_level then
                        break
                    end
                    -- The BLANK char is kept (the row has no tab of its own to draw); only the COLUMN
                    -- comes from the source line.
                    if stop.col ~= scope_col then
                        put(buf, row, stop.col, { { ch, guide_hl(level, row, stop.col) } }, PRIO_GUIDE)
                    end
                end
            else
                -- No neighbour found (an all-blank region): the shiftwidth grid is all we know.
                local level, col = 0, 0
                while col < depth and level < max_level do
                    level = level + 1
                    if col ~= scope_col then
                        put(buf, row, col, { { ch, guide_hl(level, row, col) } }, PRIO_GUIDE)
                    end
                    col = col + sw
                end
            end
        end
    else
        for level, stop in ipairs(info.stops) do
            if level > max_level then
                break
            end
            if stop.col ~= scope_col then
                local ch = stop.tab and (config.tab_char or config.char) or config.char
                put(buf, row, stop.col, { { ch, guide_hl(level, row, stop.col) } }, PRIO_GUIDE)
            end
        end
    end

    -- ── Scope guide / chunk bracket ─────────────────────────────────────────────────────────
    if sc and scope_col and (info.blank or scope_col < info.width) then
        local style = config.scope.style
        if (style == "guide" or style == "both") and not config.statuscolumn.enabled then
            put(buf, row, scope_col, { { config.char, "LvimIndentScope" } }, PRIO_SCOPE)
        end
        if style == "chunk" or style == "both" then
            local target = info.blank and (scope_col + sw) or info.width
            local hl = sc.folded and "LvimIndentChunkFolded" or "LvimIndentChunk"
            local cells = chunk.cells(row, sc.body_s, sc.body_e, target, scope_col, hl)
            if cells then
                put(buf, row, scope_col, cells, PRIO_SCOPE)
            end
        end
    end

    -- ── Scope boundary underlines ───────────────────────────────────────────────────────────
    if sc and not info.blank and info.byte_len > info.byte_start then
        local group = nil
        if row == sc.srow and config.scope.show_start then
            group = "LvimIndentScopeStart"
        elseif row == sc.erow and config.scope.show_end then
            group = "LvimIndentScopeEnd"
        end
        if group then
            api.nvim_buf_set_extmark(buf, ns, row, info.byte_start, {
                end_col = info.byte_len,
                hl_group = group,
                hl_mode = "combine",
                ephemeral = true,
                priority = PRIO_SCOPE,
            })
        end
    end
end

--- Install the decoration provider (once, from setup()).
---@return nil
function M.setup()
    api.nvim_set_decoration_provider(ns, {
        on_win = on_win,
        on_line = on_line,
    })
end

return M
