/* io.c - read and write a whole buffer on a socket */
#include "pmon.h"

#include <errno.h>
#include <poll.h>
#include <sys/socket.h>
#include <unistd.h>

int io_read_full(int fd, void *buf, size_t n, int timeout_ms)
{
    char *p = buf;
    size_t got = 0;

    while (got < n) {
        struct pollfd pfd = { .fd = fd, .events = POLLIN };
        ssize_t k;
        int r;

        /* Wait for data instead of blocking in read(), so a peer that
         * connects and then stays silent cannot hold us forever. */
        r = poll(&pfd, 1, timeout_ms);
        if (r < 0) {
            if (errno == EINTR)
                continue;
            return IO_ERR;
        }
        if (r == 0)
            return IO_TIMEOUT;

        k = read(fd, p + got, n - got);
        if (k < 0) {
            if (errno == EINTR || errno == EAGAIN)
                continue;
            return IO_ERR;
        }
        if (k == 0)
            return IO_EOF;
        got += (size_t)k;          /* short read: go round again */
    }
    return IO_OK;
}

int io_write_full(int fd, const void *buf, size_t n)
{
    const char *p = buf;
    size_t sent = 0;

    while (sent < n) {
        /* MSG_NOSIGNAL: if the peer is gone we get EPIPE back instead of
         * being killed by SIGPIPE. */
        ssize_t k = send(fd, p + sent, n - sent, MSG_NOSIGNAL);

        if (k < 0) {
            if (errno == EINTR)
                continue;
            return IO_ERR;
        }
        sent += (size_t)k;         /* short write: send the rest */
    }
    return IO_OK;
}
