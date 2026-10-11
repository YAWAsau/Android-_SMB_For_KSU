# v0.3.17

SMB 管理後端遷移至單一 Rust ELF，保留 Samba 4.25.0 資料傳輸引擎與既有帳密。

- 狀態查詢、設定解析與原子保存、啟停鎖、程序身分與監聽 socket 驗證整合進 smbctl。
- rtnetlink、inotify、pidfd 與 CE 屬性事件驅動；健康待機無固定輪詢。屬性等待內建於 Rust，移除 netwatch、ntlmhash、propwait 舊 ELF。
- 修正開機解密等待、分享路徑初始化、日誌按開機輪替，以及 MT_COMPAT_MODE 舊設定升級相容。安裝失敗顯示實際錯誤。
- 修正 Android robust mutex 不可用時的 Samba 日誌，更新通知元件與圖示，保留真正的錯誤輸出。
- NDK r30/API 28，ARM64；Rust ELF LOAD/RELRO 16 KiB 對齊。

驗證：16 個 Android 單元測試、Guest 上下載、帳密及錯誤密碼、程序崩潰恢復、設定事件、停止持續性通過；健康待機 CPU 增量為零的取樣通過。以回報者設定重現舊版失敗，修正版自檢與設定保存通過。

相容範圍：仍使用 NTLMv2；Rust 遷移不等於淘汰 NTLM。需要核心提供可用 pidfd（含權限）、rtnetlink、inotify，API 28 不代表所有舊核心皆相容。其他 ROM、群友裝置完整升級仍需實測。

附件含可刷 ZIP、源碼與建置資料包及 SHA256。Source 包含專案與 vendor 依賴；第三方來源／下載需求以 README 建置說明為準。
