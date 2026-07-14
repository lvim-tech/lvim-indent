-- lvim-indent.scope: resolving "which block is the cursor inside of". Runs on CursorMoved /
-- CursorMovedI (debounced on a uv timer, config.scope.debounce), NEVER per redraw — the
-- decoration provider only PAINTS the state resolved here (M.active).
--
-- Two engines:
--   treesitter — the innermost MULTI-LINE node enclosing the cursor, filtered by the
--     include/exclude node-type lists. Treesitter is reached only through lvim-ts (the set's
--     parser seam) for the buffer's language; the node walk itself is Neovim's own
--     vim.treesitter. Injected languages are honoured (the injected tree is walked first,
--     the host tree when it yields nothing).
--   indent — pure indentation, no parser needed (a YAML/log/plain-text buffer): the maximal
--     run of lines at (or deeper than) the cursor line's indent, plus the shallower HEADER
--     line above it. The automatic fallback whenever the treesitter engine has no parser.
--
-- The resolved scope is CURRENT-WINDOW state (win + buf + rows + the guide column); a scope
-- change starts the grow animation and asks the affected windows to repaint.
--
---@module "lvim-indent.scope"

local config = require("lvim-indent.config")
local cache = require("lvim-indent.cache")
local guard = require("lvim-indent.guard")
local anim = require("lvim-indent.anim")

local uv = vim.uv

local M = {}

---@class LvimIndentScopeState
---@field win    integer  Window the scope was resolved for (the only one it paints in)
---@field buf    integer
---@field srow   integer  0-based first line of the scope (show_start underline)
---@field erow   integer  0-based last line of the scope (show_end underline)
---@field body_s integer  0-based first BODY row (guide / chunk cells)
---@field body_e integer  0-based last BODY row
---@field col    integer  Display column the scope guide / chunk sits on
---@field origin integer  Cursor row at resolve time (the grow animation's centre)
---@field engine "treesitter"|"indent"  Which engine produced this scope

---@type LvimIndentScopeState|nil
M.active = nil

---@type uv.uv_timer_t|nil
local timer = nil

--- Ask a window's buffer lines to repaint (ephemeral decorations only redraw when told to
--- after a state change that moved no text).
---@param win integer
---@return nil
local function redraw(win)
    if vim.api.nvim_win_is_valid(win) then
        pcall(vim.api.nvim__redraw, { win = win, valid = false })
    end
end

--- Is `t` listed for `lang` (or under the "*" language) in an include/exclude map?
---@param map table<string, string[]>
---@param lang string
---@param t string  node type
---@return boolean
local function type_listed(map, lang, t)
    local function has(list)
        if type(list) ~= "table" then
            return false
        end
        for _, v in ipairs(list) do
            if v == "*" or v == t then
                return true
            end
        end
        return false
    end
    return has(map[lang]) or has(map["*"])
end

--- Does the node own a HEADER line — a first line with at least one later non-blank line
--- indented DEEPER than it? Python-style `block` nodes start on their first statement (every
--- line at the same indent), so their guide column would sit ON the text of every line; the
--- walk skips them up to the node that visibly owns the block (the if/def/case statement),
--- which is also where the start/end underlines belong.
---@param buf integer
---@param ctx LvimIndentBufCache
---@param sr integer  0-based node start row
---@param er integer  0-based node end row
---@return boolean
local function has_header(buf, ctx, sr, er)
    local head = cache.info(ctx, buf, sr).width
    for r = sr + 1, er do
        local li = cache.info(ctx, buf, r)
        if not li.blank then
            return li.width > head
        end
    end
    return false
end

--- Walk `node`'s ancestor chain for the innermost multi-line HEADER node (see has_header)
--- passing include/exclude.
---@param node TSNode|nil
---@param lang string
---@param buf integer
---@param ctx LvimIndentBufCache
---@return TSNode|nil
local function walk(node, lang, buf, ctx)
    while node do
        local sr, _, er, ec = node:range()
        if ec == 0 then
            er = er - 1
        end
        if
            er > sr
            and type_listed(config.scope.include, lang, node:type())
            and not type_listed(config.scope.exclude, lang, node:type())
            and has_header(buf, ctx, sr, er)
        then
            return node
        end
        node = node:parent()
    end
    return nil
end

--- Treesitter engine: the enclosing multi-line node at the cursor, or nil when the buffer
--- has no active parser (the caller then falls back to the indent engine).
---@param buf integer
---@param row integer  0-based cursor row
---@param col integer  0-based cursor column
---@return LvimIndentScopeState|nil scope  Partial state (rows + col), or nil
---@return boolean handled  false = no parser here, try the indent engine
local function resolve_treesitter(buf, row, col)
    if not vim.treesitter.highlighter.active[buf] then
        return nil, false
    end
    local ok_ts, lts = pcall(require, "lvim-ts")
    local lang = (ok_ts and lts.lang_for_buf(buf)) or vim.bo[buf].filetype
    local ctx = cache.ctx(buf)
    -- Innermost injected tree first, the host tree when it yields nothing.
    local node = nil
    for _, ignore_injections in ipairs({ false, true }) do
        local ok, at = pcall(vim.treesitter.get_node, {
            bufnr = buf,
            pos = { row, col },
            ignore_injections = ignore_injections,
        })
        node = ok and walk(at, lang, buf, ctx) or nil
        if node then
            break
        end
    end
    if not node then
        return nil, true
    end
    local sr, _, er, ec = node:range()
    if ec == 0 then
        er = er - 1
    end
    -- The body's last row: a closing DELIMITER line ("end", "}") sits at the header's indent
    -- and takes the show_end underline instead of the bracket; a delimiter-less block
    -- (python, yaml) hangs deeper to its very last line, which then closes the bracket.
    local body_e = er - 1
    if cache.info(ctx, buf, er).width > cache.info(ctx, buf, sr).width then
        body_e = er
    end
    return { srow = sr, erow = er, body_s = sr + 1, body_e = body_e }, true
