local util = require("scada-common.util")

--
-- File System Logger
--

---@class log
local log = {}

---@alias MODE integer
local MODE = {
    APPEND = 0,
    NEW = 1
}

log.MODE = MODE

-- whether to log debug messages or not
local LOG_DEBUG = true

local _log_sys = {
    path = "/log.txt",
    mode = MODE.APPEND,
    file = nil,
    dmesg_out = nil
}

---@type function
local free_space = fs.getFreeSpace

-- initialize logger
---@param path string file path
---@param write_mode MODE
---@param dmesg_redirect? table terminal/window to direct dmesg to
log.init = function (path, write_mode, dmesg_redirect)
    _log_sys.path = path
    _log_sys.mode = write_mode

    if _log_sys.mode == MODE.APPEND then
        _log_sys.file = fs.open(path, "a")
    else
        _log_sys.file = fs.open(path, "w")
    end

    if dmesg_redirect then
        _log_sys.dmesg_out = dmesg_redirect
    else
        _log_sys.dmesg_out = term.current()
    end
end

-- direct dmesg output to a monitor/window
---@param window table window or terminal reference
log.direct_dmesg = function (window)
    _log_sys.dmesg_out = window
end

-- private log write function
---@param msg string
local _log = function (msg)
    local time_stamp = os.date("[%c] ")
    local stamped = time_stamp .. util.strval(msg)

    -- attempt to write log
    local status, result = pcall(function ()
        _log_sys.file.writeLine(stamped)
        _log_sys.file.flush()
    end)

    -- if we don't have space, we need to create a new log file

    if not status then
        if result == "Out of space" then
            -- will delete log file
        elseif result ~= nil then
            util.println("unknown error writing to logfile: " .. result)
        end
    end

    if (result == "Out of space") or (free_space(_log_sys.path) < 100) then
        -- delete the old log file and open a new one
        _log_sys.file.close()
        fs.delete(_log_sys.path)
        log.init(_log_sys.path, _log_sys.mode)

        -- leave a message
        _log_sys.file.writeLine(time_stamp .. "recycled log file")
        _log_sys.file.writeLine(stamped)
        _log_sys.file.flush()
    end
end

-- dmesg style logging for boot because I like linux-y things
---@param msg string message
---@param tag? string log tag
---@param tag_color? integer log tag color
log.dmesg = function (msg, tag, tag_color)
    msg = util.strval(msg)
    tag = tag or ""
    tag = util.strval(tag)

    local t_stamp = string.format("%12.2f", os.clock())
    local out = _log_sys.dmesg_out
    local out_w, out_h = out.getSize()

    local lines = { msg }

    -- wrap if needed
    if string.len(msg) > out_w then
        local remaining = true
        local s_start = 1
        local s_end = out_w
        local i = 1

        lines = {}

        while remaining do
            local line = string.sub(msg, s_start, s_end)

            if line == "" then
                remaining = false
            else
                lines[i] = line

                s_start = s_end + 1
                s_end = s_end + out_w
                i = i + 1
            end
        end
    end

    -- start output with tag and time, assuming we have enough width for this to be on one line
    local cur_x, cur_y = out.getCursorPos()

    if cur_x > 1 then
        if cur_y == out_h then
            out.scroll(1)
            out.setCursorPos(1, cur_y)
        else
            out.setCursorPos(1, cur_y + 1)
        end
    end

    -- colored time
    local initial_color = out.getTextColor()
    out.setTextColor(colors.white)
    out.write("[")
    out.setTextColor(colors.lightGray)
    out.write(t_stamp)
    out.setTextColor(colors.white)
    out.write("] ")

    -- colored tag
    if tag ~= "" then
        out.write("[")
        out.setTextColor(tag_color)
        out.write(tag)
        out.setTextColor(colors.white)
        out.write("] ")
    end

    out.setTextColor(initial_color)

    -- output message
    for i = 1, #lines do
        cur_x, cur_y = out.getCursorPos()

        if i > 1 and cur_x > 1 then
            if cur_y == out_h then
                out.scroll(1)
                out.setCursorPos(1, cur_y)
            else
                out.setCursorPos(1, cur_y + 1)
            end
        end

        out.write(lines[i])
    end

    _log("[" .. t_stamp .. "] " .. tag .. " " .. msg)
end

-- log debug messages
---@param msg string message
---@param trace? boolean include file trace
log.debug = function (msg, trace)
    if LOG_DEBUG then
        local dbg_info = ""

        if trace then
            local info = debug.getinfo(2)
            local name = ""

            if info.name ~= nil then
                name = ":" .. info.name .. "():"
            end

            dbg_info = info.short_src .. ":" .. name .. info.currentline .. " > "
        end

        _log("[DBG] " .. dbg_info .. util.strval(msg))
    end
end

-- log info messages
---@param msg string message
log.info = function (msg)
    _log("[INF] " .. util.strval(msg))
end

-- log warning messages
---@param msg string message
log.warning = function (msg)
    _log("[WRN] " .. util.strval(msg))
end

-- log error messages
---@param msg string message
---@param trace? boolean include file trace
log.error = function (msg, trace)
    local dbg_info = ""

    if trace then
        local info = debug.getinfo(2)
        local name = ""

        if info.name ~= nil then
            name = ":" .. info.name .. "():"
        end

        dbg_info = info.short_src .. ":" .. name ..  info.currentline .. " > "
    end

    _log("[ERR] " .. dbg_info .. util.strval(msg))
end

-- log fatal errors
---@param msg string message
log.fatal = function (msg)
    _log("[FTL] " .. util.strval(msg))
end

return log
