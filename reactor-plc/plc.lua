-- #REQUIRES comms.lua

function scada_link(plc_comms)
    local linked = false
    local link_timeout = os.startTimer(5)

    plc_comms.send_link_req()
    print_ts("sent link request")
    
    repeat
        local event, p1, p2, p3, p4, p5 = os.pullEvent()
    
        -- handle event
        if event == "timer" and param1 == link_timeout then
            -- no response yet
            print("...no response");
        elseif event == "modem_message" then
            -- server response? cancel timeout
            if link_timeout ~= nil then
                os.cancelTimer(link_timeout)
            end

            local packet = plc_comms.parse_packet(p1, p2, p3, p4, p5)
            if packet then
                -- handle response
                local response = plc_comms.handle_link(packet)
                if response == nil then
                    print_ts("invalid link response, bad channel?\n")
                    break
                elseif response == comms.RPLC_LINKING.COLLISION then
                    print_ts("...reactor PLC ID collision (check config), exiting...\n")
                    break
                elseif response == comms.RPLC_LINKING.ALLOW then
                    print_ts("...linked!\n")
                    linked = true
                    plc_comms.send_rs_io_conns()
                    plc_comms.send_struct()
                    plc_comms.send_status()
                    print_ts("sent initial data\n")
                else
                    print_ts("...denied, exiting...\n")
                    break
                end
            end
        end
    until linked

    return linked
end

-- Internal Safety System
-- identifies dangerous states and SCRAMs reactor if warranted
-- autonomous from main control
function iss_init(reactor)
    local self = {
        reactor = reactor,
        timed_out = false,
        tripped = false,
        trip_cause = ""
    }

    local check = function ()
        local status = "ok"
        local was_tripped = self.tripped
        
        -- check system states in order of severity
        if self.damage_critical() then
            status = "dmg_crit"
        elseif self.high_temp() then
            status = "high_temp"
        elseif self.excess_heated_coolant() then
            status = "heated_coolant_backup"
        elseif self.excess_waste() then
            status = "full_waste"
        elseif self.insufficient_fuel() then
            status = "no_fuel"
        elseif self.tripped then
            status = self.trip_cause
        else
            self.tripped = false
        end
    
        if status ~= "ok" then
            self.tripped = true
            self.trip_cause = status
            self.reactor.scram()
        end

        local first_trip = ~was_tripped and self.tripped
    
        return self.tripped, status, first_trip
    end

    local trip_timeout = function ()
        self.tripped = false
        self.trip_cause = "timeout"
        self.timed_out = true
        self.reactor.scram()
    end

    local reset = function ()
        self.timed_out = false
        self.tripped = false
        self.trip_cause = ""
    end

    local status = function (named)
        if named then
            return {
                damage_critical = damage_critical(),
                excess_heated_coolant = excess_heated_coolant(),
                excess_waste = excess_waste(),
                high_temp = high_temp(),
                insufficient_fuel = insufficient_fuel(),
                no_coolant = no_coolant(),
                timed_out = timed_out()
            }
        else
            return {
                damage_critical(),
                excess_heated_coolant(),
                excess_waste(),
                high_temp(),
                insufficient_fuel(),
                no_coolant(),
                timed_out()
            }
        end
    end
    
    local damage_critical = function ()
        return self.reactor.getDamagePercent() >= 100
    end
    
    local excess_heated_coolant = function ()
        return self.reactor.getHeatedCoolantNeeded() == 0
    end
    
    local excess_waste = function ()
        return self.reactor.getWasteNeeded() == 0
    end

    local high_temp = function ()
        -- mekanism: MAX_DAMAGE_TEMPERATURE = 1_200
        return self.reactor.getTemperature() >= 1200
    end
    
    local insufficient_fuel = function ()
        return self.reactor.getFuel() == 0
    end

    local no_coolant = function ()
        return self.reactor.getCoolantFilledPercentage() < 2
    end

    local timed_out = function ()
        return self.timed_out
    end

    return {
        check = check,
        trip_timeout = trip_timeout,
        reset = reset,
        status = status,
        damage_critical = damage_critical,
        excess_heated_coolant = excess_heated_coolant,
        excess_waste = excess_waste,
        high_temp = high_temp,
        insufficient_fuel = insufficient_fuel,
        no_coolant = no_coolant,
        timed_out = timed_out
    }
end

