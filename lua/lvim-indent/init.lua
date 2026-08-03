-- lvim-indent: indent guides that know what you are inside of — every indent level drawn
-- (including through blank lines), the enclosing scope lit, and optionally the scope's shape
-- as a chunk bracket. One decoration provider paints only the visible lines with ephemeral
-- extmarks at DISPLAY columns (tabs / 'vartabstop' / mixed indentation land right); the scope
-- is resolved on debounced cursor moves via treesitter (through lvim-ts) with a pure-indent
-- fallback for grammarless buffers. Everything themes itself from the lvim-utils palette.
--
-- This module is the public entry point: setup() merges user opts into the live config,
-- validates every glyph (single display width — a wide glyph would shift the cells it
-- overlays), binds the highlight factory, installs the provider + the scope resolver, and
-- defines :LvimIndent. State changes fire the `LvimIndentChanged` User autocmd so a
-- statusline / the control-center can mirror them.
--
---@module "lvim-indent"

local config = require("lvim-indent.config")
local cache = require("lvim-indent.cache")
local guard = require("lvim-indent.guard")
local scope = require("lvim-indent.scope")
local guides = require("lvim-indent.guides")
local uu = require("lvim-utils.utils")

local M = {}

---@type boolean  one-time registration (provider, autocmds, command, highlight bind) done
local registered = false

--- Repaint every window (a global state flip moved no text, so nothing would redraw itself).
---@return nil
local function redraw_all()
    pcall(vim.api.nvim__redraw, { valid = false })
end

--- Fire the state-change User event.
---@param buf integer|nil  nil = the global switch moved
---@param enabled boolean
---@return nil
local function notify_changed(buf, enabled)
    vim.api.nvim_exec_autocmds("User", {
        pattern = "LvimIndentChanged",
        data = { buf = buf, enabled = enabled },
    })
end

--- Reject a glyph that is not exactly one display cell wide (it would shift every cell the
--- overlay covers). "" is allowed where the config documents it.
---@param name string  config path for the error message
---@param glyph string|nil
---@param allow_empty? boolean
---@return nil
local function validate_glyph(name, glyph, allow_empty)
    if glyph == nil or (allow_empty and glyph == "") then
        return
    end
    if type(glyph) ~= "string" or vim.fn.strdisplaywidth(glyph) ~= 1 then
        error(("lvim-indent: %s must be a single-width glyph (got %s)"):format(name, vim.inspect(glyph)), 0)
    end
end

--- Validate every configured glyph after the merge.
---@return nil
local function validate_glyphs()
    validate_glyph("char", config.char)
    validate_glyph("tab_char", config.tab_char)
    validate_glyph("blank_char", config.blank_char, true)
    validate_glyph("chunk.open", config.chunk.open)
    validate_glyph("chunk.body", config.chunk.body)
    validate_glyph("chunk.close", config.chunk.close)
    validate_glyph("chunk.tail", config.chunk.tail)
end

--- Resolve an optional command/API buffer argument to a buffer handle.
---@param buf? integer  nil/0 = current
---@return integer
local function bufnr(buf)
    if buf == nil or buf == 0 then
        return vim.api.nvim_get_current_buf()
    end
    return buf
end

--- Is lvim-indent drawing in a buffer (the global switch AND the buffer's own)?
---@param buf? integer  nil = report the GLOBAL switch only
---@return boolean
function M.enabled(buf)
    if buf == nil then
        return config.enabled
    end
    return config.enabled and guard.buf_enabled(bufnr(buf))
end

--- Turn guides on — globally, or for one buffer.
---@param buf? integer  nil = global
---@return nil
function M.enable(buf)
    if buf == nil then
        config.enabled = true
        notify_changed(nil, true)
    else
        buf = bufnr(buf)
        guard.set_enabled(buf, true)
        notify_changed(buf, true)
    end
    scope.resolve()
    redraw_all()
end

--- Turn guides off — globally, or for one buffer.
---@param buf? integer  nil = global
---@return nil
function M.disable(buf)
    if buf == nil then
        config.enabled = false
        notify_changed(nil, false)
    else
        buf = bufnr(buf)
        guard.set_enabled(buf, false)
        notify_changed(buf, false)
    end
    scope.clear()
    redraw_all()
end

--- Flip the switch — globally, or for one buffer.
---@param buf? integer  nil = global
---@return nil
function M.toggle(buf)
    local on
    if buf == nil then
        on = config.enabled
    else
        on = guard.buf_enabled(bufnr(buf))
    end
    if on then
        M.disable(buf)
    else
        M.enable(buf)
    end
end

--- Recompute everything for a buffer (drop its indent cache, re-resolve the scope, repaint).
---@param buf? integer  nil = every buffer
---@return nil
function M.refresh(buf)
    cache.invalidate(buf and bufnr(buf) or nil)
    scope.resolve()
    redraw_all()
end

--- :LvimIndent [enable|disable|toggle|refresh] [buffer]
---@param args string[]
---@return nil
local function command(args)
    local action = args[1] or "toggle"
    local buf = args[2] == "buffer" and vim.api.nvim_get_current_buf() or nil
    if action == "enable" then
        M.enable(buf)
    elseif action == "disable" then
        M.disable(buf)
    elseif action == "toggle" then
        M.toggle(buf)
    elseif action == "refresh" then
        M.refresh(buf)
    else
        vim.notify(("lvim-indent: unknown action %q"):format(action), vim.log.levels.ERROR)
    end
end

--- Configure and start (idempotent — a second call re-merges config and re-validates, but the
--- provider, autocmds and the highlight bind are installed once).
---@param opts? LvimIndentConfig
---@return nil
function M.setup(opts)
    uu.merge(config, opts or {})
    validate_glyphs()
    if registered then
        -- A second setup() is a retune, and `own_option` is one of the values it can retune.
        require("lvim-indent.column").own(config.column.enabled and config.column.own_option)
        M.refresh()
        return
    end
    registered = true

    require("lvim-utils.highlight").bind(require("lvim-indent.highlights").build)
    require("lvim-indent.column").own(config.column.enabled and config.column.own_option)
    guides.setup()
    scope.setup()

    local aug = vim.api.nvim_create_augroup("LvimIndent", { clear = true })
    vim.api.nvim_create_autocmd("BufWipeout", {
        group = aug,
        callback = function(ev)
            cache.invalidate(ev.buf)
            guard.forget(ev.buf)
        end,
        desc = "lvim-indent: drop a wiped buffer's cache and per-buffer switch",
    })

    vim.api.nvim_create_user_command("LvimIndent", function(cmd)
        command(cmd.fargs)
    end, {
        nargs = "*",
        complete = function(_, line)
            local words = vim.split(vim.trim(line), "%s+")
            if #words <= 2 and not line:match("%s$") or #words == 1 then
                return { "enable", "disable", "toggle", "refresh" }
            end
            return { "buffer" }
        end,
        desc = "lvim-indent: enable | disable | toggle | refresh [buffer]",
    })
end

return M
