# pmon System Design

Midterm project for Network and System Programming. `pmon` is a remote performance monitor:
the server runs on the machine being monitored, and several clients connect at the same time to ask for its system information and live performance figures.

Design principle: every item maps to one requirement of the assignment and can be shown in the demo with one or two commands.

| Component | File | Role |
|---|---|---|
| Server | `pmond` | Calls `fork()` for every connection, reads performance figures from `/proc` |
| Client | `pmon` | Command-line tool |
| Shared library | `libpmon.so` | Logging, reliable read and write, the protocol, `key=value` text handling |

## 1. Requirements and how each is shown

| Requirement | How it is met | What to look at in the demo | Status |
|---|---|---|---|
| `fork()` per connection, no threads | The parent only accepts and forks; a child serves one connection | The client prints the pid of the child serving it, different for every client | Done |
| At least 10 concurrent clients, with runtime proof | 10 clients run `watch` at once | `ps --forest` shows 1 parent and 10 children; `ss -tn` shows 10 connections | Done (`demo/02-ten-clients.sh`) |
| Packet capture and analysis | A binary protocol with a custom 12-byte header | The `tcpdump -X` output compared field by field with the header format | Done (`docs/CAPTURE.md`) |
| Compile-time and runtime debug log control | A compile-time macro; a runtime option and a signal | `strings` differs between the two builds; a signal to the running server makes the log more detailed at once | Done |
| Shared functions in a `.so` | `libpmon.so`, linked by both sides | `ldd` on both executables; the same `sha256sum` of the library on the server and the client VMs | Done |
| The client requests system information | `pmon sysinfo`, `pmon stat`, `pmon watch` | Run them | Done |
| Robustness, at least three comparisons with and without | Four mechanisms, each with an option that turns it off | The same script runs once with it off and once with it on | Done (`demo/r1`–`r4`) |
| Makefile or CMake | A hand-written Makefile | `make` | Done |

## 2. Functions

| Command | What it does |
|---|---|
| `pmon sysinfo` | Static facts about the host: host name, kernel version, number of CPUs, boot time, total memory and disk |
| `pmon stat` | Current performance figures, sampled once |
| `pmon watch [-i seconds] [-n count]` | Prints one line of figures at a fixed interval, until Ctrl+C or the count is reached |

Performance figures:

| Figure | Source | Calculation |
|---|---|---|
| CPU usage | `/proc/stat` | Share of non-idle time in the total time between two samples |
| Load and number of tasks | `/proc/loadavg` | Read directly |
| Memory, swap | `/proc/meminfo` | Total minus available |
| Disk usage | `statvfs("/")` | Used blocks as a share of usable blocks |
| Network receive and send rate | `/proc/net/dev` | Byte difference between two samples divided by the time, loopback excluded |

CPU and network figures are rates, so they need two samples. `stat` takes two samples 0.2 seconds apart; `watch` uses two consecutive pushes as the interval.

Output of `watch`:

```
server pid 8020, every 1 s
time       cpu%  load1   mem%    mem MB   disk%   rx kB/s   tx kB/s  tasks
14:14:43    0.5   0.17   14.2       554    17.4       0.1       0.0    204
14:14:44    0.0   0.17   14.2       554    17.4       0.4       0.5    204
```

`watch` is a long-lived connection, so when several people watch the same host there are several children on the server at once.
This is the natural situation for 10 concurrent clients.

## 3. Protocol

TCP, port 9419 by default, multi-byte fields in network byte order. Requests and responses use the same frame.

| Offset | Size | Field | Meaning |
|---|---|---|---|
| 0 | 2 | magic | Always `0x504D` (ASCII `PM`) |
| 2 | 1 | opcode | Operation code |
| 3 | 1 | status | Result code of a response, 0 in a request |
| 4 | 4 | length | Number of payload bytes, at most 64 KiB |
| 8 | 4 | crc32 | CRC-32 of the payload |

The payload is lines of `key=value` text and can be read directly in `tcpdump -A`.

