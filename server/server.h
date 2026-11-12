/* server.h - shared between the server's source files */
#ifndef PMOND_SERVER_H
#define PMOND_SERVER_H

#include <time.h>

struct server_opts {
    int port;
    int max_clients;      /* concurrent connections before replying BUSY */
    int timeout_ms;       /* how long a child waits for the next request */
    int validate;         /* check incoming frames (see proto_recv) */

    /* Robustness mechanisms. All on by default; each can be switched off
     * from the command line to show what happens without it. */
    int reap;             /* collect exited children (no zombies) */
    int sigpipe_guard;    /* survive a client that vanishes mid-stream */
};

/* Serve one client until it disconnects. Runs in the child process. */
void session_run(int fd, const char *peer, const struct server_opts *opts);

/* Static facts about the machine, as "key=value" lines. Caller frees. */
char *sysinfo_text(void);

/* Raw counters at one moment. CPU usage and network rates are differences
 * between two of these, so a single sample is not enough on its own. */
struct sample {
    struct timespec at;
    unsigned long long cpu_total;   /* jiffies in all states */
    unsigned long long cpu_idle;    /* jiffies idle or waiting for I/O */
    unsigned long long rx_bytes;    /* all interfaces except loopback */
    unsigned long long tx_bytes;
};

void metrics_sample(struct sample *s);

/* Performance figures for the period prev..now, as "key=value" lines.
 * Caller frees. */
char *metrics_text(const struct sample *prev, const struct sample *now);

#endif
