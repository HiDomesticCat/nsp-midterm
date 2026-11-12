# pmon: A Remote Performance Monitor

Network and System Programming, Midterm Report

Name: ____________    Student ID: ____________

# 1. Introduction

## 1.1 What the system does

`pmon` is a remote performance monitor. The server (`pmond`) runs on the machine being monitored. The client (`pmon`) connects from another machine and asks for that machine's system information and live performance figures.

The scenario is a compute host shared by several people. A user wants to know how busy the host is before submitting a job, and an administrator wants to keep an eye on the load. Each of them runs `pmon watch`, so several clients are connected to the same server at the same time.

| Command | What it does |
|---|---|
| `pmon sysinfo` | Static facts about the host: host name, kernel version, number of CPUs, boot time, total memory and disk |
| `pmon stat` | Current performance figures, sampled once |
| `pmon watch [-i seconds] [-n count]` | Prints one line of figures at a fixed interval, until Ctrl+C or the count is reached |

## 1.2 Requirements and where they are covered

| Requirement | How it is met | Sections |
|---|---|---|
| The server uses `fork()` for each client connection, no threads | The parent only accepts and forks | 2.3, 3.1, 4.2 |
| At least 10 concurrent clients, with runtime proof | 10 clients run `watch` at once; `ps`, `ss` and the server log are compared | 4.2 |
| Packet capture and analysis | `tcpdump` on loopback and between two machines; the cross-machine capture is also viewed in Wireshark | 6 |
| Two levels of debug log control: compile time and runtime | A compile-time macro; at runtime an option, an environment variable and `SIGUSR1` | 2.4, 3.4, 4.3 |
| Shared utility functions in a dynamic shared library used by both sides | `libpmon.so` | 2.5, 3.6, 4.4 |
| The client requests system information from the server | `sysinfo`, `stat`, `watch` | 4.1 |
| Robustness mechanisms, at least three examples with and without | Four mechanisms, each with an option that turns it off | 5 |
| Built with Makefile or CMake | A hand-written Makefile | 3.6 |

## 1.3 Development and test environment

| Host | Role | Specification | Test network address |
|---|---|---|---|
| `nsp-server` | Development, compilation, runs the server | 2 vCPU, 4 GB, Ubuntu 24.04, gcc 13.3 | 10.77.0.10 |
| `nsp-client-1` | Runs clients | 1 vCPU, 2 GB, no compiler | 10.77.0.21 |
| `nsp-client-2` | Runs clients | 1 vCPU, 2 GB, no compiler | 10.77.0.22 |

The three hosts are virtual machines on OpenStack, attached to an isolated test network with no outside access. The source is compiled only on `nsp-server`; `make deploy` copies the client executable and the library to the two client hosts. Every output in this report was produced by actually running the programs in this environment.

# 2. System Design

## 2.1 Components

| Component | File | Source | Role |
|---|---|---|---|
| Server | `pmond` | `server/` | Accepts connections, forks a child for each, reads performance figures from `/proc` |
| Client | `pmon` | `client/` | Command-line tool that sends requests and prints the results |
| Shared library | `libpmon.so` | `lib/`, `include/pmon.h` | Logging, reliable read and write, the protocol, `key=value` text handling |

## 2.2 Protocol

The protocol runs over TCP, port 9419 by default. Requests and responses use the same frame: a 12-byte header followed by 0 to 65536 bytes of payload. Multi-byte fields are in network byte order.

| Offset | Size | Field | Meaning |
|---|---|---|---|
| 0 | 2 | magic | Always `0x504D` (ASCII `PM`) |
| 2 | 1 | opcode | Operation code |
| 3 | 1 | status | Result code of a response, 0 in a request |
| 4 | 4 | length | Number of payload bytes, at most 64 KiB |
| 8 | 4 | crc32 | CRC-32 of the payload |

The payload is lines of `key=value` text.

| Opcode | Name | Request payload | Response payload |
|---|---|---|---|
| 1 | SYSINFO | None | Static facts about the host |
| 2 | STAT | None | One set of performance figures |
| 3 | WATCH | `interval` (1 to 60 seconds), `count` (0 means no limit) | One frame every interval, same content as STAT |

