-- lvim-indent.chunk: the scope's SHAPE as a bracket — pure geometry, no drawing. The bracket
-- spans the scope's BODY rows at the scope's guide column (the header's indent), where every
-- cell is whitespace by construction: `╭` + a `─` run toward the code on the first body line,
-- `│` down the middle, `╰` + the run on the last. The corners bend INTO the block (they sit on
-- the body, not on the header/closing lines, whose text occupies the column) — so the bracket
-- works for top-level scopes too, and never needs to overwrite a character. A single-body-line
-- scope degrades to one horizontal run.
--
---@module "lvim-indent.chunk"

local config = require("lvim-indent.config")

local M = {}

--- The virt_text cell list for one chunk row.
---@param row integer     0-based row being painted
---@param body_s integer  0-based first body row (already animation-clamped)
---@param body_e integer  0-based last body row
---@param target integer  Display column the `─` run should stop BEFORE (the row's first text
---                       column, or scope col + shiftwidth on a blank row)
---@param col integer     The scope guide column the bracket sits on
---@param hl string       Highlight group for every cell
---@return table[]|nil    virt_text chunks ({text, hl} pairs), or nil when nothing fits
function M.cells(row, body_s, body_e, target, col, hl)
    local ch = config.chunk
    local glyph
    local run = false
    if body_s == body_e then
        glyph, run = ch.tail, true
    elseif row == body_s then
        glyph, run = ch.open, true
    elseif row == body_e then
        glyph, run = ch.close, true
    else
        glyph = ch.body
    end
    local cells = { { glyph, hl } }
    if run then
        for _ = col + 1, target - 1 do
            cells[#cells + 1] = { ch.tail, hl }
        end
    end
    return cells
end

return M
