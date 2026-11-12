#!/bin/bash
# R3 - a client that connects and then says nothing.
. "$(dirname "$0")/common.sh"

scenario() {
    start_server $BIN -t 3 "$@"
    echo "\$ nc 127.0.0.1 $PORT    (connected, sends nothing)"
    ( sleep 9 | nc 127.0.0.1 "$PORT" > /dev/null ) &
    NC=$!
    sleep 1
    echo "after 1 s: $(count_children) child serving it"
    sleep 4
    echo "after 5 s: $(count_children) child serving it"
    echo "server log:"
    grep -E 'connected|sent nothing' "$LOG" | sed 's/^/  /'
    kill $NC 2>/dev/null; wait $NC 2>/dev/null
    stop_server
}

title "WITHOUT the mechanism (--no-timeout)"
scenario --no-timeout

title "WITH the mechanism (3 second read timeout)"
scenario