| Status | Meaning |
|---|---|
| 0 OK | Success |
| 1 BAD_REQUEST | Malformed frame, unknown opcode, or a parameter out of range |
| 2 BUSY | The connection limit has been reached |
| 3 INTERNAL | An error inside the server |

## 2.3 Server process model and flow

The diagram below shows one connection from start to finish. The three vertical lines are the client, the server parent and the server child.

@image ../diagrams/flow.png

- The client's `connect()` is answered by the parent's `accept()`. The parent then calls `fork()` and hands the connection to the child.
- After `fork()` each side closes the descriptor it does not need: the parent closes the connection, the child closes the listening socket. The parent goes back to `poll()` to wait for the next client, which is why the request and response arrows in the diagram pass over the parent and go straight to the child.
- The dashed box is the child's request loop. One connection can carry several requests.
- When the client closes the connection, the child reads EOF and exits. The kernel sends `SIGCHLD` to the parent, which reaps the child with `waitpid()` and writes a log line.

With several clients connected, each connection has its own child:

```
pmond (parent)   socket -> bind -> listen -> main loop
  |- child  <- client A
  |- child  <- client B
  `- ...
```

The parent's main loop:

1. Wait with `poll()` for a new connection on the listening socket, for at most one second.
2. Call `accept()` when there is one. If the number of children has reached the limit (64 by default), reply with a BUSY frame and close.
3. Call `fork()`. The child closes the listening socket and enters the request loop. The parent closes the connection socket, records the child's pid and returns to step 1.
4. At the start of every round, check the signal flags: reap children that have exited, and leave the loop if asked to stop.

The child's request loop: read a frame, check it, handle it, reply, and repeat until the client disconnects; then the process exits.

The flow of one `watch`:

```
client                              server (child)
  | WATCH interval=1 count=0 -----> |  take the first sample
  |                                 |  wait 1 s (and notice if the client leaves)
  | <----------- WATCH OK figures   |  sample, compute, send
  |                                 |  wait 1 s
  | <----------- WATCH OK figures   |
  | (Ctrl+C, connection closed)     |  sees the connection closed, exits
```

Signal handling: a signal handler only sets a flag, and the real work is done in the main loop. Functions such as `printf` are not safe to call inside a signal handler. Moving the work into the main loop means the parent can write a log line when it reaps a child, including which signal killed the child.

| Signal | What the parent does |
|---|---|
| `SIGCHLD` | Reaps every exited child in a `waitpid(-1, WNOHANG)` loop |
| `SIGINT`, `SIGTERM` | Stops accepting connections, tells every child to exit, waits for them and then leaves |
| `SIGUSR1` | Toggles debug output |
| `SIGPIPE` | Ignored; a failed write is reported by the return value of `send()` |

## 2.4 Two levels of debug logging

| Level | How it is controlled | Effect |
|---|---|---|
| Compile time | `make` versus `make DEBUG=1` | In a normal build `LOG_DEBUG()` produces no code, and the debug message strings are not in the executable |
| Runtime | The `-v` option, the environment variable `PMON_LOG=debug`, or `SIGUSR1` sent to the server | In a debug build, switches debug output on and off without recompiling or restarting |

Compile time decides whether the messages exist in the executable. Runtime decides whether they are printed now.

Every log line carries the time, the level, the program name and pid, and the source file and line number. The pid tells apart the output of several children. Each line is written with a single `write()`, so lines from different processes do not interleave.

```
2026-11-12 10:25:41.398 [DEBUG] pmond[57521] server/pmond.c:197: forked child 57529 for 127.0.0.1:47636, 1 active
```

## 2.5 Shared library

| Module | Content | Used by the server for | Used by the client for |
|---|---|---|---|
| `log` | The two-level control and the output format | Recording connections and errors | Debug output |
| `io` | Complete read and write with a timeout | Reading requests, sending responses | Sending requests, reading responses |
| `proto` | Sending, receiving and checking frames; CRC-32 | Same as above | Same as above |
| `kv` | Getting a value out of `key=value` text | Reading the `watch` parameters | Picking figures out of a response to print a table |

Both programs really use all four modules. The library is built with `-fPIC -shared`. The executables are linked with the rpath `$ORIGIN/../lib`, so at run time they look for the library in the `lib/` directory next to their own location, and `LD_LIBRARY_PATH` does not have to be set.

## 2.6 Where the performance figures come from

| Figure | Source | Calculation |
|---|---|---|
| CPU usage | `/proc/stat` | Share of non-idle time in the total time between two samples |
| Load and number of tasks | `/proc/loadavg` | Read directly |
| Memory, swap | `/proc/meminfo` | Total minus available |
| Disk usage | `statvfs("/")` | Used blocks as a share of usable blocks |
| Network receive and send rate | `/proc/net/dev` | Byte difference between two samples divided by the time, loopback excluded |

CPU and network figures are rates, so they need two samples. `stat` takes two samples 0.2 seconds apart; `watch` uses two consecutive pushes as the interval.

# 3. Key Source Code

## 3.1 The parent: accept and fork (`server/pmond.c`)

```c
pid = fork();
if (pid == 0) {
    /* Child: it owns the connection, not the listening socket. */
    signal(SIGCHLD, SIG_DFL);
    signal(SIGINT, SIG_DFL);
    signal(SIGTERM, SIG_DFL);
    close(listen_fd);
    session_run(fd, who, opts);
    _exit(0);
}
if (pid < 0) {
    LOG_ERROR("fork: %s", strerror(errno));
    proto_send(fd, 0, ST_BUSY, NULL, 0);
} else {
    remember_child(pid);
}
/* Parent: the child has its own copy of the connection. */
close(fd);
```

- After `fork()` both processes hold the listening socket and the connection socket. The child closes the listening socket and the parent closes the connection socket. If the parent did not, it would run out of file descriptors as connections accumulate, and a connection would not really close when its child exits.
- The child restores the default signal handling. It has no children of its own to reap, and `SIGTERM` should simply end it.
- The child calls `_exit()` and not `exit()`, so that buffers inherited from the parent are not flushed a second time.
- If `fork()` fails, the client gets a BUSY reply and the server keeps serving everyone else.

## 3.2 Reaping children (`server/pmond.c`)

```c
static void on_sigchld(int sig)
{
    (void)sig;
    g_child_exited = 1;
}