-- reactor PLC communications
function rplc_comms(id, modem, local_port, server_port, reactor)
    local self = {
        id = id,
        seq_num = 0,
        modem = modem,
        s_port = server_port,
        l_port = local_port,
        reactor = reactor,
        status_cache = nil
    }

    -- PRIVATE FUNCTIONS --

    local _send = function (msg)
        local packet = scada_packet()
        packet.make(self.seq_num, PROTOCOLS.RPLC, msg)
        self.modem.transmit(self.s_port, self.l_port, packet.raw())
        self.seq_num = self.seq_num + 1
    end

    -- variable reactor status information, excluding heating rate
    local _reactor_status = function ()
        return {
            status     = self.reactor.getStatus(),
            burn_rate  = self.reactor.getBurnRate(),
            act_burn_r = self.reactor.getActualBurnRate(),
            temp       = self.reactor.getTemperature(),
            damage     = self.reactor.getDamagePercent(),
            boil_eff   = self.reactor.getBoilEfficiency(),
            env_loss   = self.reactor.getEnvironmentalLoss(),

            fuel       = self.reactor.getFuel(),
            fuel_need  = self.reactor.getFuelNeeded(),
            fuel_fill  = self.reactor.getFuelFilledPercentage(),
            waste      = self.reactor.getWaste(),
            waste_need = self.reactor.getWasteNeeded(),
            waste_fill = self.reactor.getWasteFilledPercentage(),
            cool_type  = self.reactor.getCoolant()['name'],
            cool_amnt  = self.reactor.getCoolant()['amount'],
            cool_need  = self.reactor.getCoolantNeeded(),
            cool_fill  = self.reactor.getCoolantFilledPercentage(),
            hcool_type = self.reactor.getHeatedCoolant()['name'],
            hcool_amnt = self.reactor.getHeatedCoolant()['amount'],
            hcool_need = self.reactor.getHeatedCoolantNeeded(),
            hcool_fill = self.reactor.getHeatedCoolantFilledPercentage()
        }
    end

    local _update_status_cache = function ()
        local status = _reactor_status()
        local changed = false

        for key, value in pairs(status) do
            if value ~= self.status_cache[key] then
                changed = true
                break
            end
        end

        if changed then
            self.status_cache = status
        end

        return changed
    end

    -- PUBLIC FUNCTIONS --

    -- parse an RPLC packet
    local parse_packet = function(side, sender, reply_to, message, distance)
        local pkt = nil
        local s_pkt = scada_packet()

        -- parse packet as generic SCADA packet
        s_pkt.recieve(side, sender, reply_to, message, distance)

        -- get using RPLC protocol format
        if s_pkt.is_valid() and s_pkt.protocol() == PROTOCOLS.RPLC then
            local body = s_pkt.data()
            if #body > 2 then
                pkt = {
                    scada_frame = s_pkt,
                    id = body[1],
                    type = body[2],
                    length = #body - 2,
                    body = { table.unpack(body, 3, 2 + #body) }
                }
            end
        end

        return pkt
    end

    -- handle a linking packet
    local handle_link = function (packet)
        if packet.type == RPLC_TYPES.LINK_REQ then
            return packet.data[1] == RPLC_LINKING.ALLOW
        else
            return nil
        end
    end

    -- handle an RPLC packet
    local handle_packet = function (packet)
        if packet.type == RPLC_TYPES.KEEP_ALIVE then
            -- keep alive request received, nothing to do except feed watchdog
        elseif packet.type == RPLC_TYPES.MEK_STRUCT then
            -- request for physical structure
            send_struct()
        elseif packet.type == RPLC_TYPES.RS_IO_CONNS then
            -- request for redstone connections
            send_rs_io_conns()
        elseif packet.type == RPLC_TYPES.RS_IO_GET then
        elseif packet.type == RPLC_TYPES.RS_IO_SET then
        elseif packet.type == RPLC_TYPES.MEK_SCRAM then
        elseif packet.type == RPLC_TYPES.MEK_ENABLE then
        elseif packet.type == RPLC_TYPES.MEK_BURN_RATE then
        elseif packet.type == RPLC_TYPES.ISS_GET then
        elseif packet.type == RPLC_TYPES.ISS_CLEAR then
        end
    end

    -- attempt to establish link with supervisor
    local send_link_req = function ()
        local linking_data = {
            id = self.id,
            type = RPLC_TYPES.LINK_REQ
        }

        _send(linking_data)
    end

    -- send structure properties (these should not change)
    -- (server will cache these)
    local send_struct = function ()
        local mek_data = {
            heat_cap  = self.reactor.getHeatCapacity(),
            fuel_asm  = self.reactor.getFuelAssemblies(),
            fuel_sa   = self.reactor.getFuelSurfaceArea(),
            fuel_cap  = self.reactor.getFuelCapacity(),
            waste_cap = self.reactor.getWasteCapacity(),
            cool_cap  = self.reactor.getCoolantCapacity(),
            hcool_cap = self.reactor.getHeatedCoolantCapacity(),
            max_burn  = self.reactor.getMaxBurnRate()
        }

        local struct_packet = {
            id = self.id,
            type = RPLC_TYPES.MEK_STRUCT,
            mek_data = mek_data
        }

        _send(struct_packet)
    end

    -- send live status information
    -- control_state : acknowledged control state from supervisor
    -- overridden    : if ISS force disabled reactor
    local send_status = function (control_state, overridden)
        local mek_data = nil

        if _update_status_cache() then
            mek_data = self.status_cache
        end

        local sys_status = {
            id = self.id,
            type = RPLC_TYPES.STATUS,
            timestamp = os.time(),
            control_state = control_state,
            overridden = overridden,
            heating_rate = self.reactor.getHeatingRate(),
            mek_data = mek_data
        }

        _send(sys_status)
    end

    return {
        parse_packet = parse_packet,
        handle_link = handle_link,
        handle_packet = handle_packet,
        send_link_req = send_link_req,
        send_struct = send_struct,
        send_status = send_status
    }
end
