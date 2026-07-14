-- lvim-indent.cache: the per-buffer indent cache — DISPLAY-column indent facts per line,
-- computed once per edit, not once per redraw. The whole table is keyed by changedtick +
-- shiftwidth/tabstop/vartabstop: the decoration provider calls ctx() once per on_win, and a
-- stale key wipes the cache wholesale (no buf_attach bookkeeping — the tick IS the seam).
--
-- Everything here is DISPLAY columns, never byte columns: a tab advances to its next tab stop
-- (honouring 'vartabstop'), so guides land where the whitespace actually renders — the place
-- naive byte-column implementations break on tab / mixed indentation.
--
---@module "lvim-indent.cache"

local M = {}

---@class LvimIndentStop
---@field col integer  Display column of this indent level's guide
---@field tab boolean  The stop sits on a TAB character (draws tab_char)

---@class LvimIndentLineInfo
---@field blank      boolean  The line is empty / whitespace-only
---@field stops      LvimIndentStop[]  Guide stops inside the leading whitespace (non-blank lines)
---@field width      integer  Display width of the leading whitespace (= first text column)
---@field byte_start integer  BYTE index of the first non-whitespace char (for hl ranges)
---@field byte_len   integer  BYTE length of the line

---@class LvimIndentBufCache
---@field tick  integer  changedtick this cache was built against
---@field sw    integer  Resolved shift width (shiftwidth, tabstop when 0)
---@field ts    integer  tabstop
---@field vts   string   vartabstop option string ("" when unset)
---@field lines table<integer, LvimIndentLineInfo>  0-based row → parsed line info
---@field blank table<integer, integer>  0-based blank row → resolved guide depth (display cols)
---@field package _vts_list integer[]|nil  Parsed 'vartabstop' widths (lazy)

---@type table<integer, LvimIndentBufCache>
local buffers = {}

--- How far blank_depth() scans for a non-blank neighbour before giving up (a pathological
--- all-blank region stops costing beyond this; the found depth simply becomes 0).
---@type integer
local BLANK_SCAN_LIMIT = 500

--- Advance a display column over one TAB, honouring 'vartabstop' when set.
---@param col integer  Current display column (0-based)
---@param ts integer   tabstop
---@param vts integer[]|nil  Parsed vartabstop widths (nil when unset)
---@return integer     The next tab stop's display column
local function next_tabstop(col, ts, vts)
    if not vts then
        return col - (col % ts) + ts
    end
    -- 'vartabstop': successive widths; the LAST width repeats forever.
    local edge = 0
    local width = ts
    for i = 1, #vts do
        width = vts[i]
        edge = edge + width
        if col < edge then
            return edge
        end
    end
    return col + width - ((col - edge) % width)
end

--- The cache for a buffer, (re)built when changedtick or the indent options moved.
---@param buf integer
---@return LvimIndentBufCache
function M.ctx(buf)
    local tick = vim.api.nvim_buf_get_changedtick(buf)
    local bo = vim.bo[buf]
    local sw = bo.shiftwidth ~= 0 and bo.shiftwidth or bo.tabstop
    local entry = buffers[buf]
    if not entry or entry.tick ~= tick or entry.sw ~= sw or entry.ts ~= bo.tabstop or entry.vts ~= bo.vartabstop then
        entry = { tick = tick, sw = sw, ts = bo.tabstop, vts = bo.vartabstop, lines = {}, blank = {} }
        buffers[buf] = entry
    end
    return entry
end

--- Parsed vartabstop widths for a ctx (lazy, cached on the entry).
---@param ctx LvimIndentBufCache
---@return integer[]|nil
local function vts_list(ctx)
    if ctx.vts == "" then
        return nil
    end
    if not ctx._vts_list then
        local list = {}
        for n in ctx.vts:gmatch("%d+") do
            list[#list + 1] = tonumber(n)
        end
        ctx._vts_list = list
    end
    return ctx._vts_list
end

--- Indent facts for one line (cached). Stops are emitted while WALKING the leading whitespace:
--- every TAB char is a stop at the display column it starts on; a SPACE contributes a stop when
--- its display column is a multiple of shiftwidth — so mixed tab+space indentation yields stops
--- exactly where the levels render.
---@param ctx LvimIndentBufCache
---@param buf integer
---@param row integer  0-based
---@return LvimIndentLineInfo
function M.info(ctx, buf, row)
    local cached = ctx.lines[row]
    if cached then
        return cached
    end
    local line = vim.api.nvim_buf_get_lines(buf, row, row + 1, false)[1] or ""
    local stops = {}
    local col = 0
    local i = 1
    local len = #line
    local vts = vts_list(ctx)
    while i <= len do
        local byte = line:byte(i)
        if byte == 32 then -- space
            if col % ctx.sw == 0 then
                stops[#stops + 1] = { col = col, tab = false }
            end
            col = col + 1
        elseif byte == 9 then -- tab
            stops[#stops + 1] = { col = col, tab = true }
            col = next_tabstop(col, ctx.ts, vts)
        else
            break
        end
        i = i + 1
    end
    local info = {
        blank = i > len,
        stops = stops,
        width = col,
        byte_start = i - 1,
        byte_len = len,
    }
    ctx.lines[row] = info
    return info
end

--- The guide depth (display columns) of a BLANK line, from its non-blank neighbours: the DEEPER
--- one keeps the guide running through a gap inside a block; `cap` (smart_indent_cap) takes the
--- SHALLOWER one instead, so the gap between a deep block and a top-level statement sprouts no
--- phantom guides. Cached per row on the ctx.
---@param ctx LvimIndentBufCache
---@param buf integer
---@param row integer  0-based blank row
---@param cap boolean  smart_indent_cap
---@return integer     Depth in display columns (0 = no guides)
function M.blank_depth(ctx, buf, row, cap)
    local cached = ctx.blank[row]
    if cached then
        return cached
    end
    local total = vim.api.nvim_buf_line_count(buf)
    local prev, nxt = 0, 0
    for r = row - 1, math.max(0, row - BLANK_SCAN_LIMIT), -1 do
        local info = M.info(ctx, buf, r)
        if not info.blank then
            prev = info.width
            break
        end
    end
    for r = row + 1, math.min(total - 1, row + BLANK_SCAN_LIMIT) do
        local info = M.info(ctx, buf, r)
        if not info.blank then
            nxt = info.width
            break
        end
    end
    local depth = cap and math.min(prev, nxt) or math.max(prev, nxt)
    ctx.blank[row] = depth
    return depth
end

--- Drop a buffer's cache (edit-independent invalidation: :LvimIndent refresh, wipeout).
---@param buf? integer  nil = every buffer
---@return nil
function M.invalidate(buf)
    if buf then
        buffers[buf] = nil
    else
        buffers = {}
    end
end

return M