static void reap_children(void)
{
    pid_t pid;
    int status, i;

    g_child_exited = 0;
    while ((pid = waitpid(-1, &status, WNOHANG)) > 0) {
        /* remove the pid from the table */
        if (WIFSIGNALED(status))
            LOG_ERROR("child %d was killed by signal %d (%s), %d still active",
                      (int)pid, WTERMSIG(status), strsignal(WTERMSIG(status)),
                      g_nkids);
    }
}
```

- A loop is used, not a single `waitpid` call: when several children exit at almost the same moment, `SIGCHLD` may be delivered only once.
- `WNOHANG` makes `waitpid` return at once when no child has exited, so the main loop is never blocked.
- The `poll()` in the main loop has a one-second timeout. If a signal arrives just after the flag is checked and just before `poll()` is entered, it is still handled within one second.

## 3.3 Checking a received frame (`lib/proto.c`)

```c
if (validate) {
    if (get16(hdr) != PMON_MAGIC) {
        LOG_INFO("rejected frame: bad magic 0x%04x", (unsigned)get16(hdr));
        return PROTO_BAD;
    }
    if (n > PMON_MAX_PAYLOAD) {
        LOG_INFO("rejected frame: length %u exceeds limit %u",
                 (unsigned)n, (unsigned)PMON_MAX_PAYLOAD);
        return PROTO_BAD;
    }
}

body = malloc((size_t)n + 1);
```

The length in the header decides how much memory is allocated next and how much data the receiver waits for. It comes from the network and cannot be trusted before it is checked. The order is: check the magic and the length limit, then allocate memory, then read the payload and compare the CRC. Section 5.2 shows what happens without this check.

## 3.4 The `LOG_DEBUG` macro (`include/pmon.h`)

```c
#ifdef PMON_DEBUG
#define LOG_DEBUG(...) log_write(LOG_LVL_DEBUG, __FILE__, __LINE__, __VA_ARGS__)
#else
#define LOG_DEBUG(...) \
    do { if (0) log_write(LOG_LVL_DEBUG, __FILE__, __LINE__, __VA_ARGS__); } while (0)
