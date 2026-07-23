# Android SMB Server WebUI

在已取得 Root 權限的 Android 裝置上執行 Samba `smbd`，並透過模組 WebUI 管理 SMB 分享、認證、協議、網路介面與日誌。

目前版本：`v0.3.11-remove-mt-compat-20260715`  
版本代碼：`41`  
架構：`arm64-v8a`

> 本模組會以 Root 身分執行 `smbd`。請只分享必要目錄，優先使用帳號密碼模式，並且不要把 TCP 445 直接暴露到網際網路。

## 功能

- 內建 Samba 4.24.4 `smbd`
- WebUI 啟動、停止與重新啟動 SMB 服務
- Guest／匿名模式
- 使用者名稱／密碼模式
- 密碼只保存 NT Hash，不將明文寫入 `config.conf`
- 自訂分享路徑、分享名稱、連接埠、NetBIOS 名稱與 Workgroup
- 可讀寫或唯讀分享
- SMB2／SMB3 最低與最高協議設定
- LAN Guard：只在可信任區域網路介面上啟動服務
- 原生 rtnetlink 網路事件監看，不使用常駐輪詢
- 離開可信任 LAN 時自動停止，重新進入 LAN 時自動啟動
- LAN IP 或介面變更後自動重新綁定 `smbd`
- 原生 Android property wait，等待開機完成時不做每秒輪詢
- Windows 目錄變更即時通知
- 繁體中文、簡體中文及英文 WebUI
- 跟隨系統、淺色、深色及 OLED 黑主題
- 模組卡片即時顯示服務狀態與 SMB 位址
- 一鍵產生診斷報告
- 支援安裝後立即啟用及熱更新，通常不需要重新開機

## 安全設計

### LAN Guard

模組預設只接受可信任的實體 LAN 類型介面，例如：

- Wi-Fi
- Ethernet
- Wi-Fi 熱點
- USB 網路
- Bluetooth PAN
- Bridge／Bond

下列介面會被排除：

- 行動數據
- VPN
- TUN／TAP
- WireGuard
- Tailscale／ZeroTier 類虛擬網路
- CLAT、GRE 及其他隧道介面
- Wi-Fi Aware／P2P

開啟「開機自動啟動」時，模組會強制啟用介面綁定。裝置離開可信任 LAN 後，`smbd` 會停止並等待可信任網路恢復。

### 認證模式

#### Guest／匿名

不需要帳號密碼，適合完全可信任的私人區域網路。

Guest 模式不應用於公共 Wi-Fi、宿舍網路、公司訪客網路或任何無法控制其他使用者的環境。

#### 使用者名稱／密碼

- 停用 Guest 存取
- 使用者名稱只允許英文字母、數字、點、底線及連字號
- 使用者名稱最長 32 個字元
- 密碼經本機工具轉換為 NT Hash
- 明文密碼不會寫入 `config.conf`
- Hash 儲存在權限受限的 Samba passdb 檔案中

NT Hash 仍屬敏感認證資料，不應分享診斷目錄、runtime private 目錄或完整 `/data/adb` 備份。

## 相容性

- Android Root 環境
- `arm64-v8a` 裝置
- 模組格式要求 Magisk `26.4.2` 或相容的模組管理器
- WebUI 目前使用 `ksu.exec` 或 `ap.exec` 執行 Root 指令
- KernelSU／KernelSU Next 與 APatch 類 WebUI 管理器可使用完整 WebUI
- 沒有相容 WebUI bridge 時，SMB 服務及命令列控制仍可使用

目前發布包只包含 arm64 版 `smbd`，其他架構會在安裝時中止。

## 安裝

1. 從 Releases 下載最新模組 ZIP。
2. 在 Magisk、KernelSU、KernelSU Next、APatch 或相容模組管理器中安裝。
3. 安裝完成後重新開啟模組頁面。
4. 進入 WebUI 設定分享目錄及認證模式。
5. 按下「啟動服務」。

本模組沒有 system overlay。安裝程序會將新版內容同步到正式模組目錄，通常不需要重新開機；部分模組管理器仍可能顯示通用的重新開機提示。

## 首次設定

預設值：

```ini
AUTO_START=0
ENABLED=0
SHARE_PATH=/sdcard/SpeedBackup
SHARE_NAME=SpeedBackup
READ_ONLY=0
MIN_PROTOCOL=SMB2_02
MAX_PROTOCOL=SMB3
BIND_INTERFACES=1
INTERFACES_AUTO=1
EXTRA_INTERFACES=
PORT=445
NETBIOS_NAME=ANDROIDSMB
WORKGROUP=WORKGROUP
AUTH_MODE=guest
SMB_USERNAME=speedbackup
```

建議首次使用時：

1. 將分享路徑改成實際需要存取的目錄。
2. Windows 或多使用者網路環境優先改用帳號密碼模式。
3. 保持「只綁定指定介面」開啟。
4. 最低協議保持 `SMB2_02` 或更高。
5. 確認 WebUI 顯示的 SMB 位址後再從客戶端連線。

