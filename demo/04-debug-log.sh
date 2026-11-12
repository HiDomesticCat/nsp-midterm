#!/bin/bash
# 04 - two levels of debug log control: compile time and run time.
. "$(dirname "$0")/common.sh"

MSG='forked child'       # a LOG_DEBUG() message in server/pmond.c

title "compile time: the same source, built with and without -DPMON_DEBUG"
grep -n "LOG_DEBUG(\"$MSG" server/pmond.c
echo
for b in build build-debug; do
    printf '%-12s size %6s bytes   contains "%s": %s time(s)\n' "$b" \
        "$(stat -c %s $b/bin/pmond)" "$MSG" "$(strings $b/bin/pmond | grep -c "$MSG")"
done
echo
echo "normal build, asked for debug output anyway (-v):"
start_server $BIN -v
run $BIN/pmon -s 127.0.0.1:$PORT stat > /dev/null
sleep 1.2
stop_server
echo "DEBUG lines in the server log: $(grep -c DEBUG "$LOG")"
grep 'compiled out' "$LOG"

title "run time: debug build, debug output off by default"
start_server $DBG
run $DBG/pmon -s 127.0.0.1:$PORT stat > /dev/null
sleep 1.2
echo "DEBUG lines so far: $(grep -c DEBUG "$LOG")"

title "run time: switch it on in the running server with SIGUSR1"
run kill -USR1 $SRV
sleep 0.3
run $DBG/pmon -s 127.0.0.1:$PORT stat > /dev/null
sleep 1.2
echo "DEBUG lines now: $(grep -c DEBUG "$LOG")"
grep DEBUG "$LOG"

title "run time: and off again"
before=$(grep -c DEBUG "$LOG")
run kill -USR1 $SRV
sleep 0.3
run $DBG/pmon -s 127.0.0.1:$PORT stat > /dev/null
sleep 1.2
echo "DEBUG lines added after switching off: $(( $(grep -c DEBUG "$LOG") - before ))"

title "run time: the client has the same switch (-v or PMON_LOG=debug)"
run $DBG/pmon -v -s 127.0.0.1:$PORT stat > /dev/null
