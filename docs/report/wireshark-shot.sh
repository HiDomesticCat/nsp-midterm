#!/bin/bash
# wireshark-shot.sh - open a capture in Wireshark on a virtual display and
# save a picture of the window, with one packet selected and expanded.
#
#   docs/report/wireshark-shot.sh <file.pcap> <packet-number> <out.png>
cd "$(dirname "$0")/../.." || exit 1
PCAP=$1; PKT=$2; OUT=$3
W=1120; H=640

export DISPLAY=:98
Xvfb :98 -screen 0 ${W}x${H}x24 >/dev/null 2>&1 &
XVFB=$!
sleep 1

wireshark -X lua_script:docs/capture/pmon.lua -r "$PCAP" -g "$PKT" >/tmp/wireshark-shot.log 2>&1 &
WS=$!

# Wait for the main window, then make it fill the screen.
for i in $(seq 1 40); do
    WIN=$(xdotool search --onlyvisible --name "$(basename "$PCAP")" 2>/dev/null | head -1)
    [ -n "$WIN" ] && break
    sleep 0.5
done
if [ -z "$WIN" ]; then
    echo "wireshark window did not appear, see /tmp/wireshark-shot.log" >&2
    kill $WS $XVFB 2>/dev/null
    exit 1
fi
xdotool windowmove "$WIN" 0 0 windowsize "$WIN" $W $H
sleep 2

# Click in the packet details pane (lower left) to give it the keyboard, go
# to its last line, which is the pmon frame, and open it.
xdotool mousemove $((W / 4)) $((H - 60)) click 1
sleep 0.5
xdotool key End
sleep 0.3
xdotool key Right
sleep 1.5

import -window root "$OUT"
kill $WS 2>/dev/null
sleep 0.5
kill $XVFB 2>/dev/null
echo "saved $OUT"
