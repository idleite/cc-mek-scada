local comms = require("scada-common.comms")
local log = require("scada-common.log")
local util = require("scada-common.util")

local svsessions = require("supervisor.session.svsessions")

local supervisor = {}

local PROTOCOLS = comms.PROTOCOLS
local RPLC_TYPES = comms.RPLC_TYPES
local RPLC_LINKING = comms.RPLC_LINKING
local SCADA_MGMT_TYPES = comms.SCADA_MGMT_TYPES
local RTU_ADVERT_TYPES = comms.RTU_ADVERT_TYPES

local SESSION_TYPE = svsessions.SESSION_TYPE

local print = util.print
local println = util.println
local print_ts = util.print_ts
local println_ts = util.println_ts

-- supervisory controller communications
---@param num_reactors integer
---@param modem table
---@param dev_listen integer
---@param coord_listen integer
supervisor.comms = function (num_reactors, modem, dev_listen, coord_listen)
    local self = {
        ln_seq_num = 0,
        num_reactors = num_reactors,
        modem = modem,
        dev_listen = dev_listen,
        coord_listen = coord_listen,
        reactor_struct_cache = nil
    }

    ---@class superv_comms
    local public = {}

    -- PRIVATE FUNCTIONS --

    -- open all channels
    local _open_channels = function ()
        if not self.modem.isOpen(self.dev_listen) then
            self.modem.open(self.dev_listen)
        end

        if not self.modem.isOpen(self.coord_listen) then
            self.modem.open(self.coord_listen)
        end
    end

    -- open at construct time
    _open_channels()

    -- link modem to svsessions
    svsessions.link_modem(self.modem)

    -- send PLC link request responses
    ---@param dest integer
    ---@param msg table
    local _send_plc_linking = function (dest, msg)
        local s_pkt = comms.scada_packet()
        local r_pkt = comms.rplc_packet()

        r_pkt.make(0, RPLC_TYPES.LINK_REQ, msg)
        s_pkt.make(self.ln_seq_num, PROTOCOLS.RPLC, r_pkt.raw_sendable())

        self.modem.transmit(dest, self.dev_listen, s_pkt.raw_sendable())
        self.ln_seq_num = self.ln_seq_num + 1
    end

    -- PUBLIC FUNCTIONS --

    -- reconnect a newly connected modem
    ---@param modem table
---@diagnostic disable-next-line: redefined-local
    public.reconnect_modem = function (modem)
        self.modem = modem
        svsessions.link_modem(self.modem)
        _open_channels()
    end

    -- parse a packet
    ---@param side string
    ---@param sender integer
    ---@param reply_to integer
    ---@param message any
    ---@param distance integer
    ---@return modbus_frame|rplc_frame|mgmt_frame|coord_frame|nil packet
    public.parse_packet = function(side, sender, reply_to, message, distance)
        local pkt = nil
        local s_pkt = comms.scada_packet()

        -- parse packet as generic SCADA packet
        s_pkt.receive(side, sender, reply_to, message, distance)

        if s_pkt.is_valid() then
            -- get as MODBUS TCP packet
            if s_pkt.protocol() == PROTOCOLS.MODBUS_TCP then
                local m_pkt = comms.modbus_packet()
                if m_pkt.decode(s_pkt) then
                    pkt = m_pkt.get()
                end
            -- get as RPLC packet
            elseif s_pkt.protocol() == PROTOCOLS.RPLC then
                local rplc_pkt = comms.rplc_packet()
                if rplc_pkt.decode(s_pkt) then
                    pkt = rplc_pkt.get()
                end
            -- get as SCADA management packet
            elseif s_pkt.protocol() == PROTOCOLS.SCADA_MGMT then
                local mgmt_pkt = comms.mgmt_packet()
                if mgmt_pkt.decode(s_pkt) then
                    pkt = mgmt_pkt.get()
                end
            -- get as coordinator packet
            elseif s_pkt.protocol() == PROTOCOLS.COORD_DATA then
                local coord_pkt = comms.coord_packet()
                if coord_pkt.decode(s_pkt) then
                    pkt = coord_pkt.get()
                end
            else
                log.debug("attempted parse of illegal packet type " .. s_pkt.protocol(), true)
            end
        end

        return pkt
    end

    -- handle a packet
    ---@param packet modbus_frame|rplc_frame|mgmt_frame|coord_frame
    public.handle_packet = function(packet)
        if packet ~= nil then
            local l_port = packet.scada_frame.local_port()
            local r_port = packet.scada_frame.remote_port()
            local protocol = packet.scada_frame.protocol()

            -- device (RTU/PLC) listening channel
            if l_port == self.dev_listen then
                -- look for an associated session
                local session = svsessions.find_session(r_port)

                if protocol == PROTOCOLS.MODBUS_TCP then
                    -- MODBUS response
                elseif protocol == PROTOCOLS.RPLC then
                    -- reactor PLC packet
                    if session ~= nil then
                        if packet.type == RPLC_TYPES.LINK_REQ then
                            -- new device on this port? that's a collision
                            log.debug("PLC_LNK: request from existing connection received on " .. r_port .. ", responding with collision")
                            _send_plc_linking(r_port, { RPLC_LINKING.COLLISION })
                        else
                            -- pass the packet onto the session handler
                            session.in_queue.push_packet(packet)
                        end
                    else
                        -- unknown session, is this a linking request?
                        if packet.type == RPLC_TYPES.LINK_REQ then
                            if packet.length == 1 then
                                -- this is a linking request
                                local plc_id = svsessions.establish_plc_session(l_port, r_port, packet.data[1])
                                if plc_id == false then
                                    -- reactor already has a PLC assigned
                                    log.debug("PLC_LNK: assignment collision with reactor " .. packet.data[1])
                                    _send_plc_linking(r_port, { RPLC_LINKING.COLLISION })
                                else
                                    -- got an ID; assigned to a reactor successfully
                                    println("connected to reactor " .. packet.data[1] .. " PLC (port " .. r_port .. ")")
                                    log.debug("PLC_LNK: allowed for device at " .. r_port)
                                    _send_plc_linking(r_port, { RPLC_LINKING.ALLOW })
                                end
                            else
                                log.debug("PLC_LNK: new linking packet length mismatch")
                            end
                        else
                            -- force a re-link
                            log.debug("PLC_LNK: no session but not a link, force relink")
                            _send_plc_linking(r_port, { RPLC_LINKING.DENY })
                        end
                    end
                elseif protocol == PROTOCOLS.SCADA_MGMT then
                    -- SCADA management packet
                    if session ~= nil then
                        -- pass the packet onto the session handler
                        session.in_queue.push_packet(packet)
                    end
                else
                    log.debug("illegal packet type " .. protocol .. " on device listening channel")
                end
            -- coordinator listening channel
            elseif l_port == self.coord_listen then
                if protocol == PROTOCOLS.SCADA_MGMT then
                    -- SCADA management packet
                elseif protocol == PROTOCOLS.COORD_DATA then
                    -- coordinator packet
                else
                    log.debug("illegal packet type " .. protocol .. " on coordinator listening channel")
                end
            else
                log.error("received packet on unused channel " .. l_port, true)
            end
        end
    end

    return public
end

return supervisor
