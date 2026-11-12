/* session.c - what a child does for its one client */
#include "pmon.h"
#include "server.h"

#include <errno.h>
#include <poll.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

#define STAT_WINDOW_MS 200      /* measuring period of a single STAT */

/* Send text as the OK response to op. Returns the proto_send() result. */
static int reply_text(int fd, uint8_t op, char *text)
{
    int r;

    if (text == NULL)
        return proto_send(fd, op, ST_INTERNAL, NULL, 0);
    r = proto_send(fd, op, ST_OK, text, (uint32_t)strlen(text));
    free(text);
    return r;
}

/* Wait ms milliseconds, or less if the client closes or sends something.
 * Returns 1 after the full wait, 0 if the socket became readable. */
static int wait_or_client(int fd, int ms)
{
    struct timespec start, now;

    clock_gettime(CLOCK_MONOTONIC, &start);
    for (;;) {
        struct pollfd pfd = { .fd = fd, .events = POLLIN };
        long elapsed;
        int r;

        clock_gettime(CLOCK_MONOTONIC, &now);
        elapsed = (now.tv_sec - start.tv_sec) * 1000L +
                  (now.tv_nsec - start.tv_nsec) / 1000000L;
        if (elapsed >= ms)
            return 1;

        r = poll(&pfd, 1, ms - (int)elapsed);
        if (r > 0)
            return 0;
        /* r == 0: time is up; r < 0: interrupted by a signal, wait on */
    }
}

/* STAT: usage over a short window, since CPU and network figures are rates. */
static void handle_stat(int fd)
{
    struct sample a, b;

    metrics_sample(&a);
    usleep(STAT_WINDOW_MS * 1000);
    metrics_sample(&b);
    reply_text(fd, OP_STAT, metrics_text(&a, &b));
}

/* WATCH: push a sample every interval. Ends after count samples, or when
 * the client goes away. Returns 0 if the connection can no longer be used. */
static int handle_watch(int fd, const char *peer, const char *params,
                        const struct server_opts *opts)
{
    int interval = (int)kv_get_num(params, "interval", 1);
    int count = (int)kv_get_num(params, "count", 0);     /* 0 = no limit */
    struct sample prev, now;
    int sent = 0;

    if (interval < 1 || interval > 60 || count < 0) {
        proto_send(fd, OP_WATCH, ST_BAD_REQUEST, NULL, 0);
        return 1;
    }
    LOG_INFO("%s watching every %d s", peer, interval);

    metrics_sample(&prev);
    while (count == 0 || sent < count) {
        /* The client sends nothing while watching, so a readable socket
         * means it closed the connection (or broke the protocol). */
        if (!opts->sigpipe_guard) {
            /* Demonstration only: wait blindly and write without checking
             * whether anyone is still there. */
            sleep((unsigned)interval);
        } else if (!wait_or_client(fd, interval * 1000)) {
            LOG_INFO("%s stopped watching after %d sample(s)", peer, sent);
            return 0;
        }
        metrics_sample(&now);
        if (reply_text(fd, OP_WATCH, metrics_text(&prev, &now)) != IO_OK) {
            LOG_INFO("%s is gone (%s), watch ended after %d sample(s)",
                     peer, strerror(errno), sent);
            return 0;
        }
        prev = now;
        sent++;
    }
    LOG_INFO("%s finished watching, %d sample(s) sent", peer, sent);
    return 1;
}

/* Close after replying to something we refused to read in full.
 *
 * If a socket is closed while unread data is still queued on it, the kernel
 * sends a reset instead of a normal close, and the peer may lose the reply we
 * just sent. So: finish our side, discard what the peer already sent (within
 * limits), and only then close. */
static void close_after_reject(int fd)
{
    char junk[1024];
    size_t total = 0;

    shutdown(fd, SHUT_WR);
    while (total < 65536) {
        struct pollfd pfd = { .fd = fd, .events = POLLIN };
        ssize_t k;

        if (poll(&pfd, 1, 500) <= 0)
            break;
        k = read(fd, junk, sizeof junk);
        if (k <= 0)
            break;
        total += (size_t)k;
    }
    close(fd);
}

void session_run(int fd, const char *peer, const struct server_opts *opts)
{
    unsigned long served = 0;
    int usable = 1;

    LOG_INFO("%s connected", peer);

    while (usable) {
        uint8_t op = 0, status = 0;
        void *payload = NULL;
        uint32_t len = 0;
        int r;

        r = proto_recv(fd, &op, &status, &payload, &len,
                       opts->timeout_ms, opts->validate);
        if (r == IO_EOF) {
            LOG_INFO("%s disconnected after %lu request(s)", peer, served);
            break;
        }
        if (r == IO_TIMEOUT) {
            LOG_INFO("%s sent nothing for %d s, closing",
                     peer, opts->timeout_ms / 1000);
            break;
        }
        if (r == PROTO_BAD) {
            proto_send(fd, 0, ST_BAD_REQUEST, NULL, 0);
            LOG_INFO("%s sent an invalid frame, closing", peer);
            close_after_reject(fd);
            return;
        }
        if (r != IO_OK) {
            LOG_ERROR("reading from %s: %s", peer, strerror(errno));
            break;
        }

        LOG_DEBUG("%s request %s, %u byte(s)", peer, proto_op_name(op),
                  (unsigned)len);

        switch (op) {
        case OP_SYSINFO:
            reply_text(fd, OP_SYSINFO, sysinfo_text());
            break;
        case OP_STAT:
            handle_stat(fd);
            break;
        case OP_WATCH:
            usable = handle_watch(fd, peer, payload, opts);
            break;
        default:
            proto_send(fd, op, ST_BAD_REQUEST, NULL, 0);
            break;
        }
        free(payload);
        served++;
    }
    close(fd);
}
