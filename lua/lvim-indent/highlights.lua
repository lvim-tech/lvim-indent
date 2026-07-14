-- lvim-indent.highlights: every group from ONE build() factory reading the LIVE palette —
-- no inline colours anywhere else in the plugin. init.lua binds it via lvim-utils.highlight.bind,
-- so the whole set re-derives on ColorScheme / palette sync. Guides are thin GLYPHS, so the
-- tints here are FOREGROUND blends: accent blended toward the bg by the config strength
-- (1 = full accent). `nocombine` keeps a guide cell from inheriting underline/italic from
-- whatever syntax group sits under it.
--
---@module "lvim-indent.highlights"

local c = require("lvim-utils.colors")
local hl = require("lvim-utils.highlight")
local config = require("lvim-indent.config")

local M = {}

--- Resolve a config accent: a palette key ("blue") or a literal "#rrggbb".
---@param accent string
---@return string
local function col(accent)
    return c[accent] or accent
end

--- All lvim-indent groups from the live palette + live config.
---@return table<string, table>
function M.build()
    local levels = config.levels
    local scope = config.scope
    local groups = {
        -- The single-colour guide (rainbow off) …
        LvimIndentGuide = { fg = hl.blend(col(levels.accent), c.bg, levels.tint), nocombine = true },
        -- … the scope (a brighter guide + the show_start/show_end underlines) …
        LvimIndentScope = { fg = hl.blend(col(scope.accent), c.bg, scope.tint), nocombine = true },
        LvimIndentScopeStart = { sp = col(scope.accent), underline = true },
        LvimIndentScopeEnd = { sp = col(scope.accent), underline = true },
        -- … the chunk bracket (scope accent; the folded variant while a closed fold is inside) …
        LvimIndentChunk = { fg = hl.blend(col(scope.accent), c.bg, scope.tint), nocombine = true },
        LvimIndentChunkFolded = { fg = col(config.chunk.folded_accent), nocombine = true },
        -- … and the diagnostics-aware level tint (levels.diagnostics).
        LvimIndentDiagError = { fg = col(levels.diag_accents.error), nocombine = true },
        LvimIndentDiagWarn = { fg = col(levels.diag_accents.warn), nocombine = true },
    }
    -- The rainbow cycle: LvimIndentGuide1..N from levels.accents, one per depth.
    for i, accent in ipairs(levels.accents) do
        groups["LvimIndentGuide" .. i] = { fg = hl.blend(col(accent), c.bg, levels.tint), nocombine = true }
    end
    return groups
end

return M
