/*
 * pmon.h - public interface of libpmon.so
 *
 * Everything the server (pmond) and the client (pmon) have in common lives in
 * the shared library: logging, reliable socket I/O, the wire protocol and
 * the key=value text used in payloads.
 */
#ifndef PMON_H
#define PMON_H

#include <stddef.h>
#include <stdint.h>

/* ---- log ----------------------------------------------------------------
 *
 * Two levels of debug control:
 *
 *   compile time  LOG_DEBUG() only produces code when the program is built
 *                 with -DPMON_DEBUG (make DEBUG=1). In a normal build the
 *                 call and its format string are not in the binary at all.
 *
 *   run time      In a debug build, debug output is still off by default.
 *                 Turn it on with -v, with PMON_LOG=debug in the environment,
 *                 or by sending SIGUSR1 to a running server.
 */
enum { LOG_LVL_ERROR, LOG_LVL_INFO, LOG_LVL_DEBUG };

void log_init(const char *prog);     /* also reads PMON_LOG */
void log_set_debug(int on);
void log_toggle_debug(void);         /* safe to call from a signal handler */
void log_write(int level, const char *file, int line, const char *fmt, ...)
    __attribute__((format(printf, 4, 5)));

#define LOG_ERROR(...) log_write(LOG_LVL_ERROR, __FILE__, __LINE__, __VA_ARGS__)
#define LOG_INFO(...)  log_write(LOG_LVL_INFO,  __FILE__, __LINE__, __VA_ARGS__)

#ifdef PMON_DEBUG
#define LOG_DEBUG(...) log_write(LOG_LVL_DEBUG, __FILE__, __LINE__, __VA_ARGS__)
#else
/* Never executed, so the compiler drops the call and the string, but the
 * arguments are still type-checked and count as "used". */
#define LOG_DEBUG(...) \
    do { if (0) log_write(LOG_LVL_DEBUG, __FILE__, __LINE__, __VA_ARGS__); } while (0)
#endif

/* ---- io -----------------------------------------------------------------
 *
 * read() and write() on a socket may transfer fewer bytes than asked for.
 * These helpers loop until everything is transferred, retry on EINTR, and
 * give up after timeout_ms without progress (a negative value waits forever).
 */
enum {
    IO_OK      =  0,
    IO_ERR     = -1,   /* errno is set */
    IO_TIMEOUT = -2,
    IO_EOF     = -3,   /* peer closed the connection */
    PROTO_BAD  = -4    /* the bytes received are not a valid frame */
};

int io_read_full(int fd, void *buf, size_t n, int timeout_ms);
int io_write_full(int fd, const void *buf, size_t n);

/* ---- protocol -----------------------------------------------------------
 *
 * Every message, request or response, is one frame:
 *
 *   offset  size  field
 *        0     2  magic    0x504D ("PM")
 *        2     1  opcode
 *        3     1  status   0 in requests, result code in responses
 *        4     4  length   payload bytes, at most PMON_MAX_PAYLOAD
 *        8     4  crc32    CRC-32 of the payload
 *       12     -  payload
 *
 * Multi-byte fields are in network byte order.
 */
#define PMON_MAGIC        0x504Du
#define PMON_HDR_LEN      12
#define PMON_MAX_PAYLOAD  (1u << 16)
#define PMON_PORT         9419

enum {
    OP_SYSINFO = 1,   /* static facts about the machine */
    OP_STAT    = 2,   /* one sample of the performance counters */
    OP_WATCH   = 3    /* a sample every interval until the client leaves */
};

enum {
    ST_OK          = 0,
    ST_BAD_REQUEST = 1,
    ST_BUSY        = 2,
    ST_INTERNAL    = 3
};

uint32_t pmon_crc32(const void *data, size_t n);

int proto_send(int fd, uint8_t opcode, uint8_t status,
               const void *payload, uint32_t len);

/* On IO_OK, *payload is a malloc'd buffer of *len bytes followed by a NUL
 * byte; the caller frees it. With validate == 0 the magic, length limit and
 * CRC checks are skipped (only used to demonstrate why they are needed). */
int proto_recv(int fd, uint8_t *opcode, uint8_t *status,
               void **payload, uint32_t *len, int timeout_ms, int validate);

const char *proto_op_name(int opcode);
const char *proto_status_name(int status);

/* ---- key=value text -------------------------------------------------------
 *
 * Payloads are lines of "key=value". The server uses these to read request
 * parameters, the client to pick values out of a response.
 */

/* Copy the value of key into out (always NUL-terminated).
 * Returns 1 if the key was found, 0 otherwise. */
int kv_get(const char *text, const char *key, char *out, size_t out_size);

/* The value of key as a number, or fallback if it is missing or not numeric. */
double kv_get_num(const char *text, const char *key, double fallback);

#endif