| Opcode | Name | Request payload | Response payload |
|---|---|---|---|
| 1 | SYSINFO | None | Static facts about the host |
| 2 | STAT | None | One set of performance figures |
| 3 | WATCH | `interval` (1–60 seconds), `count` (0 means no limit) | One frame every interval, same content as STAT |

| Status | Meaning |
|---|---|
| 0 OK | Success |
| 1 BAD_REQUEST | Malformed frame, unknown opcode, or a parameter out of range |
| 2 BUSY | The connection limit has been reached |
| 3 INTERNAL | An error inside the server |

The flow of `watch`:

```
client                              server (child)
  | WATCH interval=1 count=0 -----> |  take the first sample
  |                                 |  wait 1 s (and notice if the client leaves)
  | <----------- WATCH OK figures   |  sample, compute, send
  |                                 |  wait 1 s
  | <----------- WATCH OK figures   |
  | (Ctrl+C, connection closed)     |  sees the connection closed, exits
```

## 4. Server process model

```
pmond (parent)   socket -> bind -> listen -> main loop
  |- child  <- client A
  |- child  <- client B
  `- ...
```

- **The parent's main loop**: waits for a new connection with `poll()`. When one arrives it calls `accept()` and then `fork()`,
  closes its own copy of the connection socket and waits for the next one. If the number of children is over the limit (64 by default) it replies BUSY and closes.
- **The child**: closes the listening socket and repeats "read a frame → handle it → reply" until the client disconnects, then exits.
- **Signal handlers only set a flag**; the real work is done in the main loop. The main loop can then safely use logging and other functions that must not be called inside a signal handler.
  - `SIGCHLD`: the main loop reaps exited children in a `waitpid(-1, WNOHANG)` loop. If a child was killed by a signal, the signal is logged.
  - `SIGINT` / `SIGTERM`: the main loop ends, tells every child to exit and then leaves.
  - `SIGUSR1`: toggles debug output.

## 5. Two levels of debug logging

| Level | How it is controlled | Effect |
|---|---|---|
| Compile time | `make` versus `make DEBUG=1` | In a normal build `LOG_DEBUG()` produces no code, and the debug message strings are not in the executable |
| Runtime | The `-v` option, the environment variable `PMON_LOG=debug`, or `SIGUSR1` sent to the server | In a debug build, switches debug output on and off without restarting |

Every log line carries the time, the level, the program name and pid, and the source file and line number. The pid tells apart the output of several children.
Each line is written with a single `write()`, so lines from different processes do not interleave.

```
2026-11-06 14:14:09.759 [DEBUG] pmond[7845] lib/proto.c:72: send frame op=STAT status=OK len=182
```

How it is shown:

- Compile time: `strings` on the executables of both builds, looking for the same debug message. It is absent from the normal build and present in the debug build.
- Runtime: `pkill -USR1 pmond` while the server is running; debug messages appear from the next request on. Sending it again turns them off.

## 6. Robustness

Each of the four mechanisms has an option that turns it off, to show the difference with and without it.

| No. | Abnormal situation | Mechanism | Option | How to trigger it | What is seen with it off | What is seen with it on |
|---|---|---|---|---|---|---|
| R1 | A child exits | `SIGCHLD` + `waitpid` | `--no-reap` | Run `pmon stat` a few times | More and more `<defunct>` entries in `ps` | No zombie processes |
| R2 | Data that is not this protocol | Check the magic, the length limit and the CRC | `--no-validate` | `curl http://server:9419/` | The child takes the HTTP text as a header, allocates a large amount of memory and waits for a huge payload | BAD_REQUEST at once, then disconnect |
| R3 | A client connects and sends nothing | 10-second read timeout | `--no-timeout` | `nc server 9419` and leave it | The child stays forever | The child logs the timeout and exits |
| R4 | The client is killed in the middle of `watch` | Notice a closed connection while waiting; ignore `SIGPIPE` and let `send()` return `EPIPE` | `--no-sigpipe` | `kill -9` the client during `watch` | The parent logs that the child was killed by `SIGPIPE` | The child logs that the client left and exits normally |

