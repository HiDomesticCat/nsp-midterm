# pmon：遠端效能監控系統

Network and System Programming 期中報告

姓名：＿＿＿＿＿＿　　學號：＿＿＿＿＿＿

# 1. 應用介紹

## 1.1 這個系統做什麼

`pmon` 是一個遠端效能監控系統。server（`pmond`）跑在被監控的主機上，client（`pmon`）從別台機器連線，查詢那台主機的系統資訊與即時效能數據。

情境是多人共用的運算主機：使用者在送出工作之前想知道主機現在忙不忙，管理者想持續盯著負載。每個人各開一個 `pmon watch`，就會有多個 client 同時連在同一台 server 上。

| 指令 | 作用 |
|---|---|
| `pmon sysinfo` | 主機的靜態資訊：主機名稱、核心版本、CPU 數量、開機時間、記憶體與磁碟總量 |
| `pmon stat` | 目前的效能數據，取樣一次 |
| `pmon watch [-i 秒] [-n 次數]` | 每隔一段時間顯示一列效能數據，直到按 Ctrl+C 或達到次數 |

## 1.2 題目要求對照

| 題目要求 | 做法 | 本報告章節 |
|---|---|---|
| server 用 `fork()` 為每個連線建立 child，不用 thread | parent 只負責 accept 與 fork | 2.3、3.1、4.2 |
| 至少 10 個 client 同時連線，附執行期證明 | 10 個 client 同時 `watch`，以 `ps`、`ss`、server log 三方對照 | 4.2 |
| 封包擷取與分析 | `tcpdump` 擷取 loopback 與跨機兩份 | 6 |
| 編譯期與執行期兩層 debug log 控制 | 編譯期巨集；執行期參數、環境變數、`SIGUSR1` | 2.4、3.4、4.3 |
| client 與 server 共用的函式包成動態函式庫 | `libpmon.so` | 2.5、3.6、4.4 |
| client 向 server 要系統資訊 | `sysinfo`、`stat`、`watch` | 4.1 |
| 強健性機制，至少三組有與沒有的對照 | 四個機制各有一個關閉參數 | 5 |
| 用 Makefile 或 CMake 建置 | 手寫 Makefile | 3.6 |

## 1.3 開發與測試環境

| 主機 | 角色 | 規格 | 測試網段位址 |
|---|---|---|---|
| `nsp-server` | 開發、編譯、執行 server | 2 vCPU、4 GB、Ubuntu 24.04、gcc 13.3 | 10.77.0.10 |
| `nsp-client-1` | 執行 client | 1 vCPU、2 GB、沒有編譯器 | 10.77.0.21 |
| `nsp-client-2` | 執行 client | 1 vCPU、2 GB、沒有編譯器 | 10.77.0.22 |

三台是 OpenStack 上的虛擬機，接在一個不對外的獨立測試網段。原始碼只在 `nsp-server` 上編譯，`make deploy` 把 client 執行檔與函式庫複製到兩台 client 主機。本報告的所有輸出都是在這個環境實際執行的結果。

# 2. 系統設計

## 2.1 元件

| 元件 | 檔名 | 原始碼 | 角色 |
|---|---|---|---|
| Server | `pmond` | `server/` | 接受連線、fork child、從 `/proc` 讀取效能數據 |
| Client | `pmon` | `client/` | 命令列工具，送出請求並顯示結果 |
| 共用函式庫 | `libpmon.so` | `lib/`、`include/pmon.h` | log、可靠讀寫、協定、`key=value` 文字處理 |

## 2.2 通訊協定

使用 TCP，預設埠 9419。請求與回應是同一種訊框：12 位元組標頭，後面接 0 到 65536 位元組的內容。多位元組欄位為 network byte order。

| 位移 | 長度 | 欄位 | 說明 |
|---|---|---|---|
| 0 | 2 | magic | 固定 `0x504D`（ASCII `PM`） |
| 2 | 1 | opcode | 操作碼 |
| 3 | 1 | status | 回應的結果碼，請求中為 0 |
| 4 | 4 | length | 內容的位元組數，上限 64 KiB |
| 8 | 4 | crc32 | 內容的 CRC-32 |

