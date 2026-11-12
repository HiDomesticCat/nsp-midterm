#!/bin/bash
# verify.sh - check every course requirement by itself and print PASS or FAIL.
# It builds both variants, starts its own server, and does not use the other
# demo scripts.   demo/verify.sh
cd "$(dirname "$0")/.." || exit 1
PORT=9601
LOG=/tmp/audit-pmond.log
pass=0; fail=0
ok()  { echo "  PASS  $*"; pass=$((pass+1)); }
bad() { echo "  FAIL  $*"; fail=$((fail+1)); }
is()  { if [ "$2" = "$3" ]; then ok "$1 (= $2)"; else bad "$1 (got '$2', want '$3')"; fi; }
ge()  { if [ "$2" -ge "$3" ] 2>/dev/null; then ok "$1 (= $2)"; else bad "$1 (got '$2', want >= $3)"; fi; }
start() { : > $LOG; "$@" 2>>$LOG & SRV=$!; sleep 0.6; }
stop()  { kill $SRV 2>/dev/null; wait $SRV 2>/dev/null; }
kids()  { pgrep -P $SRV | wc -l; }
zomb()  { ps -o stat= --ppid $SRV | grep -c Z; }

echo "== 8. Makefile: clean build of both variants"
make clean >/dev/null 2>&1
o1=$(make 2>&1); r1=$?; o2=$(make DEBUG=1 2>&1); r2=$?
is "make exit status" $r1 0
is "make DEBUG=1 exit status" $r2 0
is "compiler warnings" "$(echo "$o1$o2" | grep -ci warning)" 0
echo "      flags: $(grep -o -- '-W[a-z]*' Makefile | sort -u | tr '\n' ' ')"
echo "      built: $(ls build/bin build/lib build-debug/bin build-debug/lib | tr '\n' ' ')"

echo "== 1. fork per connection, no threads"
ge "fork() calls in server/pmond.c" "$(grep -c 'fork()' server/pmond.c)" 1
is "files mentioning pthread" "$(grep -rIl pthread Makefile include lib server client | wc -l)" 0
is "pthread_create imported by pmond" "$(nm -D build/bin/pmond | grep -c pthread_create)" 0

echo "== 2. ten clients at once (same machine)"
start build/bin/pmond -p $PORT
cp=""
for i in 1 2 3 4 5 6 7 8 9 10; do
    build/bin/pmon -s 127.0.0.1:$PORT sysinfo --hold 4 >/tmp/audit-c$i.out 2>&1 & cp="$cp $!"
done
sleep 1.5
is "child processes of pmond" "$(kids)" 10
is "established connections on port" "$(ss -Htn state established "( sport = :$PORT )" | wc -l)" 10
is "distinct child pids" "$(pgrep -P $SRV | sort -u | wc -l)" 10
is "max threads in any pmond process" "$(ps -o nlwp= -p $SRV $(pgrep -P $SRV) | sort -n | tail -1 | tr -d ' ')" 1
is "children whose parent is pmond" "$(ps -o ppid= $(pgrep -P $SRV) | grep -c "$SRV")" 10
good=0; for p in $cp; do wait $p && good=$((good+1)); done
is "clients that got an answer" $good 10
sleep 1.2
is "children left after clients finish" "$(kids)" 0
is "zombies left" "$(zomb)" 0

echo "== 2b. ten clients at once (two other machines, 5 + 5)"
rp=""
for h in nsp-client-1 nsp-client-2; do
    ssh -n $h "for i in 1 2 3 4 5; do pmon/bin/pmon -s nsp-server:$PORT sysinfo --hold 5 >/dev/null & done; wait" & rp="$rp $!"
done
sleep 3
is "child processes of pmond" "$(kids)" 10
ss -Htn state established "( sport = :$PORT )" | awk '{print $4}' | sed 's/:[0-9]*$//' | sort | uniq -c | sed 's/^/      peers:/'
for p in $rp; do wait $p; done
sleep 1.2
is "children left afterwards" "$(kids)" 0

echo "== 6. client asks the server for system information"
out=$(build/bin/pmon -s 127.0.0.1:$PORT sysinfo); rc=$?
is "pmon sysinfo exit status" $rc 0
ge "lines of system information" "$(echo "$out" | wc -l)" 5
echo "$out" | head -5 | sed 's/^/      /'
out=$(build/bin/pmon -s 127.0.0.1:$PORT stat); is "pmon stat exit status" $? 0
out=$(build/bin/pmon -s 127.0.0.1:$PORT watch -n 2); is "pmon watch -n 2 exit status" $? 0
is "watch rows shown" "$(echo "$out" | tail -n +3 | wc -l)" 2
stop

echo "== 4. debug log: compile time"
grep -rhoE 'LOG_DEBUG\("[^"]+' server lib client | sed 's/LOG_DEBUG("//' | sort -u > /tmp/audit-dbg.txt
n=$(wc -l < /tmp/audit-dbg.txt)
ge "debug messages in the source" $n 3
strings build/bin/pmond build/bin/pmon build/lib/libpmon.so > /tmp/audit-rel.str
strings build-debug/bin/pmond build-debug/bin/pmon build-debug/lib/libpmon.so > /tmp/audit-deb.str
is "of those, present in the normal build" "$(grep -cFf /tmp/audit-dbg.txt /tmp/audit-rel.str)" 0
ge "of those, present in the debug build" "$(grep -cFf /tmp/audit-dbg.txt /tmp/audit-deb.str)" $n

