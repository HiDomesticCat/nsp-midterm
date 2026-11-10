/* kv.c - read values out of "key=value" lines */
#include "pmon.h"

#include <stdlib.h>
#include <string.h>

int kv_get(const char *text, const char *key, char *out, size_t out_size)
{
    size_t key_len = strlen(key);
    const char *line = text;

    if (out_size == 0)
        return 0;
    out[0] = '\0';

    while (line != NULL && *line != '\0') {
        const char *end = strchr(line, '\n');
        size_t line_len = end != NULL ? (size_t)(end - line) : strlen(line);

        /* The key must be the whole text before '=', not just a prefix. */
        if (line_len > key_len && line[key_len] == '=' &&
            strncmp(line, key, key_len) == 0) {
            size_t n = line_len - key_len - 1;

            if (n >= out_size)
                n = out_size - 1;      /* truncate rather than overflow */
            memcpy(out, line + key_len + 1, n);
            out[n] = '\0';
            return 1;
        }
        line = end != NULL ? end + 1 : NULL;
    }
    return 0;
}

double kv_get_num(const char *text, const char *key, double fallback)
{
    char value[64], *rest;
    double v;

    if (!kv_get(text, key, value, sizeof value))
        return fallback;
    v = strtod(value, &rest);
    return rest == value ? fallback : v;
}
