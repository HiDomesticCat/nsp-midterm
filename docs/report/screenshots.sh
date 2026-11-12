#!/bin/bash
# screenshots.sh - run each demo in a real terminal (xterm) on a virtual
# display and save a screenshot of the terminal window.
#
#   docs/report/screenshots.sh          all demos -> docs/screenshots/*.png
#
# Needs: xvfb xterm imagemagick fonts-dejavu-core
cd "$(dirname "$0")/../.." || exit 1
OUT=docs/screenshots
mkdir -p "$OUT"
export DISPLAY=:99

Xvfb :99 -screen 0 1400x3200x24 >/dev/null 2>&1 &
XVFB=$!
trap 'kill $XVFB 2>/dev/null' EXIT
sleep 1

shot() {   # shot <name> <demo script> [args]
    local name=$1; shift
    local done_flag=/tmp/shot-done
    rm -f $done_flag
    xterm -fa "DejaVu Sans Mono" -fs 10 -geometry 150x180+0+0 \
          -bg "#1e1e1e" -fg "#d4d4d4" -bw 0 +sb \
          -e bash -c "printf '\033[1;32mubuntu@nsp-server\033[0m:\033[1;34m~/nsp-midterm\033[0m\$ %s\n' '$*'; $* 2>&1; touch $done_flag; sleep 600" &
    local xt=$!
    for i in $(seq 1 120); do [ -e $done_flag ] && break; sleep 0.5; done
    sleep 0.7
    import -window root "$OUT/$name-full.png"
    kill $xt 2>/dev/null; wait $xt 2>/dev/null
    # cut away the unused part of the screen, keep a small margin
    convert "$OUT/$name-full.png" -fuzz 2% -trim +repage -shave 2x2 -trim +repage \
            -bordercolor "#1e1e1e" -border 14 "$OUT/$name.png"
    rm -f "$OUT/$name-full.png"
    echo "$name: $(identify -format '%wx%h' "$OUT/$name.png")"
}

shot 01-basic          demo/01-basic.sh
shot 02-ten-clients    demo/02-ten-clients.sh
shot 02-ten-clients-remote demo/02-ten-clients.sh remote
shot 04-debug-log      demo/04-debug-log.sh
shot 05-shared-lib     demo/05-shared-lib.sh
shot r1-zombie         demo/r1-zombie.sh
shot r2-validate       demo/r2-validate.sh
shot r3-timeout        demo/r3-timeout.sh
shot r4-sigpipe        demo/r4-sigpipe.sh