內容是 `key=value` 的文字行。

| 操作碼 | 名稱 | 請求內容 | 回應內容 |
|---|---|---|---|
| 1 | SYSINFO | 無 | 主機的靜態資訊 |
| 2 | STAT | 無 | 一次效能數據 |
| 3 | WATCH | `interval`（1 到 60 秒）、`count`（0 表示不限） | 每隔 interval 推送一個訊框，內容同 STAT |

| 結果碼 | 意義 |
|---|---|
| 0 OK | 成功 |
| 1 BAD_REQUEST | 訊框格式錯誤、未知的操作碼、參數超出範圍 |
| 2 BUSY | 連線數已達上限 |
| 3 INTERNAL | server 內部錯誤 |

## 2.3 Server 的行程模型與流程

```
pmond (parent)   socket → bind → listen → 主迴圈
  ├─ child  ← client A
  ├─ child  ← client B
  └─ ...
```

parent 的主迴圈：

1. 用 `poll()` 等待 listen socket 有新連線，最多等一秒。
2. 有連線就 `accept()`。child 數量已達上限（預設 64）時，回一個 BUSY 訊框並關閉。
3. `fork()`。child 關掉 listen socket，進入請求迴圈；parent 關掉連線的 socket，記下 child 的 pid，回到步驟 1。
4. 每一輪開頭檢查訊號旗標：有 child 結束就回收，被要求結束就離開迴圈。

child 的請求迴圈：讀一個訊框，檢查，處理，回應，重複到 client 斷線為止，然後結束行程。

一次 `watch` 的流程：

```
client                              server (child)
  | WATCH interval=1 count=0 -----> |  取第一次樣本
  |                                 |  等 1 秒（同時留意 client 是否離開）
  | <------------- WATCH OK 數據    |  取樣、計算、送出
  |                                 |  等 1 秒
  | <------------- WATCH OK 數據    |
  | （Ctrl+C，連線關閉）             |  發現連線關閉，結束
```

訊號的處理方式：訊號處理函式只設定旗標，實際的工作在主迴圈做。訊號處理函式裡不能安全地呼叫 `printf` 這類函式，把工作移到主迴圈之後，回收 child 時就能寫 log，包括 child 是被哪個訊號殺掉的。

| 訊號 | parent 的反應 |
|---|---|
| `SIGCHLD` | 用 `waitpid(-1, WNOHANG)` 迴圈回收所有結束的 child |
| `SIGINT`、`SIGTERM` | 停止接受連線，通知所有 child 結束，等它們結束後離開 |
| `SIGUSR1` | 切換 debug 輸出的開關 |
| `SIGPIPE` | 忽略，寫入失敗改由 `send()` 的回傳值得知 |

## 2.4 兩層 debug log

| 層 | 怎麼控制 | 效果 |
|---|---|---|
| 編譯期 | `make` 與 `make DEBUG=1` | 一般建置中 `LOG_DEBUG()` 不產生任何程式碼，除錯訊息的字串不在執行檔裡 |
| 執行期 | `-v` 參數、環境變數 `PMON_LOG=debug`、對 server 送 `SIGUSR1` | 在除錯建置中切換是否輸出 debug 訊息，不必重新編譯或重啟 |

編譯期決定「執行檔裡有沒有」，執行期決定「現在印不印」。

log 的每一行包含時間、等級、程式名稱與 pid、原始檔與行號。pid 讓多個 child 混在一起的輸出可以分辨。每行用單一 `write()` 輸出，多個行程同時寫不會交錯。

```
2026-11-12 10:25:41.398 [DEBUG] pmond[57521] server/pmond.c:197: forked child 57529 for 127.0.0.1:47636, 1 active
```

## 2.5 共用函式庫

| 模組 | 內容 | server 怎麼用 | client 怎麼用 |
|---|---|---|---|
| `log` | 兩層控制與輸出格式 | 記錄連線與錯誤 | 除錯輸出 |
| `io` | 帶逾時的完整讀寫 | 讀請求、送回應 | 送請求、讀回應 |
| `proto` | 訊框的收送與檢查、CRC-32 | 同上 | 同上 |
| `kv` | 從 `key=value` 文字取值 | 讀 `watch` 的參數 | 從回應取出各項數據排成表格 |

