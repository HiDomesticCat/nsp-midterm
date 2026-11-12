/* sysinfo.c - static facts about the machine the server runs on */
#include "server.h"

#include <stdio.h>
#include <stdlib.h>
#include <sys/statvfs.h>
#include <sys/sysinfo.h>
#include <sys/utsname.h>
#include <unistd.h>

char *sysinfo_text(void)
{
    char *text = NULL;
    size_t size = 0;
    FILE *out = open_memstream(&text, &size);
    struct utsname u;
    struct sysinfo si;
    struct statvfs vfs;

    if (out == NULL)
        return NULL;

    if (uname(&u) == 0) {
        fprintf(out, "hostname=%s\n", u.nodename);
        fprintf(out, "kernel=%s %s %s\n", u.sysname, u.release, u.machine);
    }
    fprintf(out, "cpus=%ld\n", sysconf(_SC_NPROCESSORS_ONLN));

    if (sysinfo(&si) == 0) {
        unsigned long long unit = si.mem_unit;

        fprintf(out, "uptime=%ldd %ldh %ldm\n", si.uptime / 86400,
                (si.uptime % 86400) / 3600, (si.uptime % 3600) / 60);
        fprintf(out, "mem_total_mb=%llu\n", si.totalram * unit >> 20);
        fprintf(out, "swap_total_mb=%llu\n", si.totalswap * unit >> 20);
    }

    if (statvfs("/", &vfs) == 0) {
        unsigned long long unit = vfs.f_frsize;

        fprintf(out, "disk_total_mb=%llu\n", vfs.f_blocks * unit >> 20);
        fprintf(out, "disk_free_mb=%llu\n", vfs.f_bavail * unit >> 20);
    }

    /* Shows fork() at work: every client is answered by a different pid,
     * all with the same parent. */
    fprintf(out, "server_pid=%d\n", (int)getppid());
    fprintf(out, "handler_pid=%d\n", (int)getpid());

    if (fclose(out) != 0) {
        free(text);
        return NULL;
    }
    return text;
}