echo "== 4. debug log: run time (debug build)"
dbg() { grep -c DEBUG $LOG; }
start build-debug/bin/pmond -p $PORT
build-debug/bin/pmon -s 127.0.0.1:$PORT stat >/dev/null; sleep 0.3
is "DEBUG lines, started without -v" "$(dbg)" 0
kill -USR1 $SRV; sleep 0.3
build-debug/bin/pmon -s 127.0.0.1:$PORT stat >/dev/null; sleep 0.3
a=$(dbg); ge "DEBUG lines after SIGUSR1 (on)" $a 1
kill -USR1 $SRV; sleep 0.3
build-debug/bin/pmon -s 127.0.0.1:$PORT stat >/dev/null; sleep 0.3
is "DEBUG lines after SIGUSR1 again (off, unchanged)" "$(dbg)" $a
stop
start build-debug/bin/pmond -p $PORT -v
build-debug/bin/pmon -s 127.0.0.1:$PORT stat >/dev/null; sleep 0.3
ge "DEBUG lines, started with -v" "$(dbg)" 1
stop
: > $LOG; PMON_LOG=debug build-debug/bin/pmond -p $PORT 2>>$LOG & SRV=$!; sleep 0.6
build-debug/bin/pmon -s 127.0.0.1:$PORT stat >/dev/null; sleep 0.3
ge "DEBUG lines, started with PMON_LOG=debug" "$(dbg)" 1
stop
start build/bin/pmond -p $PORT -v
build/bin/pmon -s 127.0.0.1:$PORT stat >/dev/null; sleep 0.3
is "DEBUG lines, normal build with -v" "$(dbg)" 0
stop

echo "== 5. shared library used by both sides"
is "libpmon.so is a shared object" "$(file build/lib/libpmon.so | grep -c 'shared object')" 1
is "pmond needs libpmon.so" "$(readelf -d build/bin/pmond | grep -c 'NEEDED.*libpmon.so')" 1
is "pmon needs libpmon.so"  "$(readelf -d build/bin/pmon  | grep -c 'NEEDED.*libpmon.so')" 1
nm -D --defined-only build/lib/libpmon.so | awk '{print $NF}' | sort > /tmp/audit-lib.sym
for b in pmond pmon; do
    u=$(nm -D --undefined-only build/bin/$b | awk '{print $NF}' | sort | comm -12 - /tmp/audit-lib.sym)
    ge "library functions imported by $b" "$(echo "$u" | wc -l)" 3
    echo "      $(echo $u)"
    is "copies of proto_send inside $b itself" "$(nm --defined-only build/bin/$b 2>/dev/null | grep -c ' T proto_send')" 0
done
mkdir -p /tmp/audit-alone && cp build/bin/pmon /tmp/audit-alone/
/tmp/audit-alone/pmon -h >/dev/null 2>/tmp/audit-alone.err; rc=$?
is "client without the library next to it: exit status" $rc 127
head -1 /tmp/audit-alone.err | sed 's/^/      /'
h0=$(sha256sum < build/lib/libpmon.so | cut -c1-16)
for h in nsp-client-1 nsp-client-2; do
    is "libpmon.so on $h identical to the one built here" "$(ssh -n $h 'sha256sum < pmon/lib/libpmon.so | cut -c1-16')" "$h0"
    is "compilers on $h" "$(ssh -n $h 'which gcc cc 2>/dev/null | wc -l')" 0
done

echo "== 3. packet captures"
for f in docs/capture/stat-lo.pcap docs/capture/stat-ens4.pcap; do
    is "$f: packets" "$(tshark -r $f 2>/dev/null | wc -l)" 10
    tshark -r $f -Y 'tcp.len > 0' -T fields -e ip.src -e ip.dst -e tcp.len -e tcp.payload 2>/dev/null | cut -c1-74 | sed 's/^/      /'
    is "$f: data packets starting with magic 504d" "$(tshark -r $f -Y 'tcp.len > 0' -T fields -e tcp.payload 2>/dev/null | grep -c '^504d')" 2
done

echo "== 7. robustness, R1 checked independently"
start build/bin/pmond -p $PORT --no-reap
for i in 1 2 3 4 5; do build/bin/pmon -s 127.0.0.1:$PORT stat >/dev/null; done; sleep 0.5
is "zombies with --no-reap" "$(zomb)" 5
stop
start build/bin/pmond -p $PORT
for i in 1 2 3 4 5; do build/bin/pmon -s 127.0.0.1:$PORT stat >/dev/null; done; sleep 1.2
is "zombies with reaping" "$(zomb)" 0
stop

echo "== report: every source file is in the appendix"
grep '^@source ' docs/report/REPORT.md | awk '{print $2}' | sort > /tmp/audit-rep.lst
git ls-files Makefile include lib server client demo | sort > /tmp/audit-git.lst
is "source files missing from the appendix" "$(comm -13 /tmp/audit-rep.lst /tmp/audit-git.lst | wc -l)" 0
comm -13 /tmp/audit-rep.lst /tmp/audit-git.lst | sed 's/^/      missing: /'
is "report images that do not exist" "$(cd docs/report && grep '^@image ' REPORT.md | awk '{print $2}' | while read p; do [ -f "$p" ] || echo x; done | wc -l)" 0
echo "      images in report: $(grep -c '^@image ' docs/report/REPORT.md)"

echo
echo "RESULT: $pass passed, $fail failed"