## 連線方式

假設 WebUI 顯示：

```text
smb://192.168.1.100/SpeedBackup/
```

### Windows

在檔案總管網址列輸入：

```text
\\192.168.1.100\SpeedBackup
```

### Android、macOS 或 Linux

在支援 SMB 的檔案管理器中輸入：

```text
smb://192.168.1.100/SpeedBackup/
```

帳號密碼模式請使用 WebUI 內設定的 SMB 使用者名稱與密碼。Windows 連線建議使用帳號密碼模式。

## WebUI 設定

### 分享設定

| 設定 | 說明 |
|---|---|
| 分享路徑 | Android 上要公開的目錄 |
| 分享名稱 | 客戶端看到的 SMB share 名稱 |
| 唯讀分享 | 開啟後禁止客戶端寫入及刪除 |
| 開機自動啟動 | Android 開機完成且可信任 LAN 就緒後啟動 |

### 協議與介面

| 設定 | 說明 |
|---|---|
| 最低／最高 SMB 協議 | 支援 SMB2_02 至 SMB3_11 |
| Port | 預設為 TCP 445 |
| 自動加入目前 IPv4 | 從可信任 LAN 介面取得 IPv4／CIDR |
| 只綁定指定介面 | 將 `smbd` 限制在產生的 interfaces 清單 |
| 額外 interfaces／CIDR | 手動加入額外位址或網段 |
| NetBIOS | Samba NetBIOS 名稱 |
| Workgroup | SMB Workgroup 名稱 |

WebUI 設定採即時保存。服務執行中時，需要重新載入的設定會自動重新啟動 `smbd`。

## Windows 目錄刷新

產生的 `smb.conf` 會啟用：

```ini
change notify = yes
kernel change notify = yes
smb3 directory leases = no
```

這組設定用來讓 Windows 更快看到 Android 本機程序建立、刪除或重新命名的檔案，同時避免 SMB3 目錄租約長時間快取舊目錄清單。

## 命令列控制

模組控制入口：

```sh
su
MODDIR=/data/adb/modules/smbdwebui
```

常用指令：

```sh
sh "$MODDIR/control.sh" start
sh "$MODDIR/control.sh" stop
sh "$MODDIR/control.sh" restart
sh "$MODDIR/control.sh" status_text
sh "$MODDIR/control.sh" log
sh "$MODDIR/control.sh" conf
sh "$MODDIR/control.sh" diagnose
```

完整指令：

```text
start
stop
restart
status
status_text
get_config
set_config
save_restart
set_password_hex
log
diagnose
clean_stderr
conf
interface_key
trusted_lan
suspend_network
is_running
refresh_card
```

範例：

```sh
sh "$MODDIR/control.sh" set_config \
  SHARE_PATH=/sdcard/SpeedBackup \
  SHARE_NAME=SpeedBackup \
  READ_ONLY=0 \
  AUTH_MODE=guest
```

不建議直接使用 `set_password_hex`。一般使用者應透過 WebUI 設定密碼，避免手動編碼錯誤。

## 設定與資料位置

| 路徑 | 用途 |
|---|---|
| `/data/adb/modules/smbdwebui` | 模組程式及 WebUI |
| `/data/adb/smbdwebui/config.conf` | 非機密使用者設定 |
| `/data/adb/smbdwebui/runtime/smb.conf` | 執行時產生的 Samba 設定 |
| `/data/adb/smbdwebui/runtime/log` | 模組及 Samba 日誌 |
| `/data/adb/smbdwebui/runtime/private` | Samba passdb 與使用者對應 |
| `/data/adb/smbdwebui/runtime/run` | PID 及執行時資料 |

升級時會保留 `config.conf`。解除安裝時會刪除已保存的 SMB 認證資料，但刻意保留非機密設定，重新安裝後可沿用。

需要完全清除所有設定時，可在解除安裝後手動刪除：

```sh
su -c 'rm -rf /data/adb/smbdwebui'
```

## 日誌與診斷

WebUI 的「查看日誌」可顯示模組日誌、即時網路診斷及 Samba 日誌。

命令列產生完整診斷報告：

```sh
su
/data/adb/modules/smbdwebui/diagnose.sh
```

診斷內容包括：

- 模組版本
- Android 版本及核心資訊
- `smbd`、`netwatch`、`propwait` 版本
- 目前設定，但不輸出密碼
- passdb 中繼資料，但不輸出 NT Hash
- 目前網路介面與 LAN 判定
- 產生的 `smb.conf`
- 最近的模組及 Samba 日誌

回報問題時請一併提供診斷檔，並先確認其中沒有你不希望公開的裝置名稱、路徑、IP 位址或其他環境資訊。

## 運作架構

