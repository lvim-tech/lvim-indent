-- lvim-indent.statuscolumn: the scope as a GUTTER component instead of an overlay — an
-- optional cell the set's statuscolumn (lvim-hud chrome) can host. When
-- config.statuscolumn.enabled is on, the in-text scope guide is suppressed (the chunk styles
-- still draw per scope.style) and this component shows the bracket in the number column
-- instead. Evaluated per line by the 'statuscolumn' engine (v:lnum; the window being drawn is
-- the CURRENT window during evaluation, like 'statusline').
--
-- Usage inside a 'statuscolumn' expression:
--   %{%v:lua.require'lvim-indent.statuscolumn'.component()%}
--
---@module "lvim-indent.statuscolumn"

local config = require("lvim-indent.config")
local scope = require("lvim-indent.scope")

local M = {}

--- The one-cell component for the line being drawn: the chunk's corner/vertical inside the
--- scope body, a plain space everywhere else (so the gutter width never jumps).
---@return string
function M.component()
    if not config.statuscolumn.enabled then
        return ""
    end
    local st = scope.active
    local win = vim.api.nvim_get_current_win()
    local row = vim.v.lnum - 1
    if not st or st.win ~= win or row < st.body_s or row > st.body_e then
        return " "
    end
    local ch = config.chunk.body
    if st.body_s == st.body_e then
        ch = config.chunk.tail
    elseif row == st.body_s then
        ch = config.chunk.open
    elseif row == st.body_e then
        ch = config.chunk.close
    end
    return "%#LvimIndentScope#" .. ch .. "%*"
end

return M
