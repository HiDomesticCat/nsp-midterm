# pmon 系統設計

Network and System Programming 期中作業。`pmon` 是一個遠端效能監控系統：
server 跑在被監控的主機上，多個 client 同時連線查詢它的系統資訊與即時效能數據。

設計原則：每一項都對應題目的一個要求，並且能在 demo 時用一兩個指令展示出來。

| 元件 | 檔名 | 角色 |
|---|---|---|
| Server | `pmond` | 每個連線 `fork()` 一個 child，從 `/proc` 讀取效能數據 |
| Client | `pmon` | 命令列工具 |
| 共用函式庫 | `libpmon.so` | log、可靠讀寫、協定、`key=value` 文字處理 |

## 1. 題目要求與展示方式

| 題目要求 | 做法 | demo 時怎麼看 | 狀態 |
|---|---|---|---|
| 每個連線 `fork()`，不用 thread | parent 只 accept 與 fork，child 服務一個連線 | client 會印出服務它的 child pid，每個 client 都不同 | 完成 |
| 至少 10 個 client 同時連線，附執行期證明 | 10 個 client 同時 `watch` | `ps --forest` 看到 1 個 parent 加 10 個 child，`ss -tn` 看到 10 條連線 | 完成，待寫成 demo 腳本 |
| 封包擷取與分析 | 自訂 12 位元組標頭的二進位協定 | `tcpdump -X` 的輸出逐欄對照標頭格式 | 待做 |
| 編譯期與執行期兩層 debug log | 編譯期巨集、執行期參數與訊號 | 兩種建置的 `strings` 結果不同；對執行中的 server 送訊號，log 立刻變多 | 完成 |
| 共用函式包成 `.so` | `libpmon.so` 給兩邊連結 | `ldd` 兩個執行檔；server 與 client VM 上的函式庫 `sha256sum` 相同 | 完成 |
| client 向 server 要系統資訊 | `pmon sysinfo`、`pmon stat`、`pmon watch` | 直接執行 | 完成 |
| 強健性，至少三組有與沒有的對照 | 四個機制各有一個關閉參數 | 同一支腳本開與關各跑一次 | 機制完成，關閉參數待做 |
| Makefile 或 CMake | 手寫 Makefile | `make` | 完成 |

## 2. 功能

| 指令 | 作用 |
|---|---|
| `pmon sysinfo` | 主機的靜態資訊：主機名稱、核心版本、CPU 數量、開機時間、記憶體與磁碟總量 |
| `pmon stat` | 目前的效能數據，取樣一次 |
| `pmon watch [-i 秒] [-n 次數]` | 每隔一段時間顯示一列效能數據，直到按 Ctrl+C 或達到次數 |

效能數據：

| 項目 | 來源 | 算法 |
|---|---|---|
| CPU 使用率 | `/proc/stat` | 兩次取樣之間，非閒置時間佔全部時間的比例 |
| 負載與行程數 | `/proc/loadavg` | 直接讀取 |
| 記憶體、swap | `/proc/meminfo` | 總量減去可用量 |
| 磁碟使用率 | `statvfs("/")` | 已用區塊佔可用區塊的比例 |
| 網路收送速率 | `/proc/net/dev` | 兩次取樣之間的位元組差除以時間，不含 loopback |

CPU 與網路是變化率，需要兩次取樣。`stat` 會間隔 0.2 秒取兩次；`watch` 用相鄰兩次推送當作區間。

`watch` 的輸出：

```
server pid 8020, every 1 s
time       cpu%  load1   mem%    mem MB   disk%   rx kB/s   tx kB/s  tasks
14:14:43    0.5   0.17   14.2       554    17.4       0.1       0.0    204
14:14:44    0.0   0.17   14.2       554    17.4       0.4       0.5    204
```

`watch` 是長時間的連線，所以多個人同時監看同一台主機時，server 上會同時有多個 child。
這是 10 個 client 同時連線的自然情境。

## 3. 通訊協定

TCP，預設埠 9419，多位元組欄位為 network byte order。請求與回應使用同一種訊框。

| 位移 | 長度 | 欄位 | 說明 |
|---|---|---|---|
| 0 | 2 | magic | 固定 `0x504D`（ASCII `PM`） |
| 2 | 1 | opcode | 操作碼 |
| 3 | 1 | status | 回應的結果碼，請求中為 0 |
| 4 | 4 | length | payload 位元組數，上限 64 KiB |
| 8 | 4 | crc32 | payload 的 CRC-32 |

