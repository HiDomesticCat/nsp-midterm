#!/bin/bash
# 05 - the server and the client share one dynamic library.
. "$(dirname "$0")/common.sh"

title "the library is a shared object"
run file build/lib/libpmon.so

title "functions it exports"
nm -D --defined-only build/lib/libpmon.so | awk '$2=="T"{print $3}' | column -c 78

title "both programs need it, and look for it next to themselves"
for p in pmond pmon; do
    echo "--- $p"
    readelf -d build/bin/$p | grep -E 'NEEDED.*pmon|RUNPATH|RPATH' | sed 's/^ */  /'
    ldd build/bin/$p | grep pmon | sed 's/^[[:space:]]*/  /'
done

title "the functions are not copied into the programs"
for p in pmond pmon; do
    echo "$p: proto_send is '$(nm -D build/bin/$p | awk '$NF=="proto_send"{print $(NF-1)}')' (U = undefined here, resolved from libpmon.so at load time)"
done

title "without the library the programs do not start"
mv build/lib/libpmon.so build/lib/libpmon.so.hidden
run build/bin/pmon stat
mv build/lib/libpmon.so.hidden build/lib/libpmon.so

title "the client VMs run the very same library file"
echo "nsp-server    $(sha256sum build/lib/libpmon.so | cut -c1-32)"
for h in nsp-client-1 nsp-client-2; do
    sum=$(ssh -n -o ConnectTimeout=3 "$h" 'sha256sum pmon/lib/libpmon.so 2>/dev/null | cut -c1-32' 2>/dev/null)
    echo "$h  ${sum:-not deployed (run: make deploy)}"
done
