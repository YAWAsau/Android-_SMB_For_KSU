#!/system/bin/sh
MODDIR=${0%/*}
if sh "$MODDIR/control.sh" is_running >/dev/null 2>&1; then
  echo "- 停止 SMB 伺服器"
  sh "$MODDIR/control.sh" stop
else
  echo "- 啟動 SMB 伺服器"
  sh "$MODDIR/control.sh" start
fi
sh "$MODDIR/control.sh" refresh_card >/dev/null 2>&1
sh "$MODDIR/control.sh" status_text