四個模組兩邊都實際用到。函式庫以 `-fPIC -shared` 建置；執行檔連結時加上 rpath `$ORIGIN/../lib`，執行時會到自己所在位置旁邊的 `lib/` 找函式庫，不必設定 `LD_LIBRARY_PATH`。

## 2.6 效能數據的來源

| 項目 | 來源 | 算法 |
|---|---|---|
| CPU 使用率 | `/proc/stat` | 兩次取樣之間，非閒置時間佔全部時間的比例 |
| 負載與行程數 | `/proc/loadavg` | 直接讀取 |
| 記憶體、swap | `/proc/meminfo` | 總量減去可用量 |
| 磁碟使用率 | `statvfs("/")` | 已用區塊佔可用區塊的比例 |
| 網路收送速率 | `/proc/net/dev` | 兩次取樣之間的位元組差除以時間，不含 loopback |

CPU 與網路是變化率，需要兩次取樣。`stat` 間隔 0.2 秒取兩次；`watch` 用相鄰兩次推送當作區間。

# 3. 關鍵程式碼說明

## 3.1 parent：accept 與 fork（`server/pmond.c`）

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

- `fork()` 之後兩個行程都持有 listen socket 和連線的 socket。child 關掉 listen socket，parent 關掉連線的 socket。parent 如果不關，連線數一多就會用完檔案描述符，而且 child 結束後連線也不會真的關閉。
- child 把訊號處理還原成預設，因為它沒有自己的 child 要回收，收到 `SIGTERM` 應該直接結束。
- child 用 `_exit()` 而不是 `exit()`，避免把從 parent 繼承來的緩衝區再輸出一次。
- `fork()` 失敗時回 BUSY 給 client，server 繼續服務其他人。

## 3.2 回收 child（`server/pmond.c`）

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
        /* 從 pid 表移除 */
        if (WIFSIGNALED(status))
            LOG_ERROR("child %d was killed by signal %d (%s), %d still active",
                      (int)pid, WTERMSIG(status), strsignal(WTERMSIG(status)),
                      g_nkids);
    }
}
```

- 用迴圈而不是只呼叫一次 `waitpid`：多個 child 幾乎同時結束時，`SIGCHLD` 可能只送達一次。
- `WNOHANG` 讓 `waitpid` 在沒有結束的 child 時立刻返回，不會卡住主迴圈。
- 主迴圈的 `poll()` 設了一秒逾時。如果訊號剛好在檢查旗標之後、進入 `poll()` 之前到達，最多一秒後也會被處理。

## 3.3 接收訊框時的檢查（`lib/proto.c`）

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

標頭裡的 length 決定接下來要配置多少記憶體、要等多少資料。它來自網路，在檢查之前不能相信。順序是先檢查 magic 與長度上限，才配置記憶體，讀完內容後再比對 CRC。5.2 節示範了少了這段檢查會發生什麼事。

## 3.4 `LOG_DEBUG` 巨集（`include/pmon.h`）

```c
#ifdef PMON_DEBUG
#define LOG_DEBUG(...) log_write(LOG_LVL_DEBUG, __FILE__, __LINE__, __VA_ARGS__)
#else
#define LOG_DEBUG(...) \
    do { if (0) log_write(LOG_LVL_DEBUG, __FILE__, __LINE__, __VA_ARGS__); } while (0)
#endif
```

- 除錯建置（`-DPMON_DEBUG`）時是真的呼叫 `log_write`，是否輸出由執行期的開關決定。
- 一般建置時是一段永遠不會執行的程式碼。編譯器會把呼叫連同格式字串一起刪掉，但仍然檢查參數的型別，變數也算有被使用，不會因為 `-Werror` 而編譯失敗。
- `__FILE__` 與 `__LINE__` 必須寫在巨集裡，才會是呼叫處的檔名與行號。

## 3.5 可靠的讀取（`lib/io.c`）

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

- TCP 是位元組串流，一次 `read()` 可能只拿到一部分，所以用迴圈讀到滿為止。
- 先 `poll()` 再 `read()`，對方不送資料時會在期限後返回 `IO_TIMEOUT`，不會永遠卡在 `read()`。
- 被訊號中斷（`EINTR`）時重試，不當成錯誤。server 會收到 `SIGUSR1`，這個處理是必要的。
- 逾時、對方關閉、錯誤用不同的回傳值區分，呼叫的人可以記錄真正的原因。

## 3.6 Makefile：共用函式庫的建置

```make
LDLIBS := -L$(BUILD)/lib -lpmon -Wl,-rpath,'$$ORIGIN/../lib'

