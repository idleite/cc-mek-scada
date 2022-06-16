-- Horizontal Bar Graphics Element

local util    = require("scada-common.util")

local element = require("graphics.element")

---@class hbar_args
---@field show_percent? boolean whether or not to show the percent
---@field bar_fg_bg? cpair bar foreground/background colors if showing percent
---@field parent graphics_element
---@field x? integer 1 if omitted
---@field y? integer 1 if omitted
---@field width? integer parent width if omitted
---@field height? integer parent height if omitted
---@field gframe? graphics_frame frame instead of x/y/width/height
---@field fg_bg? cpair foreground/background colors

-- new horizontal bar
---@param args hbar_args
local function hbar(args)
    -- properties/state
    local last_num_bars = -1

    -- create new graphics element base object
    local e = element.new(args)

    -- bar width is width - 5 characters for " 100%" if showing percent
    local bar_width = util.trinary(args.show_percent, e.frame.w - 5, e.frame.w)

    assert(bar_width > 0, "graphics.elements.indicators.hbar: too small for bar")

    -- determine bar colors
    local bar_bkg = e.fg_bg.blit_bkg
    local bar_fgd = e.fg_bg.blit_fgd
    if args.show_percent and args.bar_fg_bg ~= nil then
        bar_bkg = args.bar_fg_bg.blit_bkg
        bar_fgd = args.bar_fg_bg.blit_fgd
    end

    -- handle data changes
    function e.on_update(fraction)
        -- enforce minimum and maximum
        if fraction < 0 then
            fraction = 0.0
        elseif fraction > 1 then
            fraction = 1.0
        end

        -- compute number of bars
        local num_bars = util.round(fraction * (bar_width * 2))
        util.print(num_bars)

        -- redraw bar if changed
        if num_bars ~= last_num_bars then
            last_num_bars = num_bars

            local fgd = ""
            local bkg = ""
            local spaces = ""

            -- fill percentage
            for _ = 1, num_bars / 2 do
                spaces = spaces .. " "
                fgd = fgd .. bar_fgd
                bkg = bkg .. bar_bkg
            end

            -- add fractional bar if needed
            if num_bars % 2 == 1 then
                spaces = spaces .. "\x95"
                fgd = fgd .. bar_bkg
                bkg = bkg .. bar_fgd
            end

            -- pad background
            for _ = 1, ((bar_width * 2) - num_bars) / 2 do
                spaces = spaces .. " "
                fgd = fgd .. bar_bkg
                bkg = bkg .. bar_bkg
            end

            -- draw bar
            for y = 1, e.frame.h do
                e.window.setCursorPos(1, y)
                -- intentionally swapped fgd/bkg since we use spaces as fill, but they are the opposite
                e.window.blit(spaces, bkg, fgd)
            end
        end

        -- update percentage
        if args.show_percent then
            e.window.setCursorPos(bar_width + 1, math.max(1, math.ceil(e.frame.h / 2)))
            e.window.write(util.sprintf("%3.0f%%", fraction * 100))
        end
    end

    return e.get()
end

return hbar
