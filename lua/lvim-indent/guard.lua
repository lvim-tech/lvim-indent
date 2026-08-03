-- lvim-indent.guard: the exclusion decision — is this buffer real content that gets guides?
-- The set-wide rule first: a buffer with `buftype ~= ""` (panels, trees, terminals, the
-- dashboard, quickfix, help, prompts) is out BY CONSTRUCTION, never by name — chrome is not
-- content. The config lists only carry the exceptions among real files (a markdown prose
-- buffer, say) plus the size limit. decide() returns the REASON too, so :checkhealth can
-- answer "why do I see no guides here?" — the single most-asked question of this plugin kind.
--
---@module "lvim-indent.guard"

local config = require("lvim-indent.config")

local M = {}

--- Per-buffer disable set (:LvimIndent disable buffer / require("lvim-indent").disable(buf)).
---@type table<integer, boolean>
local disabled = {}

--- Flip a buffer's own switch.
---@param buf integer
---@param on boolean
---@return nil
function M.set_enabled(buf, on)
    disabled[buf] = (not on) or nil
end

--- A buffer's own switch (true unless explicitly disabled).
---@param buf integer
---@return boolean
function M.buf_enabled(buf)
    return not disabled[buf]
end

--- Drop a wiped buffer's entry.
---@param buf integer
---@return nil
function M.forget(buf)
    disabled[buf] = nil
end

--- The full decision for a buffer, with the reason when it is out.
---@param buf integer
---@return boolean allowed
---@return string reason  "ok", or why the buffer gets no guides
function M.decide(buf)
    if not config.enabled then
        return false, "lvim-indent is disabled (:LvimIndent enable)"
    end
    if disabled[buf] then
        return false, "this buffer is disabled (:LvimIndent enable buffer)"
    end
    if not vim.api.nvim_buf_is_valid(buf) then
        return false, "invalid buffer"
    end
    local bt = vim.bo[buf].buftype
    if bt ~= "" then
        -- The by-construction guard already rejects EVERY non-empty buftype, so a `config.exclude.buftypes`
        -- allow/deny list would be unreachable — the option was removed rather than shipped dead.
        return false, ('buftype "%s" is not file content (built-in guard)'):format(bt)
    end
    local ft = vim.bo[buf].filetype
    for _, f in ipairs(config.exclude.filetypes) do
        if f == ft then
            return false, ('filetype "%s" is in exclude.filetypes'):format(ft)
        end
    end
    local limit = config.max_file_lines or 0
    if limit > 0 and vim.api.nvim_buf_line_count(buf) > limit then
        return false, ("more than max_file_lines (%d) lines"):format(limit)
    end
    return true, "ok"
end

--- The RULER's decision, which is deliberately not the guides' one.
---
--- A ruler is not an indent guide: `exclude.filetypes` says "this file's indentation is not worth
--- drawing", which has nothing to say about where column 80 is. Tying them together meant the
--- ruler silently vanished in every excluded filetype — json here — and the report was "it does
--- not work", with nothing on screen to suggest why. The by-construction buftype guard still
--- applies (no rulers in panels or trees), and `column.exclude_filetypes` is the ruler's own lever.
---@param buf integer
---@return boolean
function M.column_allowed(buf)
    local cfg = config.column
    if not config.enabled or not cfg.enabled or disabled[buf] then
        return false
    end
    if not vim.api.nvim_buf_is_valid(buf) or vim.bo[buf].buftype ~= "" then
        return false
    end
    local ft = vim.bo[buf].filetype
    for _, f in ipairs(cfg.exclude_filetypes or {}) do
        if f == ft then
            return false
        end
    end
    return true
end

--- The boolean decision (the hot path — one call per window per redraw).
---@param buf integer
---@return boolean
function M.allowed(buf)
    return (M.decide(buf))
end

return M