payload 是 `key=value` 的文字行，在 `tcpdump -A` 裡可以直接閱讀。

| 操作碼 | 名稱 | 請求內容 | 回應內容 |
|---|---|---|---|
| 1 | SYSINFO | 無 | 主機的靜態資訊 |
| 2 | STAT | 無 | 一次效能數據 |
| 3 | WATCH | `interval`（1–60 秒）、`count`（0 表示不限） | 每隔 interval 推送一個訊框，內容同 STAT |

| 結果碼 | 意義 |
|---|---|
| 0 OK | 成功 |
| 1 BAD_REQUEST | 訊框格式錯誤、未知的操作碼、參數超出範圍 |
| 2 BUSY | 連線數已達上限 |
| 3 INTERNAL | server 內部錯誤 |

`watch` 的流程：

```
client                              server (child)
  | WATCH interval=1 count=0 -----> |  取第一次樣本
  |                                 |  等 1 秒（同時留意 client 是否離開）
  | <------------- WATCH OK 數據    |  取樣、計算、送出
  |                                 |  等 1 秒
  | <------------- WATCH OK 數據    |
  | （Ctrl+C，連線關閉）             |  發現連線關閉，結束
```

## 4. Server 行程模型

```
pmond (parent)   socket → bind → listen → 主迴圈
  ├─ child  ← client A
  ├─ child  ← client B
  └─ ...
```

- **parent 的主迴圈**：用 `poll()` 等待新連線。有連線就 `accept()` 再 `fork()`，
  自己關掉連線的 socket 繼續等下一個。child 數量超過上限（預設 64）就回 BUSY 並關閉。
- **child**：關掉 listen socket，重複「讀一個訊框 → 處理 → 回應」直到 client 斷線，然後結束。
- **訊號處理函式只設定旗標**，實際的工作在主迴圈做。這樣主迴圈裡可以安心使用 log 等不能在訊號處理函式中呼叫的函式。
  - `SIGCHLD`：主迴圈用 `waitpid(-1, WNOHANG)` 迴圈回收結束的 child。child 若是被訊號殺掉，會記錄是哪個訊號。
  - `SIGINT` / `SIGTERM`：主迴圈結束，通知所有 child 結束後再離開。
  - `SIGUSR1`：切換 debug 輸出。

## 5. 兩層 debug log

| 層 | 怎麼控制 | 效果 |
|---|---|---|
| 編譯期 | `make` 與 `make DEBUG=1` | 一般建置中 `LOG_DEBUG()` 不產生任何程式碼，除錯訊息的字串不在執行檔裡 |
| 執行期 | `-v` 參數、環境變數 `PMON_LOG=debug`、對 server 送 `SIGUSR1` | 在除錯建置中切換是否輸出 debug 訊息，不必重啟 |

log 的每一行有時間、等級、程式名稱與 pid、原始檔與行號。pid 讓多個 child 的輸出可以分辨。
每行用單一 `write()` 輸出，多個行程同時寫不會交錯。

```
2026-11-06 14:14:09.759 [DEBUG] pmond[7845] lib/proto.c:72: send frame op=STAT status=OK len=182
```

展示方式：

- 編譯期：`strings` 兩種建置的執行檔找同一句除錯訊息，一般建置找不到，除錯建置找得到。
- 執行期：server 執行中 `pkill -USR1 pmond`，下一個請求開始出現 debug 訊息；再送一次關閉。

## 6. 強健性

四個機制各有一個關閉參數，用來展示有與沒有的差別。

| 編號 | 異常狀況 | 機制 | 關閉參數 | 怎麼觸發 | 關閉時看到什麼 | 開啟時看到什麼 |
|---|---|---|---|---|---|---|
| R1 | child 結束 | `SIGCHLD` + `waitpid` | `--no-reap` | 連續執行幾次 `pmon stat` | `ps` 裡 `<defunct>` 越來越多 | 沒有殭屍行程 |
| R2 | 不是本協定的資料 | 檢查 magic、length 上限、CRC | `--no-validate` | `curl http://server:9419/` | child 把 HTTP 文字當成標頭，配置大量記憶體並等待一個巨大的 payload | 立刻回 BAD_REQUEST 並斷線 |
| R3 | client 連上後不送資料 | 讀取逾時 10 秒 | `--no-timeout` | `nc server 9419` 後放著 | child 一直存在 | 逾時後 child 記錄並結束 |
| R4 | `watch` 途中 client 被強制結束 | 忽略 `SIGPIPE`，由 `send()` 回傳 `EPIPE` | `--no-sigpipe` | `watch` 途中 `kill -9` client | parent 記錄 child 被 `SIGPIPE` 殺掉 | child 記錄 client 已離開並正常結束 |

