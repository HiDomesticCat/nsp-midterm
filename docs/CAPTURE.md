# Packet Capture and Analysis

One complete `pmon stat` connection, captured with `tcpdump`.

| File | Environment | Produced by |
|---|---|---|
| `capture/stat-lo.pcap`, `.txt` | Single machine, loopback | `demo/03-capture.sh` |
| `capture/stat-ens4.pcap`, `.txt` | Two machines: `nsp-client-1` (10.77.0.21) → `nsp-server` (10.77.0.10) | `demo/03-capture.sh ens4 remote` |

The `.pcap` files open directly in Wireshark. The loopback capture is used as the example below; the cross-machine capture has exactly the same structure.

## 1. The whole connection: 10 packets

The client's port is 58396 and the server's is 9419.

| # | Time | Direction | Flags | Data length | Meaning |
|---|---|---|---|---|---|
| 1 | .683795 | client → server | `S` | 0 | Three-way handshake: SYN |
| 2 | .683806 | server → client | `S.` | 0 | Three-way handshake: SYN + ACK |
| 3 | .683816 | client → server | `.` | 0 | Three-way handshake: ACK, connection established |
| 4 | .683841 | client → server | `P.` | 12 | **Request frame** (header only) |
| 5 | .683845 | server → client | `.` | 0 | Acknowledges the request |
| 6 | .884327 | server → client | `P.` | 195 | **Response frame** (12-byte header + 183-byte payload) |
| 7 | .884335 | client → server | `.` | 0 | Acknowledges the response |
| 8 | .884371 | client → server | `F.` | 0 | The client closes: FIN |
| 9 | .884475 | server → client | `F.` | 0 | The server closes too: FIN |
| 10 | .884485 | client → server | `.` | 0 | Acknowledgement, connection finished |

What can be observed:

- **Packets 4 and 6 are 0.2 seconds apart.** That is the interval between the two samples the server takes to compute CPU usage and network rates (`STAT_WINDOW_MS`), not network delay.
- **The request and the response each take a single TCP packet.** `proto_send()` puts the header and the payload into one buffer and sends them together, so they are not split in two.
- **The client sends FIN first.** The client closes its socket after it has the response. The server child reads EOF, logs "disconnected" and exits, which sends its own FIN.
- **The sequence numbers match the data lengths.** The request is `seq 1:13` (12 bytes), the response is `seq 1:196` (195 bytes), and each FIN takes one sequence number.

## 2. The request frame: 12 bytes

The TCP data of packet 4 (after the 20-byte IP header and the 32-byte TCP header):

```
504d 0200 0000 0000 0000 0000
```

| Bytes | Value | Field | Reading |
|---|---|---|---|
| 0–1 | `50 4d` | magic | ASCII `PM`, marks the pmon protocol |
| 2 | `02` | opcode | 2 = STAT |
| 3 | `00` | status | Always 0 in a request |
| 4–7 | `00 00 00 00` | length | Payload length 0; STAT has no parameters |
| 8–11 | `00 00 00 00` | crc32 | The CRC-32 of an empty payload is 0 |

## 3. The response frame: 12 + 183 bytes

The start of the TCP data of packet 6:

```
504d 0200 0000 00b7 1165 f848 7469 6d65 3d31 303a ...
                              t i  m e  = 1  0 :
```

| Bytes | Value | Field | Reading |
|---|---|---|---|
| 0–1 | `50 4d` | magic | `PM` |
| 2 | `02` | opcode | 2 = STAT, same as the request |
| 3 | `00` | status | 0 = OK |
| 4–7 | `00 00 00 b7` | length | 0xb7 = 183 bytes |
| 8–11 | `11 65 f8 48` | crc32 | CRC-32 of the payload |
| 12– | `74 69 6d 65 3d ...` | payload | `time=10:26:04\ncpu_pct=2.5\n...` |

Multi-byte fields are in network byte order (most significant byte first): the length 183 is written as `00 00 00 b7`, not as `b7 00 00 00` the way x86 keeps it in memory.
The program builds them byte by byte with `put32()` and `get32()` and does not depend on the machine's byte order.

The TCP data length of 195 = 12-byte header + 183-byte payload, in agreement with the length field.

The payload is lines of `key=value` text and can be read directly on the right side of the capture:

```
time=10:26:04.cpu_pct=2.5.load1=0.03.tasks=187.mem_total_mb=3915.mem_used_mb=549...
```

(`.` is the newline character 0x0a; `tcpdump` shows non-printable characters as a period.)

## 4. Differences in the cross-machine capture

`capture/stat-ens4.txt` differs from the loopback capture only at the network layer:

| Item | Loopback | Cross-machine |
|---|---|---|
| Addresses | 127.0.0.1 → 127.0.0.1 | 10.77.0.21 → 10.77.0.10 |
| MSS | 65495 | 1410 (the physical network's MTU minus the VXLAN encapsulation and headers) |
| Gap between packets 6 and 7 | 0.008 ms | 0.8 ms (it really crosses a network) |

The 12-byte application header and the payload format are exactly the same.

## 5. Security problems visible in the capture

- **The payload is plain text.** Anyone who can capture packets on the path can read the host's CPU, memory and task figures.
- **There is no authentication.** Anyone who can reach port 9419 can query.
- **CRC-32 only detects transmission errors, not tampering.** An attacker who changes the payload can recompute the CRC.

These three points are known limitations of the midterm. The Security item of the final project (encryption, authentication) addresses them.
The current protection is to deploy on an isolated test network with no outside access.

## Viewing the cross-machine capture in Wireshark

Wireshark does not know a custom protocol and by default shows the frame only as TCP data. `docs/capture/pmon.lua` is a Lua dissector that tells Wireshark what each of the first 12 bytes on port 9419 means.

```
wireshark -X lua_script:docs/capture/pmon.lua docs/capture/stat-ens4.pcap
tshark    -X lua_script:docs/capture/pmon.lua -r docs/capture/stat-ens4.pcap -Y pmon -O pmon
```

Packet 4, the request from the client (10.77.0.21) to the server (10.77.0.10):

![Wireshark: request frame](screenshots/wireshark-request.png)

Packet 6, the server's response:

![Wireshark: response frame](screenshots/wireshark-reply.png)

- Packets 4 and 6 show PMON in the Protocol column, and the Info column is the summary produced by the dissector.
- The lower left pane is the dissected frame: the request has payload length 0 and CRC 0; the response has payload length 183 and CRC `0x1a0a7d18`.
- The dissector checks every frame: the length field against the payload bytes that follow, and the CRC field against a CRC-32 it computes with its own code. Both frames are marked `[correct]`. With one payload byte changed in a copy of the capture, it reports `[incorrect, should be 0xbae3cb5b]`.
- The highlighted bytes in the lower right pane are the pmon frame. The bytes before it are the Ethernet, IP and TCP headers.

The pictures are taken by `docs/report/wireshark-shot.sh`, which opens Wireshark on a virtual display.
