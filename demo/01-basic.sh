#!/bin/bash
# 01 - the application: a client asks the server for system information.
. "$(dirname "$0")/common.sh"

title "start the server"
start_server $BIN

title "sysinfo: static facts about the machine"
run $BIN/pmon -s 127.0.0.1:$PORT sysinfo

title "stat: one sample of the performance counters"
run $BIN/pmon -s 127.0.0.1:$PORT stat

title "watch: a sample every second (3 samples)"
run $BIN/pmon -s 127.0.0.1:$PORT watch -i 1 -n 3

title "what the server logged"
stop_server
cat "$LOG"
