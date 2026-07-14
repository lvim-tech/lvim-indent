-- lvim-indent.anim: the optional scope grow — when the cursor lands in a new scope, the
-- painted range GROWS from the cursor line outward over a few frames (uv timer, ~60fps),
-- instead of appearing at once. Purely decorative and never blocking: each frame only moves
-- `progress` and asks the window to repaint; the decoration provider clamps the already-
-- resolved scope rows through clamp(). frames = 0 (the default) short-circuits to instant.
--
---@module "lvim-indent.anim"

local config = require("lvim-indent.config")

local uv = vim.uv

local M = {}

--- Grow fraction of the CURRENT scope: 0 = just the cursor line, 1 = the full range.
---@type number
local progress = 1

---@type uv.uv_timer_t|nil
local timer = nil

--- Frame interval in ms (~60fps).
---@type integer
local FRAME_MS = 16

--- Apply the configured easing to a linear frame fraction.
---@param t number  0..1
---@return number   0..1
local function ease(t)
    local kind = config.scope.animate.easing
    if kind == "out" then
        return 1 - (1 - t) * (1 - t)
    elseif kind == "in_out" then
        return t * t * (3 - 2 * t)
    end
    return t
end

--- Start the grow for a freshly resolved scope in `win`. With frames <= 0 the scope shows
--- full-size on the next repaint (no timer at all).
---@param win integer
---@return nil
function M.start(win)
    local frames = config.scope.animate.frames or 0
    if timer then
        timer:stop()
    end
    if frames <= 0 then
        progress = 1
        return
    end
    progress = 0
    local frame = 0
    if not timer then
        timer = uv.new_timer()
    end
    if not timer then
        progress = 1
        return
    end
    timer:start(FRAME_MS, FRAME_MS, function()
        frame = frame + 1
        progress = ease(math.min(1, frame / frames))
        if frame >= frames then
            ---@diagnostic disable-next-line: need-check-nil
            timer:stop()
        end
        vim.schedule(function()
            if vim.api.nvim_win_is_valid(win) then
                pcall(vim.api.nvim__redraw, { win = win, valid = false })
            end
        end)
    end)
end

--- Clamp a scope's body rows to the currently grown reach around `origin`.
---@param body_s integer  0-based first body row
---@param body_e integer  0-based last body row
---@param origin integer  The grow centre (cursor row at resolve time)
---@return integer s, integer e  The rows to paint this frame
function M.clamp(body_s, body_e, origin)
    if progress >= 1 or body_e < body_s then
        return body_s, body_e
    end
    local up = math.floor((origin - body_s) * progress + 0.5)
    local down = math.floor((body_e - origin) * progress + 0.5)
    return origin - up, origin + down
end

return M