$(BUILD)/obj/lib/%.o: lib/%.c
	$(CC) $(CFLAGS) -fPIC -MMD -MP -c $< -o $@

$(LIB): $(LIB_OBJ)
	$(CC) -shared -o $@ $^

$(SERVER): $(SERVER_OBJ) $(LIB)
	$(CC) -o $@ $(SERVER_OBJ) $(LDLIBS)
```

- 函式庫的物件檔加 `-fPIC`，產生位置無關的程式碼，才能被載入到任意位址。
- `-shared` 把物件檔連結成 `libpmon.so`。
- 執行檔用 `-lpmon` 連結，函式庫的程式碼不會被複製進執行檔。
- `make DEBUG=1` 加上 `-DPMON_DEBUG -g -O0`，輸出到另一個目錄 `build-debug/`，兩種建置可以並存比較。
- 所有檔案都以 `-std=c11 -Wall -Wextra -Werror` 編譯，目前沒有任何警告。

## 3.7 client 的指令表與選項解析（`client/pmon.c`）

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

- 所有指令宣告在一張表裡，每一列有名稱、負責執行的函式（函式指標）與說明文字。`main()` 查表後呼叫，`usage()` 也從同一張表印出說明。新增指令只要加一列。
- 選項分兩層解析。`main()` 用 `getopt(argc, argv, "+s:vh")` 處理指令名稱之前的全域選項，開頭的 `+` 讓它遇到指令名稱就停下；接著把 `argv` 移到指令名稱的位置、重設 `optind`，交給各指令用自己的規格再解析一次。所以 `-i 2`、`-i2`、選項順序互換都能接受，行為與系統上的其他工具一致。

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

- 選項的數值用 `strtol` 轉換而不是 `atoi`。`atoi("abc")` 會回傳 0、`atoi("5x")` 會回傳 5，都不報錯；`strtol` 可以檢查整個字串是否都是數字（`*end` 必須是字串結尾）以及是否溢位（`errno`）。
- 不合法時明確指出是哪個選項、允許的範圍與實際收到的內容，例如 `pmon: -i must be a number from 1 to 60, not '5x'`。

# 4. 執行結果

以下各節是 `demo/` 目錄中對應腳本的執行畫面截圖。每支腳本會自己啟動與關閉 server。截圖是在 `nsp-server` 上以終端機程式 xterm 執行腳本後擷取的畫面，由 `docs/report/screenshots.sh` 產生；文字版的輸出另存在 `docs/output/`。

## 4.1 基本功能：client 向 server 要系統資訊

`demo/01-basic.sh`

@image ../screenshots/01-basic.png

## 4.2 fork 與 10 個 client 同時連線

`demo/02-ten-clients.sh`：在同一台主機上啟動 10 個 client，各自 `watch` 6 秒。三項證明互相對照：

- 行程樹：1 個 parent 底下有 10 個 child。
- TCP 連線：埠 9419 上有 10 條已建立的連線。
- 每個 client 回報的 server pid 都不同，與行程樹中的 10 個 child 一致。

@image ../screenshots/02-ten-clients.png

`demo/02-ten-clients.sh remote`：改由兩台 client 主機各啟動 5 個 client。server 端看到的連線來自兩個不同的位址，各 5 條。

@image ../screenshots/02-ten-clients-remote.png

## 4.3 兩層 debug log 控制

`demo/04-debug-log.sh`

- 編譯期：同一句除錯訊息在一般建置的執行檔裡出現 0 次，在除錯建置裡出現 1 次；一般建置即使加上 `-v` 也沒有任何 debug 輸出。
- 執行期：除錯建置預設不輸出；對執行中的 server 送 `SIGUSR1` 之後開始輸出，再送一次就停止。

@image ../screenshots/04-debug-log.png

## 4.4 共用動態函式庫

`demo/05-shared-lib.sh`

- 兩個執行檔的動態區段都記錄需要 `libpmon.so`，搜尋路徑是 `$ORIGIN/../lib`。
- `proto_send` 在兩個執行檔裡都是未定義符號，執行時才從函式庫解析。
- 把函式庫移走之後，程式無法啟動。
- server 與兩台 client 主機上的函式庫雜湊值相同，是同一個檔案。

@image ../screenshots/05-shared-lib.png

# 5. 強健性機制

四個機制各有一個關閉參數。每支腳本先關掉機制執行一次，再開啟機制執行一次，其他條件完全相同。關閉參數只用於示範，server 啟動時會記錄一行警告。

| 編號 | 異常狀況 | 機制 | 關閉參數 |
|---|---|---|---|
| R1 | child 結束 | `SIGCHLD` + `waitpid` 迴圈 | `--no-reap` |
| R2 | 收到不是本協定的資料 | 檢查 magic、長度上限、CRC | `--no-validate` |
| R3 | client 連上後不送資料 | 讀取逾時 | `--no-timeout` |
| R4 | `watch` 途中 client 被強制結束 | 等待時留意連線是否關閉；忽略 `SIGPIPE`，由 `send()` 回傳 `EPIPE` | `--no-sigpipe` |

## 5.1 R1：回收結束的 child

`demo/r1-zombie.sh`：連續執行 5 次 `pmon stat`，然後看 server 的 child。

- 沒有機制：5 個 child 都停在狀態 `Z`（殭屍）。它們已經結束，但行程表的項目沒有被釋放。長時間執行的 server 會因此用完行程數上限。
- 有機制：沒有殘留。

@image ../screenshots/r1-zombie.png

## 5.2 R2：拒絕不合協定的資料

`demo/r2-validate.sh`：用 `curl` 對 server 的埠送出 HTTP 請求。

- 沒有機制：child 把 `GET / HTTP/1.1` 的前 12 個位元組當成標頭。第 4 到 7 個位元組 `/ HT` 被解讀成長度 `0x2f204854`，約 754 MiB。child 配置了這麼多記憶體（輸出中的 756 MB）並等待永遠不會來的資料，`curl` 等到逾時。任何人只要送 12 個位元組就能讓 server 佔用大量記憶體。
- 有機制：child 發現 magic 不是 `PM`，立刻回 BAD_REQUEST 並斷線，沒有配置任何記憶體。

@image ../screenshots/r2-validate.png

## 5.3 R3：不送資料的 client

`demo/r3-timeout.sh`：用 `nc` 連上 server 後什麼都不送。

- 沒有機制：5 秒後 child 還在。每一個這樣的連線永久佔用一個 child，連線數達到上限後其他人就連不進來。
- 有機制：3 秒後 child 記錄逾時並結束。（示範用 3 秒，預設是 10 秒。）

@image ../screenshots/r3-timeout.png

## 5.4 R4：client 中途消失

`demo/r4-sigpipe.sh`：`pmon watch` 執行到一半時用 `kill -9` 強制結束 client。

- 沒有機制：child 繼續往已關閉的連線寫入，被核心以 `SIGPIPE` 殺掉。parent 的 log 記錄了 `killed by signal 13 (Broken pipe)`。child 來不及做任何清理。
- 有機制：child 在等待下一次取樣時發現連線已關閉，記錄後正常結束。

@image ../screenshots/r4-sigpipe.png

## 5.5 其他已實作的機制

以下沒有設關閉參數，但同樣在程式中：

- 讀寫都用迴圈處理短讀、短寫與 `EINTR`（3.5 節）。
- 連線數上限，超過時回 BUSY；`fork()` 失敗時同樣回 BUSY，server 不會結束。
- 拒絕非法資料時先送出錯誤回覆、讀掉對方已送來的資料再關閉。直接關閉會讓核心送出重置，對方收不到回覆。這是測試時實際遇到後修正的問題。
- 參數檢查：client 以 `strtol` 驗證選項的數值（3.7 節），server 再檢查一次 `watch` 的參數範圍，不信任 client。
- `SO_REUSEADDR`，server 重啟不必等待。
- client 的連線逾時（5 秒）與回應逾時（15 秒）。
- 收到 `SIGINT` 或 `SIGTERM` 時，parent 通知所有 child 結束並等待它們，不留下孤兒行程。

# 6. 封包擷取與分析

`demo/03-capture.sh` 用 `tcpdump` 擷取一次 `pmon stat` 的完整連線。loopback 與跨機（`nsp-client-1` 到 `nsp-server`）各擷取一份，`.pcap` 檔在 `docs/capture/`，可用 Wireshark 開啟。以下以 loopback 的擷取說明。

## 6.1 整條連線：10 個封包

client 的埠是 58396，server 是 9419。

| # | 時間 | 方向 | 旗標 | 資料長度 | 意義 |
|---|---|---|---|---|---|
| 1 | .683795 | client → server | `S` | 0 | 三向交握：SYN |
| 2 | .683806 | server → client | `S.` | 0 | 三向交握：SYN + ACK |
| 3 | .683816 | client → server | `.` | 0 | 三向交握：ACK，連線建立 |
| 4 | .683841 | client → server | `P.` | 12 | 請求訊框（只有標頭） |
| 5 | .683845 | server → client | `.` | 0 | 確認收到請求 |
| 6 | .884327 | server → client | `P.` | 195 | 回應訊框（12 位元組標頭 + 183 位元組內容） |
| 7 | .884335 | client → server | `.` | 0 | 確認收到回應 |
| 8 | .884371 | client → server | `F.` | 0 | client 關閉連線：FIN |
| 9 | .884475 | server → client | `F.` | 0 | server 也關閉：FIN |
| 10 | .884485 | client → server | `.` | 0 | 確認，連線結束 |

- 封包 4 到 6 相隔 0.2 秒，是 server 計算 CPU 使用率時兩次取樣的間隔，不是網路延遲。
- 請求與回應各只佔一個 TCP 封包，因為 `proto_send()` 把標頭和內容放進同一個緩衝區一次送出。
- 由 client 先送 FIN；server 的 child 讀到 EOF 後結束，送出自己的 FIN。
- 序號與資料長度一致：請求佔 `seq 1:13`，回應佔 `seq 1:196`。

## 6.2 請求訊框

封包 4 的 TCP 資料共 12 位元組：

```
504d 0200 0000 0000 0000 0000
```

| 位元組 | 值 | 欄位 | 解讀 |
|---|---|---|---|
| 0–1 | `50 4d` | magic | ASCII `PM` |
| 2 | `02` | opcode | 2 = STAT |
| 3 | `00` | status | 請求固定為 0 |
| 4–7 | `00 00 00 00` | length | 內容長度 0 |
| 8–11 | `00 00 00 00` | crc32 | 空內容的 CRC-32 是 0 |

## 6.3 回應訊框

封包 6 的 TCP 資料共 195 位元組，以下是 `tcpdump -X` 的輸出：

```
0x0030:  9b56 241c 504d 0200 0000 00b7 1165 f848  .V$.PM.......e.H
0x0040:  7469 6d65 3d31 303a 3236 3a30 340a 6370  time=10:26:04.cp
0x0050:  755f 7063 743d 322e 350a 6c6f 6164 313d  u_pct=2.5.load1=
0x0060:  302e 3033 0a74 6173 6b73 3d31 3837 0a6d  0.03.tasks=187.m
0x0070:  656d 5f74 6f74 616c 5f6d 623d 3339 3135  em_total_mb=3915
```

| 位元組 | 值 | 欄位 | 解讀 |
|---|---|---|---|
| 0–1 | `50 4d` | magic | `PM` |
| 2 | `02` | opcode | 2 = STAT，與請求相同 |
| 3 | `00` | status | 0 = OK |
| 4–7 | `00 00 00 b7` | length | 0xb7 = 183 位元組 |
| 8–11 | `11 65 f8 48` | crc32 | 內容的 CRC-32 |
| 12 起 | `74 69 6d 65 3d ...` | 內容 | `time=10:26:04`、`cpu_pct=2.5` 等文字行 |

- 長度 183 寫成 `00 00 00 b7`，高位在前，是 network byte order。程式用 `put32()`、`get32()` 逐位元組組合，不依賴機器的位元組順序。
- TCP 資料長度 195 等於標頭 12 加內容 183，與 length 欄位一致。
- 內容是明文，在輸出右側可以直接閱讀。

## 6.4 跨機擷取的差異

| 項目 | loopback | 跨機 |
|---|---|---|
| 位址 | 127.0.0.1 → 127.0.0.1 | 10.77.0.21 → 10.77.0.10 |
| MSS | 65495 | 1410 |
| 封包 6 到 7 的間隔 | 0.008 毫秒 | 0.8 毫秒 |

應用層的 12 位元組標頭與內容格式完全相同。

# 7. 稽核與安全性討論

## 7.1 server 的 log 作為稽核紀錄

每個連線在 server 的 log 留下這些紀錄，等級是 INFO，任何建置都會輸出：

| 事件 | 記錄的內容 |
|---|---|
| 連線建立 | 時間、child 的 pid、client 的位址與埠 |
| 開始 `watch` | 間隔秒數 |
| 連線結束 | 處理了幾個請求；`watch` 送出了幾筆數據；結束的原因（正常斷線、逾時、client 消失） |
| 拒絕連線 | 原因（連線數已滿、訊框不合法及其細節） |
| child 異常終止 | pid 與訊號名稱 |

從 log 可以回答：誰在什麼時候連過、看了多久、有沒有人送過不合協定的資料。4.1 節輸出的最後一段就是一次完整的紀錄。

## 7.2 已知限制

- **沒有認證**：任何連得到 9419 埠的人都能查詢。log 能記錄的身分只有來源位址。
- **內容是明文**：第 6 節的擷取結果顯示，路徑上的任何人都能讀到主機的負載與記憶體資訊。
- **CRC-32 只能偵測傳輸錯誤**：攻擊者改了內容後可以重算 CRC，它不能防竄改。
- **log 輸出到標準錯誤**：由啟動 server 的人決定導向哪裡，程式本身沒有輪替或防竄改的機制。

目前的防護是把系統部署在不對外的獨立測試網段。認證與加密是期末專案 Security 項目的範圍。

## 7.3 關閉參數的風險

第 5 節的四個關閉參數會讓 server 處於不安全的狀態，只用於示範。server 啟動時只要有任何一個被關掉，就會在 log 記錄 `UNSAFE demonstration mode` 與被關掉的項目。

# 8. 建置與執行方式

```
make            # 一般建置 → build/
make DEBUG=1    # 除錯建置 → build-debug/
make deploy     # 把 client 與 libpmon.so 複製到 client 主機
make clean

