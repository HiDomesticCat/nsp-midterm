#!/bin/bash
# 03 - capture one request and one response with tcpdump.
#
#   demo/03-capture.sh              loopback, request made on this machine
#   demo/03-capture.sh ens4 remote  test network, request made from nsp-client-1
#
# The capture is saved under docs/capture/ (open the .pcap in Wireshark).
. "$(dirname "$0")/common.sh"

IFACE=${1:-lo}
OUT=docs/capture/stat-$IFACE
mkdir -p docs/capture

title "start the server and tcpdump on $IFACE"
start_server $BIN
sudo tcpdump -i "$IFACE" -nn -U -w "$OUT.pcap" "tcp port $PORT" 2>/dev/null &
sleep 1

title "one stat request"
if [ "$2" = remote ]; then
    run ssh -n nsp-client-1 "pmon/bin/pmon -s nsp-server:$PORT stat"
else
    run $BIN/pmon -s 127.0.0.1:$PORT stat
fi
sleep 1
sudo pkill -INT -x tcpdump
sleep 0.5
stop_server

title "the packets (tcpdump -nn -X)"
sudo chown "$(id -u):$(id -g)" "$OUT.pcap"
tcpdump -r "$OUT.pcap" -nn -X 2>/dev/null | tee "$OUT.txt"
echo
echo "saved: $OUT.pcap  $OUT.txt"
