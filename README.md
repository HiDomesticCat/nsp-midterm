# pmon

A remote performance monitor. Midterm project for Network and System Programming.

The server (`pmond`) runs on the machine being monitored and calls `fork()` for every connection.
The client (`pmon`) connects and asks for the machine's system information and live performance figures.
Both link the shared library `libpmon.so`.

## Build

```
make            # normal build -> build/
make DEBUG=1    # debug build -> build-debug/ (keeps the debug log)
make deploy     # copy the client and libpmon.so to the client VMs
make dist       # pack the committed source into pmon-source.zip
make clean
```

gcc and make are required. The demo scripts also use `tcpdump`, `nc` and `curl`.

## Usage

```
build/bin/pmond                          # start the server, port 9419 by default
build/bin/pmon sysinfo                   # static facts about the host
build/bin/pmon stat                      # current CPU, memory, disk, network
build/bin/pmon watch -i 1                # one line per second, Ctrl+C to stop
build/bin/pmon -s nsp-server watch       # connect to another host
```

`pmond -h` and `pmon -h` list every option.

## Demo

Each script shows one requirement of the assignment and starts and stops the server by itself.

| Script | Requirement |
|---|---|
| `demo/01-basic.sh` | The client requests system information from the server |
| `demo/02-ten-clients.sh [remote]` | `fork()` per connection; runtime proof of 10 concurrent clients |
| `demo/03-capture.sh [interface remote]` | Packet capture (analysis in `docs/CAPTURE.md`) |
| `demo/04-debug-log.sh` | Compile-time and runtime debug log control |
| `demo/05-shared-lib.sh` | Dynamic library shared by server and client |
| `demo/r1-zombie.sh` | Robustness: reaping exited children |
| `demo/r2-validate.sh` | Robustness: rejecting data that is not the protocol |
| `demo/r3-timeout.sh` | Robustness: a client that sends nothing times out |
| `demo/r4-sigpipe.sh` | Robustness: the server is not killed when a client disappears |
| `demo/run-all.sh [pause]` | Runs all of them in order |
| `demo/verify.sh` | Checks every requirement and prints PASS or FAIL (also needs `tshark`) |

The four `r*` scripts each run twice, first with the mechanism off and then with it on, to compare the behaviour.

## Layout

```
include/pmon.h    header of the library
lib/              libpmon.so: log.c io.c proto.c kv.c
server/           pmond: pmond.c session.c sysinfo.c metrics.c
client/           pmon: pmon.c
demo/             demo scripts
docs/             DESIGN.md (system design), CAPTURE.md (packet analysis), capture/ (captures and the Wireshark dissector pmon.lua)
infra/            scripts that create the test VMs
```
