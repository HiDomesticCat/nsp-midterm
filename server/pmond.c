/*
 * pmond.c - the server's parent process
 *
 * The parent only accepts connections. Each accepted connection is handed to
 * a child created with fork(); the child serves that one client and exits.
 */
#include "pmon.h"
#include "server.h"

#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <poll.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/wait.h>
#include <unistd.h>

#define MAX_KIDS 1024

/* Pids of the live children, so they can be counted and stopped. */
static pid_t g_kids[MAX_KIDS];
static int g_nkids = 0;

/* Set by signal handlers, acted on by the main loop. Handlers do nothing
 * else, so everything else can use ordinary, non-signal-safe functions. */
static volatile sig_atomic_t g_child_exited = 0;
static volatile sig_atomic_t g_stop = 0;

static void on_sigchld(int sig)
{
    (void)sig;
    g_child_exited = 1;
}

static void on_stop(int sig)
{
    (void)sig;
    g_stop = 1;
}

/* SIGUSR1 switches debug output on or off without a restart. */
static void on_sigusr1(int sig)
{
    (void)sig;
    log_toggle_debug();
}

static void install_handlers(void)
{
    struct sigaction sa;

    memset(&sa, 0, sizeof sa);
    sigemptyset(&sa.sa_mask);

    /* No SA_RESTART: a signal makes poll() in the main loop return, and the
     * loop then looks at the flags. */
    sa.sa_handler = on_sigchld;
    sigaction(SIGCHLD, &sa, NULL);
    sa.sa_handler = on_stop;
    sigaction(SIGINT, &sa, NULL);
    sigaction(SIGTERM, &sa, NULL);
    sa.sa_handler = on_sigusr1;
    sigaction(SIGUSR1, &sa, NULL);

    /* Writing to a client that has gone must not kill the process. */
    signal(SIGPIPE, SIG_IGN);
}

/* Collect every child that has exited, so none is left as a zombie.
 * Several may have exited for one SIGCHLD, hence the loop. */
static void reap_children(void)
{
    pid_t pid;
    int status, i;

    g_child_exited = 0;
    while ((pid = waitpid(-1, &status, WNOHANG)) > 0) {
        for (i = 0; i < MAX_KIDS; i++) {
            if (g_kids[i] == pid) {
                g_kids[i] = 0;
                g_nkids--;
                break;
            }
        }
        if (WIFSIGNALED(status))
            LOG_ERROR("child %d was killed by signal %d (%s), %d still active",
                      (int)pid, WTERMSIG(status), strsignal(WTERMSIG(status)),
                      g_nkids);
        else
            LOG_DEBUG("child %d exited with status %d, %d still active",
                      (int)pid, WEXITSTATUS(status), g_nkids);
    }
}

static void remember_child(pid_t pid)
{
    int i;

    for (i = 0; i < MAX_KIDS; i++) {
        if (g_kids[i] == 0) {
            g_kids[i] = pid;
            g_nkids++;
            return;
        }
    }
}

static int listen_on(int port)
{
    struct sockaddr_in addr;
    int fd, on = 1;

    fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0)
        return -1;

    /* Allow a restart while old connections are still in TIME_WAIT. */
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &on, sizeof on);

    memset(&addr, 0, sizeof addr);
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = htonl(INADDR_ANY);
    addr.sin_port = htons((uint16_t)port);

    if (bind(fd, (struct sockaddr *)&addr, sizeof addr) < 0 ||
        listen(fd, 128) < 0) {
        close(fd);
        return -1;
    }

    /* Non-blocking, so accept() cannot hang if a connection that poll()
     * reported disappears before we get to it. */
    fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK);
    return fd;
}

