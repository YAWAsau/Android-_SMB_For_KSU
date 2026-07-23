#!/system/bin/sh
MODDIR=${0%/*}
RUNTIME=/data/adb/smbdwebui/runtime
LOGDIR="$RUNTIME/log"
MODULE_LOG="$LOGDIR/module.log"
NOTIFY_ERR="$LOGDIR/notify_stderr.log"
DEX="$MODDIR/bin/smbnotify.dex"
CLASS=com.yawasau.smbnotify.SmbNotifyUtil

mkdir -p "$LOGDIR" 2>/dev/null

notify_log() {
  printf '%s pid=%s component=notify level=%s stage=%s %s\n' \
    "$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null)" "$$" "$1" "$2" "$3" \
    >> "$MODULE_LOG" 2>/dev/null
}

clean_field() {
  printf '%s' "$1" | tr '\r\n' '  '
}

rotate_notify_stderr() {
  local size
  [ -f "$NOTIFY_ERR" ] || return 0
  size=$(wc -c < "$NOTIFY_ERR" 2>/dev/null)
  case "$size" in ''|*[!0-9]*) return 0 ;; esac
  [ "$size" -lt 262144 ] && return 0
  mv "$NOTIFY_ERR" "$NOTIFY_ERR.1" 2>/dev/null || :
}

notify_event() {
  local type title text bigtext rc out out_one
  type="$(clean_field "$1")"
  title="$(clean_field "$2")"
  text="$(clean_field "$3")"
  bigtext="$(clean_field "${4:-$3}")"

  if [ ! -f "$DEX" ]; then
    notify_log WARN NOTIFY_DEX_MISSING "缺少 $DEX；略過通知 type=$type"
    return 127
  fi

  rotate_notify_stderr
  out="$(
    export CLASSPATH="$DEX"
    printf '%s\n' \
      "TYPE|$type" \
      "TITLE|$title" \
      "TEXT|$text" \
      "BIGTEXT|$bigtext" \
      'END' |
      app_process /system/bin "$CLASS" notify --stdin
  )" 2>> "$NOTIFY_ERR"
  rc=$?
  out_one="$(clean_field "$out")"
  if [ "$rc" -eq 0 ]; then
    case "$out" in
      *SMB_NOTIFY_SENT*)
        notify_log INFO NOTIFY_SENT "type=$type text=$text dex=$out_one"
        ;;
      *)
        notify_log WARN NOTIFY_UNCONFIRMED "type=$type rc=0 text=$text dex=$out_one"
        ;;
    esac
  else
    notify_log WARN NOTIFY_FAIL "type=$type rc=$rc text=$text dex=$out_one"
  fi
  return "$rc"
}

case "$1" in
  event)
    shift
    notify_event "$@"
    ;;
  selftest)
    notify_event success "SMB 伺服器" "通知 Dex 測試成功" "SMB 專用通知 Dex 已可正常呼叫。"
    ;;
  *)
    echo "Usage: $0 event <type> <title> <text> [bigtext] | selftest" >&2
    exit 2
    ;;
esac
