# common.sh - shared by the demo scripts (sourced, not run)
#
# Every demo starts its own server on $PORT, shows one thing, and stops it.

cd "$(dirname "$0")/.." || exit 1

PORT=${PORT:-9419}
LOG=/tmp/pmond-demo.log
BIN=build/bin            # normal build
DBG=build-debug/bin      # debug build
SRV=

# Both builds are needed; make only rebuilds what changed.
make -s && make -s DEBUG=1 || { echo "build failed"; exit 1; }

title() { printf '\n==== %s ====\n' "$*"; }

# Print a command, then run it.
run() { echo "\$ $*"; "$@"; }

# start_server <bin-dir> [pmond options...]
start_server() {
    local dir=$1; shift
    rm -f "$LOG"
    "$dir/pmond" -p "$PORT" "$@" 2>> "$LOG" &
    SRV=$!
    sleep 0.5
    echo "\$ $dir/pmond -p $PORT $*    (pid $SRV, log in $LOG)"
}

stop_server() {
    if [ -n "$SRV" ]; then
        kill -TERM "$SRV" 2>/dev/null
        wait "$SRV" 2>/dev/null
        SRV=
    fi
}
trap stop_server EXIT

# The server's children: pid, state (Z = zombie), memory in MB.
children() {
    ps --ppid "$SRV" -o pid=,stat=,vsz=,comm= |
        awk '{ printf "  child %s  state %s  %d MB  %s\n", $1, $2, $3/1024, $4 }'
}
count_children() { ps --ppid "$SRV" -o pid= | wc -l; }
count_zombies()  { ps --ppid "$SRV" -o stat= | grep -c Z; }
