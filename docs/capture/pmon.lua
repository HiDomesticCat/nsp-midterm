-- pmon.lua - teach Wireshark the pmon frame, so the capture can be read
-- field by field instead of as raw bytes.
--
--   wireshark -X lua_script:docs/capture/pmon.lua docs/capture/stat-ens4.pcap
--
-- A frame is a 12-byte header followed by the payload (see include/pmon.h):
--   magic u16 | opcode u8 | status u8 | length u32 | crc32 u32 | payload
-- This is for looking at one request and one reply; it does not put frames
-- back together when TCP splits them across packets.

local pmon = Proto("pmon", "pmon performance monitor")

local opcodes  = { [1] = "SYSINFO", [2] = "STAT", [3] = "WATCH" }
local statuses = { [0] = "OK", [1] = "BAD_REQUEST", [2] = "BUSY", [3] = "INTERNAL" }

local f_magic   = ProtoField.uint16("pmon.magic",   "Magic",          base.HEX)
local f_opcode  = ProtoField.uint8 ("pmon.opcode",  "Opcode",         base.DEC, opcodes)
local f_status  = ProtoField.uint8 ("pmon.status",  "Status",         base.DEC, statuses)
local f_length  = ProtoField.uint32("pmon.length",  "Payload length", base.DEC)
local f_crc     = ProtoField.uint32("pmon.crc32",   "Payload CRC-32", base.HEX)
local f_payload = ProtoField.string("pmon.payload", "Payload")

pmon.fields = { f_magic, f_opcode, f_status, f_length, f_crc, f_payload }

function pmon.dissector(buf, pinfo, tree)
    if buf:len() < 12 or buf(0, 2):uint() ~= 0x504D then
        return 0
    end

    local opcode = buf(2, 1):uint()
    local status = buf(3, 1):uint()
    local length = buf(4, 4):uint()
    local shown  = math.min(buf:len(), 12 + length)

    local t = tree:add(pmon, buf(0, shown))
    t:add(f_magic,  buf(0, 2)):append_text(" (\"PM\")")
    t:add(f_opcode, buf(2, 1))
    t:add(f_status, buf(3, 1))
    t:add(f_length, buf(4, 4))
    t:add(f_crc,    buf(8, 4))
    if shown > 12 then
        t:add(f_payload, buf(12, shown - 12))
    end

    pinfo.cols.protocol = "PMON"
    if pinfo.dst_port == 9419 then
        pinfo.cols.info = string.format("%s request, payload %d bytes",
                                        opcodes[opcode] or "?", length)
    else
        pinfo.cols.info = string.format("%s reply %s, payload %d bytes",
                                        opcodes[opcode] or "?", statuses[status] or "?", length)
    end
    return shown
end

DissectorTable.get("tcp.port"):add(9419, pmon)