Also implemented, without an option to turn them off:

- Reads and writes loop to handle short reads, short writes and `EINTR`.
- A connection limit, with a BUSY reply beyond it. A failed `fork()` also gets a BUSY reply and does not end the server.
- When invalid data is rejected, the server sends the error reply and drains what the peer has already sent before closing. Closing directly makes the kernel send a reset, and the peer never sees the reply.
- Range checks on the `watch` parameters.
- `SO_REUSEADDR`, so the server can be restarted without waiting.
- Connect and response timeouts in the client.

## 7. The shared library `libpmon.so`

| Module | Content | Used by the server for | Used by the client for |
|---|---|---|---|
| `log` | The two-level control of section 5 and the output format | Recording connections and errors | Debug output |
| `io` | Complete read and write with a timeout | Reading requests, sending responses | Sending requests, reading responses |
| `proto` | Sending, receiving and checking frames; CRC-32 | Same as above | Same as above |
| `kv` | Getting a value out of `key=value` text | Reading the `watch` parameters | Picking figures out of a response to print a table |

Built with `-fPIC -shared`. The executables are linked with the rpath `$ORIGIN/../lib`,
so they look for the library in the `lib/` directory next to their own location, and `LD_LIBRARY_PATH` does not have to be set.

## 8. Build, deployment and layout

| Command | What it does |
|---|---|
| `make` | Normal build, output in `build/` |
| `make DEBUG=1` | Debug build: keeps the debug log, adds `-g`, output in `build-debug/` |
| `make deploy` | Copies the client executable and `libpmon.so` to `~/pmon/` on the two client VMs |
| `make clean` | Removes the build output |

Development workflow:

- The source lives only on `nsp-server` and is compiled there. The two client VMs have no compiler.
- `make deploy` sends `pmon` and the very `libpmon.so` the server is using to the client VMs.
- For testing, the server runs on `nsp-server` and the clients connect from the two client VMs over the test network:
  `~/pmon/bin/pmon -s nsp-server watch`.
- Version control: git, one commit per feature or fix, with a message that says why. `build/` and `build-debug/` are not tracked.

```
nsp-midterm/
  Makefile
  include/pmon.h    header of the library
  lib/              libpmon.so: log.c io.c proto.c kv.c
  server/           pmond: pmond.c session.c sysinfo.c metrics.c
  client/           pmon: pmon.c
  demo/             one script per demo item
  infra/            OpenStack environment
  docs/             design documents, report
```

## 9. Demo scripts

Each script does one thing, and its output is what goes into the report as a screenshot.

| Script | Shows |
|---|---|
| `demo/01-basic.sh` | The normal flow of sysinfo, stat and watch |
| `demo/02-ten-clients.sh` | 10 clients running `watch` at once, with `ps --forest` and `ss -tn` |
| `demo/03-capture.sh` | One stat captured with `tcpdump -X` |
| `demo/04-debug-log.sh` | Compile-time and runtime log control |
| `demo/05-shared-lib.sh` | `ldd` and `sha256sum` |
| `demo/r1-zombie.sh` to `demo/r4-sigpipe.sh` | Four robustness mechanisms, each run with it off and on |
| `demo/verify.sh` | Checks every requirement and prints PASS or FAIL |

Test environments:

- Single machine: loopback on `nsp-server`, `tcpdump -i lo`.
- Two machines: the server on `nsp-server`, 5 clients on each of the two client VMs, captured on the test network and opened in Wireshark.

## 10. Progress

| Stage | Content | Status |
|---|---|---|
| 1 | Makefile, `libpmon.so`, logging, protocol, fork server, `sysinfo` | Done |
| 2 | Performance figures `stat`, live `watch` | Done |
| 3 | The four options, demo scripts, packet capture and analysis | Done |
| 4 | Report and video | Report done, video to do |
