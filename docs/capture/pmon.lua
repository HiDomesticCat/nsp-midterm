-- pmon.lua - teach Wireshark the pmon frame, so the capture can be read
-- field by field instead of as raw bytes, and so Wireshark itself checks
-- that every frame on the wire is well formed.
--
--   wireshark -X lua_script:docs/capture/pmon.lua docs/capture/stat-ens4.pcap
--
-- A frame is a 12-byte header followed by the payload (see include/pmon.h):
--   magic u16 | opcode u8 | status u8 | length u32 | crc32 u32 | payload
--
-- Two checks are made on each frame and shown next to the field:
--   length  the length field equals the number of payload bytes that follow
--   crc32   the CRC-32 field equals the CRC-32 computed here over the payload
-- The CRC-32 below is written independently of lib/proto.c, so agreement
-- means the program's frames are correct, not that one copy matches itself.
--
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
local f_crc_ok  = ProtoField.bool  ("pmon.crc32_ok", "CRC-32 correct")
local f_payload = ProtoField.string("pmon.payload", "Payload")

pmon.fields = { f_magic, f_opcode, f_status, f_length, f_crc, f_crc_ok, f_payload }

-- Standard CRC-32 (polynomial 0xEDB88320, as in zlib and Ethernet), one bit
-- at a time. Wireshark's Lua is 5.2, which has the bit32 library.
local function crc32(bytes)
    local crc = 0xFFFFFFFF
    for i = 0, bytes:len() - 1 do
        crc = bit32.bxor(crc, bytes:get_index(i))
        for _ = 1, 8 do
            if bit32.band(crc, 1) == 1 then
                crc = bit32.bxor(bit32.rshift(crc, 1), 0xEDB88320)
            else
                crc = bit32.rshift(crc, 1)
            end
        end
    end
    return bit32.bnot(crc)
end

function pmon.dissector(buf, pinfo, tree)
    if buf:len() < 12 or buf(0, 2):uint() ~= 0x504D then
        return 0
    end

    local opcode   = buf(2, 1):uint()
    local status   = buf(3, 1):uint()
    local length   = buf(4, 4):uint()
    local crc      = buf(8, 4):uint()
    local present  = buf:len() - 12
    local complete = (present == length)
    local shown    = math.min(buf:len(), 12 + length)

    local t = tree:add(pmon, buf(0, shown))
    t:add(f_magic,  buf(0, 2)):append_text(" (\"PM\")")
    t:add(f_opcode, buf(2, 1))
    t:add(f_status, buf(3, 1))

    local len_item = t:add(f_length, buf(4, 4))
    if complete then
        len_item:append_text(string.format(" [correct: %d payload bytes follow]", present))
    else
        len_item:append_text(string.format(" [%d payload bytes in this packet]", present))
    end

    local crc_item = t:add(f_crc, buf(8, 4))
    local verdict = ""
    if complete then
        local computed = 0
        if length > 0 then
            computed = crc32(buf(12, length):bytes())
        end
        local ok = (computed == crc)
        if ok then
            crc_item:append_text(" [correct]")
            verdict = ", CRC correct"
        else
            crc_item:append_text(string.format(" [incorrect, should be 0x%08x]", computed))
            verdict = ", CRC INCORRECT"
        end
        t:add(f_crc_ok, ok):set_generated()
    end

    if shown > 12 then
        t:add(f_payload, buf(12, shown - 12))
    end

    pinfo.cols.protocol = "PMON"
    if pinfo.dst_port == 9419 then
        pinfo.cols.info = string.format("%s request, payload %d bytes%s",
                                        opcodes[opcode] or "?", length, verdict)
    else
        pinfo.cols.info = string.format("%s reply %s, payload %d bytes%s",
                                        opcodes[opcode] or "?", statuses[status] or "?", length, verdict)
    end
    return shown
end

DissectorTable.get("tcp.port"):add(9419, pmon)
