#!/system/bin/sh
MODDIR=${0%/*}
CONTROL="$MODDIR/control.sh"
NETWATCH="$MODDIR/bin/netwatch"
PROPWAIT="$MODDIR/bin/propwait"
NOTIFY_DEX="$MODDIR/bin/smbnotify.dex"
NOTIFY_SH="$MODDIR/notify.sh"
RUNTIME=/data/adb/smbdwebui/runtime
LOGDIR="$RUNTIME/log"
STAMP="$(date '+%Y%m%d-%H%M%S' 2>/dev/null)"
OUT="$LOGDIR/diagnose_${STAMP}.log"

mkdir -p "$LOGDIR" 2>/dev/null

{
  echo "===== Android SMB Server 診斷 ====="
  echo "時間: $(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null)"
  echo
  "$CONTROL" diagnose
  echo
  echo "===== netwatch 完整性／LAN 事件過濾 ====="
  echo "模式: native NETLINK_ROUTE；僅 LAN 候選介面觸發 Shell 檢查"
  if [ -x "$NETWATCH" ]; then
    "$NETWATCH" --version 2>&1
    echo "大小: $(wc -c < "$NETWATCH" 2>/dev/null) bytes"
    if command -v sha256sum >/dev/null 2>&1; then
      sha256sum "$NETWATCH" 2>/dev/null
    fi
  else
    echo "缺少：$NETWATCH"
  fi
  echo
  echo "===== propwait／開機等待 ====="
  echo "模式: native bionic property wait；120 秒一次性 watchdog；失敗才有限輪詢 fallback"
  if [ -x "$PROPWAIT" ]; then
    "$PROPWAIT" --version 2>&1
    echo "大小: $(wc -c < "$PROPWAIT" 2>/dev/null) bytes"
    echo "sys.boot_completed: $(getprop sys.boot_completed 2>/dev/null)"
    if command -v sha256sum >/dev/null 2>&1; then
      sha256sum "$PROPWAIT" 2>/dev/null
    fi
  else
    echo "缺少：$PROPWAIT"
  fi
  echo
  echo "===== SMB 專用通知 Dex ====="
  echo "入口: $NOTIFY_SH"
  if [ -f "$NOTIFY_DEX" ]; then
    echo "Dex: $NOTIFY_DEX"
    echo "大小: $(wc -c < "$NOTIFY_DEX" 2>/dev/null) bytes"
    if command -v sha256sum >/dev/null 2>&1; then
      sha256sum "$NOTIFY_DEX" 2>/dev/null
    fi
    (
      export CLASSPATH="$NOTIFY_DEX"
      app_process /system/bin com.yawasau.smbnotify.SmbNotifyUtil help 2>/dev/null | head -n 3
    )
  else
    echo "未安裝 smbnotify.dex；SMB 主功能不受影響，通知功能停用"
  fi
  echo
  echo "===== 設定（不含密碼）====="
  cat /data/adb/smbdwebui/config.conf 2>/dev/null
  echo
  echo "===== PASSDB 中繼資料（不輸出 Hash）====="
  awk -F: '/^root:0:/ {
    print "user=" $1
    print "uid=" $2
    print "nt_hash_length=" length($4)
    print "flags=" $5
  }' "$RUNTIME/private/smbpasswd" 2>/dev/null
  echo
  echo "===== module.log 最近 300 行 ====="
  tail -n 300 "$LOGDIR/module.log" 2>/dev/null
  echo
  echo "===== smbd.log 最近 150 行 ====="
  tail -n 150 "$LOGDIR/smbd.log" 2>/dev/null
  echo
  echo "===== smbd.stderr.log 最近 100 行 ====="
  tail -n 100 "$LOGDIR/smbd.stderr.log" 2>/dev/null
} | tee "$OUT"

echo
echo "診斷已保存：$OUT"