build/bin/pmond                       # 啟動 server
build/bin/pmon sysinfo                # 查詢
build/bin/pmon -s nsp-server watch    # 連到別台主機持續監看

demo/run-all.sh pause                 # 依序執行全部 demo
```

| 腳本 | 展示的要求 |
|---|---|
| `demo/01-basic.sh` | 系統資訊 |
| `demo/02-ten-clients.sh [remote]` | fork、10 個 client 同時連線 |
| `demo/03-capture.sh [介面 remote]` | 封包擷取 |
| `demo/04-debug-log.sh` | 兩層 debug log |
| `demo/05-shared-lib.sh` | 共用動態函式庫 |
| `demo/r1-zombie.sh` 到 `demo/r4-sigpipe.sh` | 四組強健性對照 |

# 附錄：完整原始碼

@source Makefile
@source include/pmon.h
@source lib/log.c
@source lib/io.c
@source lib/proto.c
@source lib/kv.c
@source server/server.h
@source server/pmond.c
@source server/session.c
@source server/sysinfo.c
@source server/metrics.c
@source client/pmon.c
@source demo/common.sh
@source demo/01-basic.sh
@source demo/02-ten-clients.sh
@source demo/03-capture.sh
@source demo/04-debug-log.sh
@source demo/05-shared-lib.sh
@source demo/r1-zombie.sh
@source demo/r2-validate.sh
@source demo/r3-timeout.sh
@source demo/r4-sigpipe.sh
@source demo/run-all.sh
