/*
 * pmon.c - the command-line client
 *
 * usage: pmon [-s host[:port]] [-v] <command> [arguments]
 */
#include "pmon.h"

#include <errno.h>
#include <netdb.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <unistd.h>

#define CONNECT_TIMEOUT_S   5
#define RESPONSE_TIMEOUT_MS 15000

/* Connect to "host" or "host:port". Returns a socket, or -1. */
static int connect_to(const char *server)
{
    char host[256], port[16];
    const char *colon = strrchr(server, ':');
    struct addrinfo hints, *res, *ai;
    struct timeval tv = { .tv_sec = CONNECT_TIMEOUT_S };
    int fd = -1, err;

    if (colon != NULL) {
        snprintf(host, sizeof host, "%.*s", (int)(colon - server), server);
        snprintf(port, sizeof port, "%s", colon + 1);
    } else {
        snprintf(host, sizeof host, "%s", server);
        snprintf(port, sizeof port, "%d", PMON_PORT);
    }

    memset(&hints, 0, sizeof hints);
    hints.ai_family = AF_INET;
    hints.ai_socktype = SOCK_STREAM;

    err = getaddrinfo(host, port, &hints, &res);
    if (err != 0) {
        fprintf(stderr, "pmon: cannot resolve %s: %s\n", host, gai_strerror(err));
        return -1;
    }

    for (ai = res; ai != NULL; ai = ai->ai_next) {
        fd = socket(ai->ai_family, ai->ai_socktype, ai->ai_protocol);
        if (fd < 0)
            continue;
        /* On Linux the send timeout also bounds connect(), so an
         * unreachable server does not hang the client for minutes. */
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof tv);
        if (connect(fd, ai->ai_addr, ai->ai_addrlen) == 0)
            break;
        close(fd);
        fd = -1;
    }
    freeaddrinfo(res);

    if (fd < 0)
        fprintf(stderr, "pmon: cannot connect to %s:%s: %s\n",
                host, port, strerror(errno));
    else
        LOG_DEBUG("connected to %s:%s", host, port);
    return fd;
}

/* Wait for one response frame. Returns the status code, or -1 if no valid
 * response arrived. *reply is malloc'd on success. */
static int receive(int fd, int timeout_ms, char **reply)
{
    uint8_t op = 0, status = 0;
    uint32_t len = 0;
    void *body = NULL;
    int r;

    *reply = NULL;
    r = proto_recv(fd, &op, &status, &body, &len, timeout_ms, 1);
    if (r != IO_OK) {
        fprintf(stderr, "pmon: %s\n",
                r == IO_TIMEOUT ? "the server did not answer in time" :
                r == IO_EOF     ? "the server closed the connection" :
                r == PROTO_BAD  ? "the server sent an invalid response" :
                                  strerror(errno));
        return -1;
    }
    LOG_DEBUG("response %s status=%s, %u byte(s)", proto_op_name(op),
              proto_status_name(status), (unsigned)len);
    if (status != ST_OK)
        fprintf(stderr, "pmon: server answered %s\n", proto_status_name(status));
    *reply = body;
    return status;
}

/* Send a request and wait for its response. */
static int request(int fd, uint8_t op, const char *params, char **reply)
{
    uint32_t len = params != NULL ? (uint32_t)strlen(params) : 0;

    *reply = NULL;
    if (proto_send(fd, op, 0, params, len) != IO_OK) {
        fprintf(stderr, "pmon: sending the request failed: %s\n", strerror(errno));
        return -1;
    }
    return receive(fd, RESPONSE_TIMEOUT_MS, reply);
}

/* pmon sysinfo [--hold seconds] */
static int cmd_sysinfo(const char *server, int argc, char **argv)
{
    char *reply;
    int hold = 0, fd, status;

    if (argc == 2 && strcmp(argv[0], "--hold") == 0)
        hold = atoi(argv[1]);
    else if (argc != 0)
        return 2;

    fd = connect_to(server);
    if (fd < 0)
        return 1;

    status = request(fd, OP_SYSINFO, NULL, &reply);
    if (status == ST_OK)
        fputs(reply, stdout);
    fflush(stdout);
    free(reply);

    /* Keep the connection open for a while, so that several clients can be
     * seen connected at the same moment. */
    if (status == ST_OK && hold > 0)
        sleep((unsigned)hold);

    close(fd);
    return status == ST_OK ? 0 : 1;
}