```text
模組 WebUI
  └─ control.sh
      ├─ 產生 runtime/smb.conf
      ├─ 啟動／停止 bin/smbd
      ├─ 更新模組卡片
      └─ 輸出狀態與診斷

service.sh
  ├─ bin/propwait 等待 sys.boot_completed
  └─ 啟動 network_watch.sh

network_watch.sh
  └─ bin/netwatch 監聽 NETLINK_ROUTE
      ├─ LAN 出現：啟動或重新綁定 smbd
      └─ LAN 消失：停止 smbd

notify.sh
  └─ app_process + bin/smbnotify.dex
      └─ 顯示啟動、停止及錯誤通知
```

## 模組檔案

```text
META-INF/                         安裝入口
action.sh                        模組管理器動作按鈕
customize.sh                     安裝及熱更新流程
service.sh                       開機服務入口
control.sh                       主要控制與設定介面
network_watch.sh                 LAN 狀態協調器
notify.sh                        Android 狀態通知入口
diagnose.sh                      一鍵診斷
uninstall.sh                     解除安裝清理
module.prop                      模組資訊
sha256sum.txt                    發布包內檔案雜湊
bin/smbd                         Samba 伺服器
bin/netwatch                     原生 rtnetlink watcher
bin/propwait                     原生 Android property wait
bin/ntlmhash                     NT Hash 建立工具
bin/smbnotify.dex                獨立通知 Dex
webroot/                         WebUI
```

`sha256sum.txt` 供人工或發布流程核對檔案，目前安裝腳本不會強制執行整包雜湊驗證。

## 開發與建置

Release ZIP 內含可執行檔，但公開原始碼倉庫應同時提供：

- `netwatch` 原始碼及 NDK 建置腳本
- `propwait` 原始碼及 NDK 建置腳本
- `ntlmhash` 原始碼及建置腳本
- `smbnotify.dex` 的 Java／Kotlin 原始碼及 Dex 建置流程
- Android 版 Samba 的修改內容、完整建置參數及可重現建置說明
- 產生 release ZIP 與 `sha256sum.txt` 的打包腳本

建議的倉庫結構：

```text
module/                 模組腳本與 WebUI
src/netwatch/           netwatch 原始碼
src/propwait/           propwait 原始碼
src/ntlmhash/           ntlmhash 原始碼
src/smbnotify/          通知 Dex 原始碼
third_party/            第三方授權與 patch
build/                  建置腳本
release/                打包及 checksum 腳本
```

不要只公開 release ZIP 中的已編譯 binary。可重現建置、對應原始碼與第三方授權文字，是讓使用者能審核 Root daemon 的必要條件。

## 授權與第三方元件

本模組包含 Samba 4.24.4 的 `smbd`。Samba 專案使用 GPLv3-or-later／LGPLv3-or-later 授權，實際適用條款依元件而定。散布編譯後的 Samba binary 時，應一併提供對應原始碼、修改內容、建置方式及必要授權文字。

正式公開前請完成：

- 在倉庫根目錄加入 `LICENSE`
- 明確標示自有腳本、WebUI、native helper 與 Dex 的授權
- 加入 Samba 對應版本的授權文字
- 加入 `THIRD_PARTY_NOTICES.md`
- 提供本次 `bin/smbd` 對應的完整 source／patch／build instructions
- 確認所有 binary 都能追溯到公開原始碼及建置產物

若希望整個倉庫使用單一且與 Samba 相容的授權，`GPL-3.0-or-later` 是較容易管理的選項；最終授權仍應由專案維護者決定。

## 貢獻

Issue 請至少提供：

- 裝置型號
- Android 版本
- Root／模組管理器及版本
- 模組版本
- 使用的認證模式
- 網路類型
- 問題重現步驟
- `diagnose.sh` 產生的診斷資料

提交 Pull Request 前請：

- 保持 shell 相容 Android `/system/bin/sh`
- 避免依賴 Bash-only 語法
- 不在日誌輸出明文密碼或 NT Hash
- 不取消 LAN Guard 或降低預設網路安全性
- 更新 README、版本資訊及對應 checksum
- 說明是否需要重新編譯 native binary 或 Dex

## 已知限制

- 目前只提供 arm64 binary
- `smbd` 以 Root 身分執行，錯誤的分享路徑可能公開敏感檔案
- Guest 模式沒有身分驗證
- WebUI 需要相容的 Root manager exec bridge
- 某些 ROM、核心或 SELinux 策略可能阻止 Samba 綁定連接埠或存取指定路徑
- Windows 舊連線工作階段可能保留先前認證或目錄快取，需要中斷連線後重試
- 模組不應作為公網 SMB 伺服器使用

## 免責聲明

本專案需要 Root 權限，會執行網路服務並讀寫使用者指定的檔案目錄。使用者應自行確認分享範圍、網路環境、備份及授權合規性。維護者不對資料遺失、未授權存取、裝置異常或錯誤設定造成的損害負責。
