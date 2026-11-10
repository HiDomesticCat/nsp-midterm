#!/bin/bash
# NSP midterm - run inside a homework VM to confirm the base OS is ready.
echo "== $(hostname)  $(. /etc/os-release; echo "$PRETTY_NAME")  kernel $(uname -r)"
echo "-- cloud-init: $(cloud-init status --wait 2>&1 | tail -1)"
echo "-- ready marker: $([ -e /var/lib/nsp-ready ] && echo present || echo MISSING)"
echo "-- addresses"
ip -br -4 addr show scope global
echo "-- default route"
ip route show default
echo "-- /etc/hosts entries"
grep nsp- /etc/hosts || echo "MISSING"
echo "-- peers on nsp-net"
for h in nsp-server nsp-client-1 nsp-client-2; do
  if ping -c1 -W2 "$h" >/dev/null 2>&1; then echo "$h ok"; else echo "$h UNREACHABLE"; fi
done
echo "-- tools"
for t in gcc make cmake gdb valgrind tcpdump tshark strace ltrace cppcheck git nc tmux; do
  if command -v "$t" >/dev/null 2>&1; then printf '%s ' "$t"; else printf '(no %s) ' "$t"; fi
done
echo
command -v gcc >/dev/null 2>&1 && gcc --version | head -1
echo "-- resources: $(nproc) vCPU, $(free -m | awk '/^Mem:/{print $2}') MB RAM, root $(df -h / | awk 'NR==2{print $2" total, "$4" free"}')"
