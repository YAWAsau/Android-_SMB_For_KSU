#!/system/bin/sh
MODDIR=${0%/*}
LOGDIR=/data/adb/smbdwebui/runtime/log
mkdir -p "$LOGDIR"
OUT="$LOGDIR/diagnose_$(date '+%Y%m%d-%H%M%S').log"
{
  "$MODDIR/bin/smbctl" --version
  "$MODDIR/bin/smbctl" diagnose
  "$MODDIR/bin/smbctl" log
} > "$OUT" 2>&1
cat "$OUT"
echo "診斷報告: $OUT"