#endif
```

- In a debug build (`-DPMON_DEBUG`) it is a real call to `log_write`, and the runtime switch decides whether anything is printed.
- In a normal build it is code that can never run. The compiler removes the call together with the format string, but still checks the argument types, and the variables still count as used, so the build does not fail under `-Werror`.
- `__FILE__` and `__LINE__` have to be written in the macro so that they give the file and line of the caller.

## 3.5 Reliable reading (`lib/io.c`)

```c
while (got < n) {
    struct pollfd pfd = { .fd = fd, .events = POLLIN };

    r = poll(&pfd, 1, timeout_ms);
    if (r < 0) {
        if (errno == EINTR)
            continue;
        return IO_ERR;
    }
    if (r == 0)
        return IO_TIMEOUT;

    k = read(fd, p + got, n - got);
    if (k < 0) {
        if (errno == EINTR || errno == EAGAIN)
            continue;
        return IO_ERR;
    }
    if (k == 0)
        return IO_EOF;
    got += (size_t)k;
}
```

- TCP is a byte stream and one `read()` may return only part of the data, so the loop reads until everything has arrived.
- `poll()` is called before `read()`. If the peer sends nothing, the function returns `IO_TIMEOUT` after the deadline and never blocks in `read()` forever.
- An interruption by a signal (`EINTR`) is retried and not treated as an error. The server receives `SIGUSR1`, so this is necessary.
- Timeout, peer closed and error have different return values, so the caller can log the real reason.

## 3.6 Makefile: building the shared library

```make
LDLIBS := -L$(BUILD)/lib -lpmon -Wl,-rpath,'$$ORIGIN/../lib'

$(BUILD)/obj/lib/%.o: lib/%.c
	$(CC) $(CFLAGS) -fPIC -MMD -MP -c $< -o $@

$(LIB): $(LIB_OBJ)
	$(CC) -shared -o $@ $^

$(SERVER): $(SERVER_OBJ) $(LIB)
	$(CC) -o $@ $(SERVER_OBJ) $(LDLIBS)
