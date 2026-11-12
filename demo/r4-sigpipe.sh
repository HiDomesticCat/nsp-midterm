#!/bin/bash
# R4 - a client that is killed while the server is streaming to it.
. "$(dirname "$0")/common.sh"

scenario() {
    start_server $BIN "$@"
    echo "\$ pmon watch &      then, 2.5 s later:  kill -9 <client>"
    $BIN/pmon -s 127.0.0.1:$PORT watch -i 1 > /dev/null 2>&1 &
    W=$!
    sleep 2.5
    kill -9 $W; wait $W 2>/dev/null
    sleep 3.5
    echo "server log:"
    grep -E 'watching|is gone|killed by' "$LOG" | sed 's/^/  /'
    stop_server
}

title "WITHOUT the mechanism (--no-sigpipe)"
scenario --no-sigpipe

title "WITH the mechanism (notice the close; EPIPE instead of SIGPIPE)"
scenario