不設關閉參數但同樣有做的：

- 讀寫都用迴圈處理短讀、短寫與 `EINTR`。
- 連線數上限，超過時回 BUSY；`fork()` 失敗時同樣回 BUSY，server 不會結束。
- 拒絕非法資料時先送出錯誤回覆、讀掉對方已送來的資料再關閉。直接關閉會讓核心送出重置，對方收不到回覆。
- `watch` 的參數範圍檢查。
- `SO_REUSEADDR`，server 重啟不必等待。
- client 的連線逾時與回應逾時。

## 7. 共用函式庫 `libpmon.so`

| 模組 | 內容 | server 怎麼用 | client 怎麼用 |
|---|---|---|---|
| `log` | 第 5 節的兩層控制與輸出格式 | 記錄連線與錯誤 | 除錯輸出 |
| `io` | 帶逾時的完整讀寫 | 讀請求、送回應 | 送請求、讀回應 |
| `proto` | 訊框的收送與檢查、CRC-32 | 同上 | 同上 |
| `kv` | 從 `key=value` 文字取值 | 讀 `watch` 的參數 | 從回應取出各項數據排成表格 |

以 `-fPIC -shared` 建置。執行檔連結時加上 rpath `$ORIGIN/../lib`，
會到自己所在位置旁邊的 `lib/` 找函式庫，不必設定 `LD_LIBRARY_PATH`。

## 8. 建置、部署與目錄

| 指令 | 內容 |
|---|---|
| `make` | 一般建置，輸出到 `build/` |
| `make DEBUG=1` | 除錯建置：保留 debug log，加 `-g`，輸出到 `build-debug/` |
| `make deploy` | 把 client 執行檔與 `libpmon.so` 複製到兩台 client VM 的 `~/pmon/` |
| `make clean` | 清除產物 |

開發流程：

- 原始碼只放在 `nsp-server`，在這台編譯。兩台 client VM 沒有編譯器。
- `make deploy` 把 `pmon` 和 server 正在使用的同一個 `libpmon.so` 送到 client VM。
- 測試時 server 跑在 `nsp-server`，client 從兩台 client VM 透過測試網段連線：
  `~/pmon/bin/pmon -s nsp-server watch`。
- 版本控制：git，一個功能或一個修正一個 commit，訊息說明為什麼。`build/` 與 `build-debug/` 不進版控。

```
nsp-midterm/
  Makefile
  include/pmon.h    函式庫的標頭
  lib/              libpmon.so：log.c io.c proto.c kv.c
  server/           pmond：pmond.c session.c sysinfo.c metrics.c
  client/           pmon：pmon.c
  demo/             每個展示項目一支腳本（待做）
  infra/            OpenStack 環境
  docs/             設計文件、報告
```

## 9. Demo 腳本（待做）

每支腳本只做一件事，輸出就是要放進報告的截圖。

| 腳本 | 展示 |
|---|---|
| `demo/01-basic.sh` | sysinfo、stat、watch 的正常流程 |
| `demo/02-ten-clients.sh` | 10 個 client 同時 `watch`，印出 `ps --forest` 與 `ss -tn` |
| `demo/03-capture.sh` | 執行一次 stat 並用 `tcpdump -X` 擷取 |
| `demo/04-debug-log.sh` | 編譯期與執行期兩層 log 控制 |
| `demo/05-shared-lib.sh` | `ldd` 與 `sha256sum` |
| `demo/r1-zombie.sh` 到 `demo/r4-sigpipe.sh` | 四組強健性，各自開與關跑一次 |

測試環境：

- 單機：`nsp-server` 上用 loopback，`tcpdump -i lo`。
- 跨機：server 在 `nsp-server`，兩台 client VM 各跑 5 個 client，在測試網段上擷取後用 Wireshark 開啟。

## 10. 進度

| 階段 | 內容 | 狀態 |
|---|---|---|
| 1 | Makefile、`libpmon.so`、log、協定、fork server、`sysinfo` | 完成 |
| 2 | 效能數據 `stat`、即時監看 `watch` | 完成 |
| 3 | 四個關閉參數、demo 腳本、封包擷取 | 待做 |
| 4 | 報告與影片 | 待做 |