```

- The library's object files are compiled with `-fPIC`, which produces position-independent code that can be loaded at any address.
- `-shared` links the object files into `libpmon.so`.
- The executables are linked with `-lpmon`; the library code is not copied into them.
- `make DEBUG=1` adds `-DPMON_DEBUG -g -O0` and writes to a separate directory, `build-debug/`, so both builds can exist side by side and be compared.
- Every file is compiled with `-std=c11 -Wall -Wextra -Werror`, and there are currently no warnings.

## 3.7 The client's command table and option parsing (`client/pmon.c`)

```c
static const struct command {
    const char *name;
    int (*run)(const char *server, int argc, char **argv);
    const char *args;
    const char *help;
} commands[] = {
    { "sysinfo", cmd_sysinfo, "[--hold seconds]",        "facts about the server machine" },
    { "stat",    cmd_stat,    "",                         "current CPU, memory, disk, network" },
    { "watch",   cmd_watch,   "[-i seconds] [-n count]",  "keep showing them (Ctrl+C to stop)" },
};
```

- All commands are declared in one table. Each row has a name, the function that runs it (a function pointer) and its help text. `main()` looks the command up and calls it, and `usage()` prints the help from the same table. Adding a command means adding one row.
- Options are parsed at two levels. `main()` uses `getopt(argc, argv, "+s:vh")` for the global options before the command name; the leading `+` makes it stop at the command name. It then moves `argv` to the command name, resets `optind`, and lets the command parse the rest with its own option string. So `-i 2`, `-i2` and options in any order are all accepted, the same as other tools on the system.

```c
static int parse_int(const char *text, const char *what, int min, int max, int *out)
{
    char *end;
    long v;

    errno = 0;
    v = strtol(text, &end, 10);
    if (end == text || *end != '\0' || errno != 0 || v < min || v > max) {
        fprintf(stderr, "pmon: %s must be a number from %d to %d, not '%s'\n",
                what, min, max, text);
        return -1;
    }
    *out = (int)v;
    return 0;
}
```

- Option values are converted with `strtol`, not `atoi`. `atoi("abc")` returns 0 and `atoi("5x")` returns 5, both without reporting an error. `strtol` makes it possible to check that the whole string is a number (`*end` must be the end of the string) and that it did not overflow (`errno`).
- An invalid value produces a message that names the option, the allowed range and what was received, for example `pmon: -i must be a number from 1 to 60, not '5x'`.

# 4. Execution Results

The sections below are screenshots of the matching scripts in the `demo/` directory. Each script starts and stops the server by itself. The screenshots were taken on `nsp-server` by running each script in the terminal program xterm, and are produced by `docs/report/screenshots.sh`. The same output is kept as text in `docs/output/`.

## 4.1 Basic function: the client requests system information

`demo/01-basic.sh`

@image ../screenshots/01-basic.png

## 4.2 fork and 10 concurrent clients

`demo/02-ten-clients.sh` starts 10 clients on the same host, each running `watch` for 6 seconds. Three pieces of evidence agree with each other:

- Process tree: 1 parent with 10 children under it.
- TCP connections: 10 established connections on port 9419.
- Each client reports a different server pid, and these match the 10 children in the process tree.

@image ../screenshots/02-ten-clients.png

`demo/02-ten-clients.sh remote` starts 5 clients on each of the two client hosts instead. The server sees connections from two different addresses, 5 from each.

@image ../screenshots/02-ten-clients-remote.png

## 4.3 Two levels of debug log control

`demo/04-debug-log.sh`

- Compile time: the same debug message appears 0 times in the normal executable and once in the debug executable. The normal build prints no debug output even with `-v`.
- Runtime: the debug build prints no debug output by default. After `SIGUSR1` is sent to the running server it starts printing, and a second `SIGUSR1` stops it.

@image ../screenshots/04-debug-log.png

## 4.4 Shared dynamic library

`demo/05-shared-lib.sh`

- The dynamic section of both executables records that `libpmon.so` is needed, with the search path `$ORIGIN/../lib`.
- `proto_send` is an undefined symbol in both executables and is resolved from the library at run time.
- With the library moved away, the program cannot start.
- The library has the same hash on the server and on the two client hosts: it is the same file.

@image ../screenshots/05-shared-lib.png

## 4.5 Automatic check of every requirement

`demo/verify.sh` does not use the demo scripts above. It rebuilds both variants, starts the server by itself, checks every requirement in turn and prints PASS or FAIL. The complete output follows; all 54 checks pass.

@include docs/output/verify.txt

# 5. Robustness Mechanisms

Each of the four mechanisms has an option that turns it off. Every script runs once with the mechanism off and once with it on, with everything else identical. The options exist only for demonstration, and the server logs a warning at start-up when one is used.

| No. | Abnormal situation | Mechanism | Option to turn it off |
|---|---|---|---|
| R1 | A child exits | `SIGCHLD` and a `waitpid` loop | `--no-reap` |
| R2 | Data that is not this protocol arrives | Check the magic, the length limit and the CRC | `--no-validate` |
| R3 | A client connects and sends nothing | Read timeout | `--no-timeout` |
| R4 | The client is killed in the middle of `watch` | Notice a closed connection while waiting; ignore `SIGPIPE` and let `send()` return `EPIPE` | `--no-sigpipe` |

## 5.1 R1: reaping exited children

`demo/r1-zombie.sh` runs `pmon stat` five times in a row and then looks at the server's children.

- Without the mechanism: all 5 children stay in state `Z` (zombie). They have exited, but their process table entries are not released. A long-running server would eventually hit the process limit.
- With the mechanism: nothing is left behind.

@image ../screenshots/r1-zombie.png

## 5.2 R2: rejecting data that is not the protocol

`demo/r2-validate.sh` sends an HTTP request to the server's port with `curl`.

- Without the mechanism: the child treats the first 12 bytes of `GET / HTTP/1.1` as a header. Bytes 4 to 7, `/ HT`, are read as the length `0x2f204854`, about 754 MiB. The child allocates that much memory (756 MB in the output) and waits for data that will never come; `curl` waits until it times out. Anyone can make the server hold a large amount of memory by sending 12 bytes.
- With the mechanism: the child sees that the magic is not `PM`, replies BAD_REQUEST at once and disconnects, without allocating any memory.

@image ../screenshots/r2-validate.png

## 5.3 R3: a client that sends nothing

`demo/r3-timeout.sh` connects to the server with `nc` and sends nothing.

- Without the mechanism: the child is still there after 5 seconds. Every such connection occupies a child forever, and once the connection limit is reached nobody else can connect.
- With the mechanism: after 3 seconds the child logs the timeout and exits. (The demo uses 3 seconds; the default is 10.)

@image ../screenshots/r3-timeout.png

## 5.4 R4: a client that disappears

`demo/r4-sigpipe.sh` kills the client with `kill -9` in the middle of `pmon watch`.

- Without the mechanism: the child keeps writing to the closed connection and is killed by the kernel with `SIGPIPE`. The parent's log records `killed by signal 13 (Broken pipe)`. The child has no chance to clean up.
- With the mechanism: while waiting for the next sample the child notices that the connection is closed, logs it and exits normally.

@image ../screenshots/r4-sigpipe.png

## 5.5 Other mechanisms in the code

These have no option to turn them off, but are also implemented:

- Reads and writes loop to handle short reads, short writes and `EINTR` (section 3.5).
- A connection limit, with a BUSY reply beyond it. A failed `fork()` also gets a BUSY reply and does not end the server.
- When invalid data is rejected, the server sends the error reply and drains what the peer has already sent before closing. Closing directly makes the kernel send a reset, and the peer never sees the reply. This problem was met during testing and then fixed.
- Parameter checks: the client validates option values with `strtol` (section 3.7), and the server checks the range of the `watch` parameters again and does not trust the client.
- `SO_REUSEADDR`, so the server can be restarted without waiting.
- A connect timeout (5 seconds) and a response timeout (15 seconds) in the client.
- On `SIGINT` or `SIGTERM` the parent tells every child to exit and waits for them, leaving no orphan processes.

# 6. Packet Capture and Analysis

`demo/03-capture.sh` captures one complete `pmon stat` connection with `tcpdump`. One capture was taken on loopback and one between two machines (`nsp-client-1` to `nsp-server`); the `.pcap` files are in `docs/capture/`. Sections 6.1 to 6.3 explain the loopback capture using the `tcpdump` output, and section 6.5 views the cross-machine capture in Wireshark.

## 6.1 The whole connection: 10 packets

The client's port is 58396 and the server's is 9419.

| # | Time | Direction | Flags | Data length | Meaning |
|---|---|---|---|---|---|
| 1 | .683795 | client → server | `S` | 0 | Three-way handshake: SYN |
| 2 | .683806 | server → client | `S.` | 0 | Three-way handshake: SYN + ACK |
| 3 | .683816 | client → server | `.` | 0 | Three-way handshake: ACK, connection established |
| 4 | .683841 | client → server | `P.` | 12 | Request frame (header only) |
| 5 | .683845 | server → client | `.` | 0 | Acknowledges the request |
| 6 | .884327 | server → client | `P.` | 195 | Response frame (12-byte header + 183-byte payload) |
| 7 | .884335 | client → server | `.` | 0 | Acknowledges the response |
| 8 | .884371 | client → server | `F.` | 0 | The client closes: FIN |
| 9 | .884475 | server → client | `F.` | 0 | The server closes too: FIN |
| 10 | .884485 | client → server | `.` | 0 | Acknowledgement, connection finished |

- Packets 4 and 6 are 0.2 seconds apart. That is the interval between the two samples the server takes to compute CPU usage, not network delay.
- The request and the response each take a single TCP packet, because `proto_send()` puts the header and the payload into one buffer and sends them together.
- The client sends FIN first. The server child reads EOF, exits, and sends its own FIN.
- The sequence numbers match the data lengths: the request is `seq 1:13` and the response is `seq 1:196`.

## 6.2 The request frame

The TCP data of packet 4 is 12 bytes:

```
504d 0200 0000 0000 0000 0000
```

| Bytes | Value | Field | Reading |
|---|---|---|---|
| 0–1 | `50 4d` | magic | ASCII `PM` |
| 2 | `02` | opcode | 2 = STAT |
| 3 | `00` | status | Always 0 in a request |
| 4–7 | `00 00 00 00` | length | Payload length 0 |
| 8–11 | `00 00 00 00` | crc32 | The CRC-32 of an empty payload is 0 |

## 6.3 The response frame

The TCP data of packet 6 is 195 bytes. This is the output of `tcpdump -X`:

```
0x0030:  9b56 241c 504d 0200 0000 00b7 1165 f848  .V$.PM.......e.H
0x0040:  7469 6d65 3d31 303a 3236 3a30 340a 6370  time=10:26:04.cp
0x0050:  755f 7063 743d 322e 350a 6c6f 6164 313d  u_pct=2.5.load1=
0x0060:  302e 3033 0a74 6173 6b73 3d31 3837 0a6d  0.03.tasks=187.m
0x0070:  656d 5f74 6f74 616c 5f6d 623d 3339 3135  em_total_mb=3915
```

| Bytes | Value | Field | Reading |
|---|---|---|---|
| 0–1 | `50 4d` | magic | `PM` |
| 2 | `02` | opcode | 2 = STAT, same as the request |
| 3 | `00` | status | 0 = OK |
| 4–7 | `00 00 00 b7` | length | 0xb7 = 183 bytes |
| 8–11 | `11 65 f8 48` | crc32 | CRC-32 of the payload |
| 12 onward | `74 69 6d 65 3d ...` | payload | Text lines such as `time=10:26:04` and `cpu_pct=2.5` |

- The length 183 is written as `00 00 00 b7`, most significant byte first, which is network byte order. The program builds it byte by byte with `put32()` and `get32()` and does not depend on the machine's byte order.
- The TCP data length of 195 equals the 12-byte header plus the 183-byte payload, in agreement with the length field.
- The payload is plain text and can be read directly on the right side of the output.

## 6.4 Differences in the cross-machine capture

| Item | Loopback | Cross-machine |
|---|---|---|
| Addresses | 127.0.0.1 → 127.0.0.1 | 10.77.0.21 → 10.77.0.10 |
| MSS | 65495 | 1410 |
| Gap between packets 6 and 7 | 0.008 ms | 0.8 ms |

The 12-byte application header and the payload format are exactly the same.

## 6.5 Viewing the cross-machine capture in Wireshark

The cross-machine capture `docs/capture/stat-ens4.pcap` is opened in Wireshark. The purpose is to show that the frames the programs put on the wire are correct, and to have a picture that can be used to explain them. Wireshark does not know a custom protocol and by default shows the frame only as TCP data. A Lua dissector, `docs/capture/pmon.lua`, tells Wireshark what each of the first 12 bytes on port 9419 means.

The dissector also checks every frame. It compares the length field with the number of payload bytes that actually follow, and it computes the CRC-32 of the payload with its own code, written separately from `lib/proto.c`, and compares it with the CRC field. The result is shown next to each field as `[correct]` or `[incorrect, should be ...]`.

```
wireshark -X lua_script:docs/capture/pmon.lua docs/capture/stat-ens4.pcap
```

Packet 4, the request from the client (10.77.0.21) to the server (10.77.0.10):

@image ../screenshots/wireshark-request.png

Packet 6, the server's response:

@image ../screenshots/wireshark-reply.png

- The packet list at the top matches the table in 6.1: the three-way handshake, the request, the response and one FIN from each side, 10 packets in total. Packets 4 and 6 show PMON in the Protocol column, and the Info column is the summary produced by the dissector.
- The lower left pane is the dissected frame. The request has payload length 0 and CRC 0. The response has payload length 183 and CRC `0x1a0a7d18`, and the payload is `key=value` text.
- Both frames are marked `[correct]` for the length and for the CRC-32, and the Info column ends with "CRC correct". Wireshark reached the same CRC as the server by a separate computation, so the header the server built is right.
- As a control, one payload byte of a copy of the capture was changed. The dissector then reported `[incorrect, should be 0xbae3cb5b]` for that frame, so the check does fail when a frame is wrong.
- The highlighted bytes in the lower right pane are the pmon frame. The bytes before it are the Ethernet, IP and TCP headers. The response frame starts at offset `0x42`, and its first two bytes are `50 4d`.
- Packets 4 and 6 are 0.2006 seconds apart, again the interval between the server's two samples.

# 7. Auditing and Security

## 7.1 The server log as an audit record

Every connection leaves these records in the server log. They are at INFO level and are printed by every build:

| Event | What is recorded |
|---|---|
| Connection opened | Time, pid of the child, address and port of the client |
| `watch` started | The interval in seconds |
| Connection closed | Number of requests handled; number of samples `watch` sent; the reason (normal disconnect, timeout, client gone) |
| Connection refused | The reason (connection limit reached, or an invalid frame and its details) |
| Child ended abnormally | Its pid and the name of the signal |

The log answers who connected and when, how long they watched, and whether anyone sent data that was not the protocol. The last part of the output in section 4.1 is one complete record.

## 7.2 Known limitations

- **No authentication**: anyone who can reach port 9419 can query. The only identity the log can record is the source address.
- **The payload is plain text**: the capture in section 6 shows that anyone on the path can read the host's load and memory information.
- **CRC-32 only detects transmission errors**: an attacker who changes the payload can recompute the CRC, so it does not protect against tampering.
- **The log goes to standard error**: whoever starts the server decides where it is redirected, and the program has no rotation or tamper protection of its own.

The current protection is to deploy the system on an isolated test network with no outside access. Authentication and encryption belong to the Security item of the final project.

## 7.3 Risk of the demonstration options

The four options in section 5 put the server in an unsafe state and are for demonstration only. Whenever any of them is used, the server logs `UNSAFE demonstration mode` and the names of the mechanisms that are off when it starts.

# 8. Building and Running

```
make            # normal build -> build/
make DEBUG=1    # debug build -> build-debug/
make deploy     # copy the client and libpmon.so to the client hosts
make dist       # pack the source into pmon-source.zip
make clean

