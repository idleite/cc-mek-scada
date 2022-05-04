local log = require("scada-common.log")

--
-- Protected Peripheral Manager
--

local ppm = {}

local ACCESS_FAULT = nil

ppm.ACCESS_FAULT = ACCESS_FAULT

----------------------------
-- PRIVATE DATA/FUNCTIONS --
----------------------------

local _ppm_sys = {
    mounts = {},
    auto_cf = false,
    faulted = false,
    terminate = false,
    mute = false
}

-- wrap peripheral calls with lua protected call
-- we don't want a disconnect to crash a program
-- also provides peripheral-specific fault checks (auto-clear fault defaults to true)
local peri_init = function (iface)
    local self = {
        faulted = false,
        auto_cf = true,
        type = peripheral.getType(iface),
        device = peripheral.wrap(iface)
    }

    -- initialization process (re-map)

    for key, func in pairs(self.device) do
        self.device[key] = function (...)
            local status, result = pcall(func, ...)

            if status then
                -- auto fault clear
                if self.auto_cf then self.faulted = false end
                if _ppm_sys.auto_cf then _ppm_sys.faulted = false end
                return result
            else
                -- function failed
                self.faulted = true
                _ppm_sys.faulted = true

                if not _ppm_sys.mute then
                    log.error("PPM: protected " .. key .. "() -> " .. result)
                end

                if result == "Terminated" then
                    _ppm_sys.terminate = true
                end

                return ACCESS_FAULT
            end
        end
    end

    -- fault management functions

    local clear_fault = function () self.faulted = false end
    local is_faulted = function () return self.faulted end
    local is_ok = function () return not self.faulted end

    local enable_afc = function () self.auto_cf = true end
    local disable_afc = function () self.auto_cf = false end

    -- append to device functions

    self.device.__p_clear_fault = clear_fault
    self.device.__p_is_faulted  = is_faulted
    self.device.__p_is_ok       = is_ok
    self.device.__p_enable_afc  = enable_afc
    self.device.__p_disable_afc = disable_afc

    return {
        type = self.type,
        dev = self.device
    }
end

----------------------
-- PUBLIC FUNCTIONS --
----------------------

-- REPORTING --

-- silence error prints
ppm.disable_reporting = function ()
    _ppm_sys.mute = true
end

-- allow error prints
ppm.enable_reporting = function ()
    _ppm_sys.mute = false
end

-- FAULT MEMORY --

-- enable automatically clearing fault flag
ppm.enable_afc = function ()
    _ppm_sys.auto_cf = true
end

-- disable automatically clearing fault flag
ppm.disable_afc = function ()
    _ppm_sys.auto_cf = false
end

-- check fault flag
ppm.is_faulted = function ()
    return _ppm_sys.faulted
end

-- clear fault flag
ppm.clear_fault = function ()
    _ppm_sys.faulted = false
end

-- TERMINATION --

-- if a caught error was a termination request
ppm.should_terminate = function ()
    return _ppm_sys.terminate
end

-- MOUNTING --

-- mount all available peripherals (clears mounts first)
ppm.mount_all = function ()
    local ifaces = peripheral.getNames()

    _ppm_sys.mounts = {}

    for i = 1, #ifaces do
        _ppm_sys.mounts[ifaces[i]] = peri_init(ifaces[i])

        log.info("PPM: found a " .. _ppm_sys.mounts[ifaces[i]].type .. " (" .. ifaces[i] .. ")")
    end

    if #ifaces == 0 then
        log.warning("PPM: mount_all() -> no devices found")
    end
end

-- mount a particular device
ppm.mount = function (iface)
    local ifaces = peripheral.getNames()
    local pm_dev = nil
    local pm_type = nil

    for i = 1, #ifaces do
        if iface == ifaces[i] then
            log.info("PPM: mount(" .. iface .. ") -> found a " .. peripheral.getType(iface))

            _ppm_sys.mounts[iface] = peri_init(iface)

            pm_type = _ppm_sys.mounts[iface].type
            pm_dev = _ppm_sys.mounts[iface].dev
            break
        end
    end

    return pm_type, pm_dev
end

-- handle peripheral_detach event
ppm.handle_unmount = function (iface)
    -- what got disconnected?
    local lost_dev = _ppm_sys.mounts[iface]

    if lost_dev then
        local type = lost_dev.type
        log.warning("PPM: lost device " .. type .. " mounted to " .. iface)
    else
        log.error("PPM: lost device unknown to the PPM mounted to " .. iface)
    end

    return lost_dev
end

-- GENERAL ACCESSORS --

-- list all available peripherals
ppm.list_avail = function ()
    return peripheral.getNames()
end

-- list mounted peripherals
ppm.list_mounts = function ()
    return _ppm_sys.mounts
end

-- get a mounted peripheral by side/interface
ppm.get_periph = function (iface)
    if _ppm_sys.mounts[iface] then
        return _ppm_sys.mounts[iface].dev
    else return nil end
end

-- get a mounted peripheral type by side/interface
ppm.get_type = function (iface)
    if _ppm_sys.mounts[iface] then
        return _ppm_sys.mounts[iface].type
    else return nil end
end

-- get all mounted peripherals by type
ppm.get_all_devices = function (name)
    local devices = {}

    for side, data in pairs(_ppm_sys.mounts) do
        if data.type == name then
            table.insert(devices, data.dev)
        end
    end

    return devices
end

-- get a mounted peripheral by type (if multiple, returns the first)
ppm.get_device = function (name)
    local device = nil

    for side, data in pairs(_ppm_sys.mounts) do
        if data.type == name then
            device = data.dev
            break
        end
    end
    
    return device
end

-- SPECIFIC DEVICE ACCESSORS --

-- get the fission reactor (if multiple, returns the first)
ppm.get_fission_reactor = function ()
    return ppm.get_device("fissionReactor")
end

-- get the wireless modem (if multiple, returns the first)
ppm.get_wireless_modem = function ()
    local w_modem = nil

    for side, device in pairs(_ppm_sys.mounts) do
        if device.type == "modem" and device.dev.isWireless() then
            w_modem = device.dev
            break
        end
    end

    return w_modem
end

-- list all connected monitors
ppm.list_monitors = function ()
    return ppm.get_all_devices("monitor")
end

return ppm
