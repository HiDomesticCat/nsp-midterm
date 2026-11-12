#!/bin/bash
# Run every demo in order. Pass "pause" to stop between them.
cd "$(dirname "$0")" || exit 1
for d in 01-basic 02-ten-clients 03-capture 04-debug-log 05-shared-lib \
         r1-zombie r2-validate r3-timeout r4-sigpipe; do
    printf '\n\n######## demo/%s.sh ########\n' "$d"
    ./$d.sh
    [ "$1" = pause ] && read -r -p "-- Enter for the next demo --" _
done