static void serve_forever(int listen_fd, const struct server_opts *opts)
{
    while (!g_stop) {
        struct pollfd pfd = { .fd = listen_fd, .events = POLLIN };
        struct sockaddr_in peer;
        socklen_t peer_len = sizeof peer;
        char who[64], ip[INET_ADDRSTRLEN];
        pid_t pid;
        int fd;

        if (g_child_exited)
            reap_children();

        /* Wake up for a new connection, a signal, or once a second (which
         * covers a signal that arrives just before poll() starts). */
        if (poll(&pfd, 1, 1000) <= 0)
            continue;

        fd = accept(listen_fd, (struct sockaddr *)&peer, &peer_len);
        if (fd < 0) {
            if (errno != EINTR && errno != EAGAIN && errno != ECONNABORTED)
                LOG_ERROR("accept: %s", strerror(errno));
            continue;
        }

        inet_ntop(AF_INET, &peer.sin_addr, ip, sizeof ip);
        snprintf(who, sizeof who, "%s:%d", ip, (int)ntohs(peer.sin_port));

        if (g_nkids >= opts->max_clients) {
            LOG_INFO("%s refused: %d clients already connected", who, g_nkids);
            proto_send(fd, 0, ST_BUSY, NULL, 0);
            close(fd);
            continue;
        }

        pid = fork();
        if (pid == 0) {
            /* Child: it owns the connection, not the listening socket. */
            signal(SIGCHLD, SIG_DFL);
            signal(SIGINT, SIG_DFL);
            signal(SIGTERM, SIG_DFL);
            close(listen_fd);
            session_run(fd, who, opts);
            _exit(0);
        }
        if (pid < 0) {
            LOG_ERROR("fork: %s", strerror(errno));
            proto_send(fd, 0, ST_BUSY, NULL, 0);
        } else {
            remember_child(pid);
            LOG_DEBUG("forked child %d for %s, %d active",
                      (int)pid, who, g_nkids);
        }
        /* Parent: the child has its own copy of the connection. */
        close(fd);
    }
}

/* Ask the remaining children to stop, then wait for them. */
static void shutdown_children(void)
{
    int i, n = 0;

    for (i = 0; i < MAX_KIDS; i++) {
        if (g_kids[i] > 0) {
            kill(g_kids[i], SIGTERM);
            n++;
        }
    }
    while (waitpid(-1, NULL, 0) > 0 || errno == EINTR)
        ;
    LOG_INFO("stopped, %d connection(s) closed", n);
}

static void usage(void)
{
    fprintf(stderr,
            "usage: pmond [-p port] [-m max-clients] [-t seconds] [-v]\n"
            "  -p  TCP port to listen on (default %d)\n"
            "  -m  concurrent clients before replying BUSY (default 64)\n"
            "  -t  seconds to wait for a silent client (default 10)\n"
            "  -v  debug output (debug build only)\n",
            PMON_PORT);
}

int main(int argc, char **argv)
{
    struct server_opts opts = {
        .port = PMON_PORT,
        .max_clients = 64,
        .timeout_ms = 10000,
        .validate = 1,
    };
    int c, listen_fd;

    log_init("pmond");

    while ((c = getopt(argc, argv, "p:m:t:vh")) != -1) {
        switch (c) {
        case 'p': opts.port = atoi(optarg); break;
        case 'm': opts.max_clients = atoi(optarg); break;
        case 't': opts.timeout_ms = atoi(optarg) * 1000; break;
        case 'v': log_set_debug(1); break;
        default:  usage(); return c == 'h' ? 0 : 2;
        }
    }
    if (opts.max_clients < 1 || opts.max_clients > MAX_KIDS) {
        fprintf(stderr, "pmond: -m must be between 1 and %d\n", MAX_KIDS);
        return 2;
    }
#ifndef PMON_DEBUG
    LOG_INFO("normal build: debug messages are compiled out");
#endif

    listen_fd = listen_on(opts.port);
    if (listen_fd < 0) {
        LOG_ERROR("cannot listen on port %d: %s", opts.port, strerror(errno));
        return 1;
    }
    install_handlers();

    LOG_INFO("listening on port %d, up to %d clients",
             opts.port, opts.max_clients);
    serve_forever(listen_fd, &opts);

    close(listen_fd);
    shutdown_children();
    return 0;
}
