/* proto.c - frame encoding, decoding and validation */
#include "pmon.h"

#include <stdlib.h>
#include <string.h>

/* CRC-32 (IEEE 802.3, the same one zlib and Ethernet use), bit by bit. */
uint32_t pmon_crc32(const void *data, size_t n)
{
    const uint8_t *p = data;
    uint32_t crc = 0xFFFFFFFFu;
    size_t i;
    int bit;

    for (i = 0; i < n; i++) {
        crc ^= p[i];
        for (bit = 0; bit < 8; bit++)
            crc = (crc >> 1) ^ (0xEDB88320u & (0u - (crc & 1u)));
    }
    return ~crc;
}

/* Network byte order by hand: no alignment or endianness assumptions. */
static void put16(uint8_t *p, uint16_t v)
{
    p[0] = (uint8_t)(v >> 8);
    p[1] = (uint8_t)v;
}

static void put32(uint8_t *p, uint32_t v)
{
    p[0] = (uint8_t)(v >> 24);
    p[1] = (uint8_t)(v >> 16);
    p[2] = (uint8_t)(v >> 8);
    p[3] = (uint8_t)v;
}

static uint16_t get16(const uint8_t *p)
{
    return (uint16_t)((p[0] << 8) | p[1]);
}

static uint32_t get32(const uint8_t *p)
{
    return ((uint32_t)p[0] << 24) | ((uint32_t)p[1] << 16) |
           ((uint32_t)p[2] << 8) | (uint32_t)p[3];
}

int proto_send(int fd, uint8_t opcode, uint8_t status,
               const void *payload, uint32_t len)
{
    uint8_t *frame;
    int r;

    if (len > PMON_MAX_PAYLOAD)
        return PROTO_BAD;

    /* Header and payload go out in one buffer, so a small message is one
     * TCP segment and easy to read in a packet capture. */
    frame = malloc(PMON_HDR_LEN + (size_t)len);
    if (frame == NULL)
        return IO_ERR;

    put16(frame, PMON_MAGIC);
    frame[2] = opcode;
    frame[3] = status;
    put32(frame + 4, len);
    put32(frame + 8, pmon_crc32(payload, len));
    if (len > 0)
        memcpy(frame + PMON_HDR_LEN, payload, len);

    LOG_DEBUG("send frame op=%s status=%s len=%u",
              proto_op_name(opcode), proto_status_name(status), len);

    r = io_write_full(fd, frame, PMON_HDR_LEN + (size_t)len);
    free(frame);
    return r;
}

int proto_recv(int fd, uint8_t *opcode, uint8_t *status,
               void **payload, uint32_t *len, int timeout_ms, int validate)
{
    uint8_t hdr[PMON_HDR_LEN];
    uint32_t n, crc;
    char *body;
    int r;

    *payload = NULL;
    *len = 0;

    r = io_read_full(fd, hdr, sizeof hdr, timeout_ms);
    if (r != IO_OK)
        return r;

    *opcode = hdr[2];
    *status = hdr[3];
    n = get32(hdr + 4);
    crc = get32(hdr + 8);

    LOG_DEBUG("recv header magic=0x%04x op=%u status=%u len=%u crc=0x%08x",
              (unsigned)get16(hdr), (unsigned)hdr[2], (unsigned)hdr[3],
              (unsigned)n, (unsigned)crc);

    /* Nothing in the header is trusted until it has been checked. In
     * particular the length decides how much memory we allocate and how
     * long we wait, so it must be bounded before it is used. */
    if (validate) {
        if (get16(hdr) != PMON_MAGIC) {
            LOG_INFO("rejected frame: bad magic 0x%04x", (unsigned)get16(hdr));
            return PROTO_BAD;
        }
        if (n > PMON_MAX_PAYLOAD) {
            LOG_INFO("rejected frame: length %u exceeds limit %u",
                     (unsigned)n, (unsigned)PMON_MAX_PAYLOAD);
            return PROTO_BAD;
        }
    }

    body = malloc((size_t)n + 1);
    if (body == NULL)
        return IO_ERR;

    if (n > 0) {
        r = io_read_full(fd, body, n, timeout_ms);
        if (r != IO_OK) {
            free(body);
            return r;
        }
    }
    body[n] = '\0';

    if (validate && pmon_crc32(body, n) != crc) {
        LOG_INFO("rejected frame: CRC mismatch");
        free(body);
        return PROTO_BAD;
    }

    *payload = body;
    *len = n;
    return IO_OK;
}

const char *proto_op_name(int opcode)
{
    switch (opcode) {
    case OP_SYSINFO: return "SYSINFO";
    case OP_STAT:    return "STAT";
    case OP_WATCH:   return "WATCH";
    default:         return "UNKNOWN";
    }
}

const char *proto_status_name(int status)
{
    switch (status) {
    case ST_OK:          return "OK";
    case ST_BAD_REQUEST: return "BAD_REQUEST";
    case ST_BUSY:        return "BUSY";
    case ST_INTERNAL:    return "INTERNAL";
    default:             return "UNKNOWN";
    }
}