/* pmon stat */
static int cmd_stat(const char *server, int argc)
{
    char *reply;
    int fd, status;

    if (argc != 0)
        return 2;
    fd = connect_to(server);
    if (fd < 0)
        return 1;

    status = request(fd, OP_STAT, NULL, &reply);
    if (status == ST_OK)
        fputs(reply, stdout);
    free(reply);
    close(fd);
    return status == ST_OK ? 0 : 1;
}

/* pmon watch [-i seconds] [-n count] */
static int cmd_watch(const char *server, int argc, char **argv)
{
    char params[64], *reply;
    int interval = 1, count = 0, shown = 0, fd, status, i;

    for (i = 0; i + 1 < argc; i += 2) {
        if (strcmp(argv[i], "-i") == 0)
            interval = atoi(argv[i + 1]);
        else if (strcmp(argv[i], "-n") == 0)
            count = atoi(argv[i + 1]);
        else
            return 2;
    }
    if (i != argc || interval < 1 || interval > 60 || count < 0)
        return 2;

    fd = connect_to(server);
    if (fd < 0)
        return 1;

    snprintf(params, sizeof params, "interval=%d\ncount=%d\n", interval, count);
    if (proto_send(fd, OP_WATCH, 0, params, (uint32_t)strlen(params)) != IO_OK) {
        fprintf(stderr, "pmon: sending the request failed: %s\n", strerror(errno));
        close(fd);
        return 1;
    }

    /* The server pushes one frame per interval; allow some slack. */
    while (count == 0 || shown < count) {
        char when[16];

        status = receive(fd, interval * 1000 + 5000, &reply);
        if (status != ST_OK) {
            free(reply);
            close(fd);
            return 1;
        }
        if (shown == 0)
            printf("server pid %.0f, every %d s\n"
                   "%-8s %6s %6s %6s %9s %7s %9s %9s %6s\n",
                   kv_get_num(reply, "handler_pid", 0), interval,
                   "time", "cpu%", "load1", "mem%", "mem MB", "disk%",
                   "rx kB/s", "tx kB/s", "tasks");

        kv_get(reply, "time", when, sizeof when);
        printf("%-8s %6.1f %6.2f %6.1f %9.0f %7.1f %9.1f %9.1f %6.0f\n",
               when,
               kv_get_num(reply, "cpu_pct", 0),
               kv_get_num(reply, "load1", 0),
               kv_get_num(reply, "mem_used_pct", 0),
               kv_get_num(reply, "mem_used_mb", 0),
               kv_get_num(reply, "disk_used_pct", 0),
               kv_get_num(reply, "net_rx_kb_s", 0),
               kv_get_num(reply, "net_tx_kb_s", 0),
               kv_get_num(reply, "tasks", 0));
        fflush(stdout);
        free(reply);
        shown++;
    }
    close(fd);
    return 0;
}

static void usage(void)
{
    fprintf(stderr,
            "usage: pmon [-s host[:port]] [-v] <command>\n"
            "\n"
            "  sysinfo [--hold seconds]        facts about the server machine\n"
            "  stat                            current CPU, memory, disk, network\n"
            "  watch [-i seconds] [-n count]   keep showing them (Ctrl+C to stop)\n"
            "\n"
            "  -s  server address (default: $PMON_SERVER, else 127.0.0.1:%d)\n"
            "  -v  debug output (debug build only)\n",
            PMON_PORT);
}

int main(int argc, char **argv)
{
    const char *server = getenv("PMON_SERVER");
    const char *cmd;
    int c, rc, nargs;
    char **args;

    log_init("pmon");
    if (server == NULL)
        server = "127.0.0.1";

    /* "+" stops option parsing at the command, so each command can have
     * options of its own. */
    while ((c = getopt(argc, argv, "+s:vh")) != -1) {
        switch (c) {
        case 's': server = optarg; break;
        case 'v':
            log_set_debug(1);
#ifndef PMON_DEBUG
            fprintf(stderr, "pmon: -v has no effect, this build has debug "
                            "messages compiled out\n");
#endif
            break;
        default:  usage(); return c == 'h' ? 0 : 2;
        }
    }
    if (optind >= argc) {
        usage();
        return 2;
    }
    cmd = argv[optind];
    args = argv + optind + 1;
    nargs = argc - optind - 1;

    if (strcmp(cmd, "sysinfo") == 0)
        rc = cmd_sysinfo(server, nargs, args);
    else if (strcmp(cmd, "stat") == 0)
        rc = cmd_stat(server, nargs);
    else if (strcmp(cmd, "watch") == 0)
        rc = cmd_watch(server, nargs, args);
    else
        rc = 2;

    if (rc == 2)
        usage();
    return rc;
}
