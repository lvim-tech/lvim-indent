-- Where an indent guide may be drawn, in DISPLAY columns.
--
-- Two things here are easy to get wrong and invisible once wrong. A line's indent STOPS are read
-- from its real whitespace — one per tab, and one per `shiftwidth` of spaces — never synthesised
-- as `0, sw, 2sw, …`, because with tab indentation where `sw ~= ts`, or with 'vartabstop', a stop
-- is not a multiple of anything. And a BLANK line borrows its depth from a neighbour: the deeper
-- one keeps a guide running through a gap inside a block, while `cap` takes the shallower one so
-- the gap before a top-level statement sprouts no phantom guides.

local cache = require("lvim-indent.cache")

--- A scratch buffer holding `lines`, with the given indent options.
---@param lines string[]
---@param opts { sw?: integer, ts?: integer, et?: boolean, vts?: string }
---@param fn fun(ctx: table, buf: integer)
local function on_buffer(lines, opts, fn)
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.bo[buf].shiftwidth = opts.sw or 4
    vim.bo[buf].tabstop = opts.ts or 8
    vim.bo[buf].expandtab = opts.et ~= false
    vim.bo[buf].vartabstop = opts.vts or ""
    local ok, err = pcall(fn, cache.ctx(buf), buf)
    cache.invalidate(buf)
    pcall(vim.api.nvim_buf_delete, buf, { force = true })
    if not ok then
        error(err, 0)
    end
end

---@param stops table[]
---@return integer[]
local function cols(stops)
    return vim.tbl_map(function(s)
        return s.col
    end, stops or {})
end

describe("lvim-indent.cache.info: a line's own indent")

it("measures the indent width in display columns", function()
    on_buffer({ "no indent", "    four", "        eight" }, { sw = 4 }, function(ctx, buf)
        eq(0, cache.info(ctx, buf, 0).width)
        eq(4, cache.info(ctx, buf, 1).width)
        eq(8, cache.info(ctx, buf, 2).width)
    end)
end)

it("puts a stop every shiftwidth of spaces", function()
    on_buffer({ "            twelve" }, { sw = 4 }, function(ctx, buf)
        eq({ 0, 4, 8 }, cols(cache.info(ctx, buf, 0).stops))
    end)
end)

it("follows a shiftwidth that is not four", function()
    on_buffer({ "      six" }, { sw = 2 }, function(ctx, buf)
        eq({ 0, 2, 4 }, cols(cache.info(ctx, buf, 0).stops))
    end)
end)

it("gives a TAB its own stop and advances to the next tabstop", function()
    -- With ts = 8 one tab reaches column 8, whatever shiftwidth says.
    on_buffer({ "\t\tbody" }, { sw = 4, ts = 8, et = false }, function(ctx, buf)
        local info = cache.info(ctx, buf, 0)
        eq({ 0, 8 }, cols(info.stops), "one stop per tab, at the column the tab starts in")
        eq(16, info.width)
    end)
end)

it("follows vartabstop, where a stop is a multiple of nothing", function()
    on_buffer({ "\t\tbody" }, { ts = 8, vts = "3,5", et = false }, function(ctx, buf)
        local info = cache.info(ctx, buf, 0)
        eq({ 0, 3 }, cols(info.stops), "the second tab starts at 3, not at 8")
        eq(8, info.width, "3 + 5")
    end)
end)

it("knows a blank line when it sees one", function()
    on_buffer({ "code", "", "   ", "code" }, { sw = 4 }, function(ctx, buf)
        eq(false, cache.info(ctx, buf, 0).blank)
        eq(true, cache.info(ctx, buf, 1).blank, "an empty line")
        eq(true, cache.info(ctx, buf, 2).blank, "a line of nothing but spaces")
    end)
end)

describe("lvim-indent.cache.blank_depth: a gap's borrowed depth")

it("takes the DEEPER neighbour, so a guide runs through a gap inside a block", function()
    on_buffer({ "        deep", "", "    shallow" }, { sw = 4 }, function(ctx, buf)
        eq(8, cache.blank_depth(ctx, buf, 1, false))
    end)
end)

it("takes the SHALLOWER neighbour when capped, so no phantom guides appear", function()
    on_buffer({ "        deep", "", "top level" }, { sw = 4 }, function(ctx, buf)
        eq(0, cache.blank_depth(ctx, buf, 1, true), "the gap before a top-level line draws nothing")
    end)
end)

it("borrows across a run of several blank lines", function()
    on_buffer({ "    four", "", "", "", "    four" }, { sw = 4 }, function(ctx, buf)
        for row = 1, 3 do
            eq(4, cache.blank_depth(ctx, buf, row, false), "row " .. row)
        end
    end)
end)

it("gives a gap at the top or bottom of the file no depth of its own", function()
    on_buffer({ "", "    four" }, { sw = 4 }, function(ctx, buf)
        eq(4, cache.blank_depth(ctx, buf, 0, false), "only the line below exists")
    end)
    on_buffer({ "    four", "" }, { sw = 4 }, function(ctx, buf)
        eq(4, cache.blank_depth(ctx, buf, 1, false), "only the line above exists")
    end)
    on_buffer({ "", "" }, { sw = 4 }, function(ctx, buf)
        eq(0, cache.blank_depth(ctx, buf, 0, false), "nothing to borrow from")
    end)
end)

describe("lvim-indent.cache.blank_stops: the stops a gap draws on")

it("draws on the REAL stops of the line it borrowed from", function()
    -- Tab indentation with sw ~= ts: the stops are 0 and 8, so a synthesised 0, 4, 8 would put a
    -- guide at column 4 where the lines above and below have none.
    on_buffer({ "\t\tbody", "", "\t\tbody" }, { sw = 4, ts = 8, et = false }, function(ctx, buf)
        local depth, stops = cache.blank_stops(ctx, buf, 1, false)
        eq(16, depth)
        eq({ 0, 8 }, cols(stops), "the gap must line up with the tabs above and below it")
    end)
end)

it("keeps only the stops shallower than the borrowed depth", function()
    on_buffer({ "            twelve", "", "    four" }, { sw = 4 }, function(ctx, buf)
        local depth, stops = cache.blank_stops(ctx, buf, 1, false)
        eq(12, depth)
        eq({ 0, 4, 8 }, cols(stops), "no stop at or past the depth itself")
    end)
end)

it("answers with no stops when there is no depth to draw", function()
    on_buffer({ "", "" }, { sw = 4 }, function(ctx, buf)
        local depth, stops = cache.blank_stops(ctx, buf, 0, false)
        eq(0, depth)
        truthy(stops == nil or #stops == 0, "got " .. vim.inspect(stops))
    end)
end)