end

--- Indent engine: the run of lines at (or deeper than) the cursor line's indent, headed by
--- the first shallower non-blank line above.
---@param buf integer
---@param row integer  0-based cursor row
---@return LvimIndentScopeState|nil  Partial state (rows), or nil at top level
local function resolve_indent(buf, row)
    local ctx = cache.ctx(buf)
    local total = vim.api.nvim_buf_line_count(buf)
    local info = cache.info(ctx, buf, row)
    local depth = info.blank and cache.blank_depth(ctx, buf, row, false) or info.width
    if depth <= 0 then
        return nil
    end
    -- Up: the header is the first non-blank line shallower than the cursor's indent.
    local srow = nil
    for r = row - 1, 0, -1 do
        local li = cache.info(ctx, buf, r)
        if not li.blank and li.width < depth then
            srow = r
            break
        end
    end
    if not srow then
        return nil
    end
    -- Down: the body ends on the last non-blank line still at (or deeper than) the depth.
    local erow = row
    for r = row + 1, total - 1 do
        local li = cache.info(ctx, buf, r)
        if li.blank then
            -- keep scanning; only a non-blank line can end (or extend) the body
        elseif li.width >= depth then
            erow = r
        else
            break
        end
    end
    if info.blank and erow == row then
        return nil -- a blank line trailing the block, nothing below it
    end
    -- No closing delimiter line exists in pure indentation: the body IS the scope's tail.
    return { srow = srow, erow = erow, body_s = srow + 1, body_e = erow }
end

--- Are two scope states the same painted range?
---@param a LvimIndentScopeState|nil
---@param b LvimIndentScopeState|nil
---@return boolean
local function same(a, b)
    if a == nil or b == nil then
        return a == b
    end
    return a.win == b.win and a.buf == b.buf and a.srow == b.srow and a.erow == b.erow and a.col == b.col
end

--- Resolve the scope for the current window NOW (the debounced target; also :LvimIndent
--- refresh's direct entry).
---@return nil
function M.resolve()
    local prev = M.active
    local win = vim.api.nvim_get_current_win()
    local buf = vim.api.nvim_win_get_buf(win)
    local next_state = nil
    if config.scope.enabled and guard.allowed(buf) then
        local pos = vim.api.nvim_win_get_cursor(win)
        local row = pos[1] - 1
        local ctx = cache.ctx(buf)
        local line_info = cache.info(ctx, buf, row)
        local col = math.max(0, math.min(pos[2], line_info.byte_len - 1))
        local scope = nil
        local engine = config.scope.engine
        if engine == "treesitter" then
            local handled
            scope, handled = resolve_treesitter(buf, row, col)
            if not handled then
                engine = "indent"
            end
        end
        if engine == "indent" then
            scope = resolve_indent(buf, row)
        end
        if scope then
            scope.win = win
            scope.buf = buf
            scope.col = cache.info(ctx, buf, scope.srow).width
            scope.origin = math.max(scope.body_s, math.min(row, scope.body_e))
            scope.engine = engine
            next_state = scope
        end
    end
    if same(prev, next_state) then
        return
    end
    M.active = next_state
    if next_state then
        anim.start(next_state.win)
    end
    if prev and (not next_state or prev.win ~= next_state.win) then
        redraw(prev.win)
    end
    if next_state then
        redraw(next_state.win)
    end
end

--- Clear the resolved scope (and repaint the window that showed it).
---@return nil
function M.clear()
    local prev = M.active
    M.active = nil
    if prev then
        redraw(prev.win)
    end
end

--- The debounced trigger (the autocmd target).
---@return nil
local function schedule_resolve()
    if not timer then
        timer = uv.new_timer()
    end
    if timer then
        timer:stop()
        timer:start(math.max(0, config.scope.debounce or 0), 0, function()
            vim.schedule(M.resolve)
        end)
    end
end

--- Install the resolver's autocmds (once, from setup()).
---@return nil
function M.setup()
    local aug = vim.api.nvim_create_augroup("LvimIndentScope", { clear = true })
    vim.api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI", "TextChanged", "TextChangedI" }, {
        group = aug,
        callback = schedule_resolve,
        desc = "lvim-indent: re-resolve the cursor scope (debounced)",
    })
    vim.api.nvim_create_autocmd({ "BufEnter", "WinEnter" }, {
        group = aug,
        callback = schedule_resolve,
        desc = "lvim-indent: re-resolve the scope for the entered window",
    })
end

return M
