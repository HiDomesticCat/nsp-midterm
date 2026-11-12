#!/bin/bash
# R2 - bytes that are not our protocol (here: an HTTP request from curl).
. "$(dirname "$0")/common.sh"

scenario() {
    start_server $BIN -t 6 "$@"
    echo "\$ curl -m 4 http://127.0.0.1:$PORT/"
    curl -s -m 4 -o /dev/null "http://127.0.0.1:$PORT/" &
    CURL=$!
    sleep 1
    echo "one second later, children of the server:"
    children
    [ "$(count_children)" = 0 ] && echo "  (none - the connection is already closed)"
    wait $CURL
    echo "curl exit code: $?   (28 = gave up after 4 s without any answer)"
    sleep 0.5
    echo "server log:"
    grep -E "rejected|invalid" "$LOG" | sed "s/^/  /" | grep . || echo "  (nothing - the server did not notice anything wrong)"
    stop_server
}

title "WITHOUT the mechanism (--no-validate)"
echo "'GET / HTTP/1.1' is read as a header: bytes 4-7 '/ HT' = 0x2f204854,"
echo "a payload length of 790,644,820 bytes (754 MiB). The child allocates it and waits."
scenario --no-validate

title "WITH the mechanism (magic, length limit, CRC)"
scenario
