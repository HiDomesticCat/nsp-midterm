#!/bin/bash
# R1 - children that exit must be collected, or they stay as zombies.
. "$(dirname "$0")/common.sh"

scenario() {
    start_server $BIN "$@"
    echo "\$ 5 x pmon stat"
    for i in 1 2 3 4 5; do $BIN/pmon -s 127.0.0.1:$PORT stat > /dev/null; done
    sleep 1.5
    echo "children of the server after all five clients have finished:"
    children
    echo "zombies: $(count_zombies)"
    stop_server
}

title "WITHOUT the mechanism (--no-reap)"
scenario --no-reap

title "WITH the mechanism (SIGCHLD + waitpid loop)"
scenario
