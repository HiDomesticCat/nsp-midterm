# pmon

遠端效能監控系統。Network and System Programming 期中作業。

server（`pmond`）跑在被監控的主機上，每個連線 `fork()` 一個 child；
client（`pmon`）連線查詢主機的系統資訊與即時效能數據。兩者共用 `libpmon.so`。

## 建置

```
make            # 一般建置 → build/
make DEBUG=1    # 除錯建置 → build-debug/（保留 debug log）
make deploy     # 把 client 與 libpmon.so 複製到 client VM
make clean
```

需要 gcc 與 make。demo 腳本另外用到 `tcpdump`、`nc`、`curl`。

## 使用

```
build/bin/pmond                          # 啟動 server，預設埠 9419
build/bin/pmon sysinfo                   # 主機的靜態資訊
build/bin/pmon stat                      # 目前的 CPU、記憶體、磁碟、網路
build/bin/pmon watch -i 1                # 每秒一列，Ctrl+C 結束
build/bin/pmon -s nsp-server watch       # 連到別台主機
```

`pmond -h`、`pmon -h` 列出所有參數。

## Demo

每支腳本展示一項題目要求，會自己啟動與關閉 server。

| 腳本 | 題目要求 |
|---|---|
| `demo/01-basic.sh` | client 向 server 要系統資訊 |
| `demo/02-ten-clients.sh [remote]` | `fork()` 處理每個連線；10 個 client 同時連線的執行期證明 |
| `demo/03-capture.sh [介面 remote]` | 封包擷取（分析見 `docs/CAPTURE.md`） |
| `demo/04-debug-log.sh` | 編譯期與執行期兩層 debug log 控制 |
| `demo/05-shared-lib.sh` | server 與 client 共用動態函式庫 |
| `demo/r1-zombie.sh` | 強健性：回收結束的 child |
| `demo/r2-validate.sh` | 強健性：拒絕不合協定的資料 |
| `demo/r3-timeout.sh` | 強健性：不送資料的 client 會逾時 |
| `demo/r4-sigpipe.sh` | 強健性：client 中途消失時 server 不會被殺掉 |
| `demo/run-all.sh [pause]` | 依序執行全部 |
| `demo/verify.sh` | 逐條檢查全部要求，印出 PASS 或 FAIL（另需 `tshark`） |

四支 `r*` 腳本各跑兩次：先關掉機制，再開啟機制，比較兩者的行為。

## 目錄

```
include/pmon.h    函式庫的標頭
lib/              libpmon.so：log.c io.c proto.c kv.c
server/           pmond：pmond.c session.c sysinfo.c metrics.c
client/           pmon：pmon.c
demo/             展示腳本
docs/             DESIGN.md（系統設計）、CAPTURE.md（封包分析）、capture/（擷取檔與 Wireshark 解析器 pmon.lua）
infra/            建立測試用 VM 的腳本
```
