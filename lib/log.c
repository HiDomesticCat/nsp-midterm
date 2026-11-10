/* log.c - logging shared by the server and the client */
#include "pmon.h"

#include <signal.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

static const char *g_prog = "pmon";

/* Run-time switch for debug output. sig_atomic_t because the server flips it
 * from its SIGUSR1 handler. */
static volatile sig_atomic_t g_debug = 0;

void log_init(const char *prog)
{
    const char *env = getenv("PMON_LOG");

    g_prog = prog;
    if (env != NULL && strcmp(env, "debug") == 0)
        g_debug = 1;
}

void log_set_debug(int on)
{
    g_debug = on ? 1 : 0;
}

void log_toggle_debug(void)
{
    g_debug = !g_debug;
}

void log_write(int level, const char *file, int line, const char *fmt, ...)
{
    static const char *const names[] = { "ERROR", "INFO", "DEBUG" };
    char buf[1024];
    struct timespec ts;
    struct tm tm;
    va_list ap;
    int n, m;
    ssize_t written;

    if (level == LOG_LVL_DEBUG && !g_debug)
        return;

    clock_gettime(CLOCK_REALTIME, &ts);
    localtime_r(&ts.tv_sec, &tm);

    /* The pid tells the server's children apart in a shared log. */
    n = snprintf(buf, sizeof buf - 1,
                 "%04d-%02d-%02d %02d:%02d:%02d.%03ld [%-5s] %s[%d] %s:%d: ",
                 tm.tm_year + 1900, tm.tm_mon + 1, tm.tm_mday,
                 tm.tm_hour, tm.tm_min, tm.tm_sec, ts.tv_nsec / 1000000L,
                 names[level], g_prog, (int)getpid(), file, line);
    if (n < 0 || n >= (int)sizeof buf - 1)
        n = (int)sizeof buf - 2;

    va_start(ap, fmt);
    m = vsnprintf(buf + n, sizeof buf - 1 - (size_t)n, fmt, ap);
    va_end(ap);
    if (m > 0)
        n += m;
    if (n > (int)sizeof buf - 2)
        n = (int)sizeof buf - 2;
    buf[n++] = '\n';

    /* One write() per line, so lines from different processes do not mix. */
    written = write(STDERR_FILENO, buf, (size_t)n);
    (void)written;
}
