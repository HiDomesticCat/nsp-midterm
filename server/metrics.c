/* metrics.c - performance counters read from /proc */
#include "server.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/statvfs.h>
#include <unistd.h>

/* Value of one "Name:   12345 kB" line in /proc/meminfo, in kB. */
static long meminfo_kb(const char *name)
{
    char line[256], key[64];
    long kb, result = 0;
    FILE *f = fopen("/proc/meminfo", "r");

    if (f == NULL)
        return 0;
    while (fgets(line, sizeof line, f) != NULL) {
        if (sscanf(line, "%63[^:]: %ld", key, &kb) == 2 &&
            strcmp(key, name) == 0) {
            result = kb;
            break;
        }
    }
    fclose(f);
    return result;
}

void metrics_sample(struct sample *s)
{
    char line[512];
    FILE *f;

    memset(s, 0, sizeof *s);
    clock_gettime(CLOCK_MONOTONIC, &s->at);

    /* First line of /proc/stat: time spent in each state since boot.
     *   cpu  user nice system idle iowait irq softirq steal ... */
    f = fopen("/proc/stat", "r");
    if (f != NULL) {
        unsigned long long v[8] = { 0 };
        int i;

        if (fgets(line, sizeof line, f) != NULL &&
            sscanf(line, "cpu %llu %llu %llu %llu %llu %llu %llu %llu",
                   &v[0], &v[1], &v[2], &v[3], &v[4], &v[5], &v[6], &v[7]) >= 4) {
            for (i = 0; i < 8; i++)
                s->cpu_total += v[i];
            s->cpu_idle = v[3] + v[4];
        }
        fclose(f);
    }

    /* /proc/net/dev: one line per interface after two header lines.
     *   name: rx_bytes (7 more rx fields) tx_bytes ... */
    f = fopen("/proc/net/dev", "r");
    if (f != NULL) {
        while (fgets(line, sizeof line, f) != NULL) {
            char name[32];
            unsigned long long rx, tx;

            if (sscanf(line, " %31[^:]: %llu %*u %*u %*u %*u %*u %*u %*u %llu",
                       name, &rx, &tx) == 3 && strcmp(name, "lo") != 0) {
                s->rx_bytes += rx;
                s->tx_bytes += tx;
            }
        }
        fclose(f);
    }
}

char *metrics_text(const struct sample *prev, const struct sample *now)
{
    char *text = NULL;
    size_t size = 0;
    FILE *out = open_memstream(&text, &size);
    double secs, cpu_pct = 0.0, rx = 0.0, tx = 0.0;
    unsigned long long d_total, d_idle;
    long mem_total, mem_avail, swap_total, swap_free;
    struct statvfs vfs;
    time_t t = time(NULL);
    struct tm tm;
    FILE *f;

    if (out == NULL)
        return NULL;

    secs = (double)(now->at.tv_sec - prev->at.tv_sec) +
           (double)(now->at.tv_nsec - prev->at.tv_nsec) / 1e9;

    /* CPU usage = share of the period that was not idle. */
    d_total = now->cpu_total - prev->cpu_total;
    d_idle = now->cpu_idle - prev->cpu_idle;
    if (d_total > 0 && d_idle <= d_total)
        cpu_pct = 100.0 * (double)(d_total - d_idle) / (double)d_total;

    if (secs > 0.0) {
        rx = (double)(now->rx_bytes - prev->rx_bytes) / 1024.0 / secs;
        tx = (double)(now->tx_bytes - prev->tx_bytes) / 1024.0 / secs;
    }

    localtime_r(&t, &tm);
    fprintf(out, "time=%02d:%02d:%02d\n", tm.tm_hour, tm.tm_min, tm.tm_sec);
    fprintf(out, "cpu_pct=%.1f\n", cpu_pct);

    f = fopen("/proc/loadavg", "r");
    if (f != NULL) {
        double l1, l5, l15;
        int running, tasks;

        /* "0.03 0.01 0.00 1/234 5678": load averages, runnable/total tasks */
        if (fscanf(f, "%lf %lf %lf %d/%d", &l1, &l5, &l15, &running, &tasks) == 5) {
            fprintf(out, "load1=%.2f\n", l1);
            fprintf(out, "tasks=%d\n", tasks);
        }
        fclose(f);
    }

    mem_total = meminfo_kb("MemTotal");
    mem_avail = meminfo_kb("MemAvailable");
    swap_total = meminfo_kb("SwapTotal");
    swap_free = meminfo_kb("SwapFree");
    fprintf(out, "mem_total_mb=%ld\n", mem_total / 1024);
    fprintf(out, "mem_used_mb=%ld\n", (mem_total - mem_avail) / 1024);
    fprintf(out, "mem_used_pct=%.1f\n",
            mem_total > 0 ? 100.0 * (double)(mem_total - mem_avail) / (double)mem_total : 0.0);
    fprintf(out, "swap_used_mb=%ld\n", (swap_total - swap_free) / 1024);

    if (statvfs("/", &vfs) == 0) {
        double used = (double)(vfs.f_blocks - vfs.f_bfree);
        double usable = used + (double)vfs.f_bavail;

        fprintf(out, "disk_used_pct=%.1f\n", usable > 0.0 ? 100.0 * used / usable : 0.0);
    }

    fprintf(out, "net_rx_kb_s=%.1f\n", rx);
    fprintf(out, "net_tx_kb_s=%.1f\n", tx);
    fprintf(out, "handler_pid=%d\n", (int)getpid());

    if (fclose(out) != 0) {
        free(text);
        return NULL;
    }
    return text;
}