build/bin/pmond                       # start the server
build/bin/pmon sysinfo                # query
build/bin/pmon -s nsp-server watch    # keep watching another host

demo/run-all.sh pause                 # run every demo in order
demo/verify.sh                        # check every requirement
```

| Script | Requirement shown |
|---|---|
| `demo/01-basic.sh` | System information |
| `demo/02-ten-clients.sh [remote]` | fork, 10 concurrent clients |
| `demo/03-capture.sh [interface remote]` | Packet capture |
| `demo/04-debug-log.sh` | Two levels of debug logging |
| `demo/05-shared-lib.sh` | Shared dynamic library |
| `demo/r1-zombie.sh` to `demo/r4-sigpipe.sh` | Four robustness comparisons |
| `demo/verify.sh` | Checks every requirement and prints PASS or FAIL |

# Appendix: Complete Source Code

The complete source code is handed in together with this report as the archive `pmon-source.zip`. It is produced by `make dist` from the version-controlled files, so it holds exactly the code that produced the results in this report. To build it:

```
unzip pmon-source.zip
cd pmon
make
```

The files in the archive:

| File | Content |
|---|---|
| `Makefile` | Builds the library and both programs; `DEBUG=1`, `deploy`, `dist`, `clean` |
| `include/pmon.h` | Interface of the shared library: frame format, opcodes, log macros |
| `lib/log.c` | Two-level logging |
| `lib/io.c` | Complete read and write with a timeout |
| `lib/proto.c` | Sending, receiving and checking frames; CRC-32 |
| `lib/kv.c` | `key=value` text handling |
| `server/server.h` | Declarations shared by the server's files |
| `server/pmond.c` | The parent: options, signals, accept, fork, reaping children |
| `server/session.c` | The child: the request loop for one connection |
| `server/sysinfo.c` | Static facts about the host |
| `server/metrics.c` | Performance figures from `/proc` |
| `client/pmon.c` | The client: command table, option parsing, output |
| `demo/common.sh` | Helpers shared by the demo scripts |
| `demo/01-basic.sh` | Demo: system information |
| `demo/02-ten-clients.sh` | Demo: fork and 10 concurrent clients |
| `demo/03-capture.sh` | Demo: packet capture |
| `demo/04-debug-log.sh` | Demo: two levels of debug logging |
| `demo/05-shared-lib.sh` | Demo: shared dynamic library |
| `demo/r1-zombie.sh` | Robustness R1, with and without |
| `demo/r2-validate.sh` | Robustness R2, with and without |
| `demo/r3-timeout.sh` | Robustness R3, with and without |
| `demo/r4-sigpipe.sh` | Robustness R4, with and without |
| `demo/run-all.sh` | Runs every demo in order |
| `demo/verify.sh` | Checks every requirement and prints PASS or FAIL |
| `docs/capture/pmon.lua` | Wireshark dissector for the pmon frame |
| `docs/capture/*.pcap`, `*.txt` | The two packet captures and their `tcpdump` output |
| `docs/` | Design notes, packet analysis, screenshots, and the source of this report |
