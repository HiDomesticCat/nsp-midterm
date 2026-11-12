#!/bin/bash
# 02 - ten clients connected at the same time, one forked child each.
#
#   demo/02-ten-clients.sh           ten clients on this machine
#   demo/02-ten-clients.sh remote    five on each client VM (run "make deploy" first)
. "$(dirname "$0")/common.sh"

title "start the server"
start_server $BIN

title "ten clients, each watching for 6 seconds"
if [ "$1" = remote ]; then
    for h in nsp-client-1 nsp-client-2; do
        echo "\$ ssh $h '5 x pmon -s nsp-server watch -n 6'"
        ssh -n "$h" "for i in 1 2 3 4 5; do pmon/bin/pmon -s nsp-server:$PORT watch -n 6 > /dev/null & done; wait" &
    done
else
    for i in $(seq 1 10); do
        $BIN/pmon -s 127.0.0.1:$PORT watch -n 6 > /tmp/pmon-watch-$i.out &
    done
    echo "\$ 10 x $BIN/pmon watch -n 6 &"
fi
sleep 3

title "proof 1: process tree - one parent, ten children"
run ps --forest -o pid,ppid,stat,etime,cmd -C pmond

title "proof 2: ten established TCP connections on port $PORT"
run ss -tn state established "( sport = :$PORT )"
echo "connections: $(ss -Htn state established "( sport = :$PORT )" | wc -l)"
echo "by client address:"
ss -Htn state established "( sport = :$PORT )" | awk '{print $4}' | sed 's/:[0-9]*$//' | sort | uniq -c

title "wait for the clients to finish"
wait $(jobs -p | grep -v "^$SRV$") 2>/dev/null
sleep 1.5
if [ "$1" != remote ]; then
    echo "each client was served by a different process:"
    grep -h 'server pid' /tmp/pmon-watch-*.out | sort | uniq -c
    rm -f /tmp/pmon-watch-*.out
fi
echo "children left: $(count_children)   zombies: $(count_zombies)"

title "proof 3: the server log, one pid per client"
stop_server
echo "clients that connected: $(grep -c ' connected' "$LOG")"
grep ' connected' "$LOG"
