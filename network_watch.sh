#!/system/bin/sh
MODDIR=${0%/*}
CFG=/data/adb/smbdwebui/config.conf
RUNTIME=/data/adb/smbdwebui/runtime
CONTROL="$MODDIR/control.sh"
NETWATCH="$MODDIR/bin/netwatch"
NOTIFY="$MODDIR/notify.sh"
BOOT_NOTIFY_PENDING="$RUNTIME/boot_notify_pending"
LOCK="$RUNTIME/network_watch.lock"
PIDFILE="$LOCK/pid"
NETWATCH_PIDFILE="$LOCK/netwatch_pid"
LOGDIR="$RUNTIME/log"
WATCH_LOG="$LOGDIR/module.log"
WATCH_LOG_OLD="$LOGDIR/module.log.1"

mkdir -p "$RUNTIME" "$LOGDIR" 2>/dev/null

rotate_watch_log() {
  local size
  [ -f "$WATCH_LOG" ] || return 0
  size=$(wc -c < "$WATCH_LOG" 2>/dev/null)
  case "$size" in ''|*[!0-9]*) return 0 ;; esac
  if [ "$size" -ge 1048576 ]; then
    rm -f "$WATCH_LOG_OLD" 2>/dev/null
    mv "$WATCH_LOG" "$WATCH_LOG_OLD" 2>/dev/null
  fi
}

log_watch() {
  local level="$1" stage="$2"
  shift 2
  rotate_watch_log
  printf '%s pid=%s component=watcher level=%s stage=%s %s\n' \
    "$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null)" "$$" "$level" "$stage" "$*" \
    >> "$WATCH_LOG" 2>/dev/null
}

notify_watch() {
  [ -x "$NOTIFY" ] || return 0
  sh "$NOTIFY" event "$1" "$2" "$3" "${4:-$3}" >/dev/null 2>&1 || true
}

boot_notify_pending() {
  [ -f "$BOOT_NOTIFY_PENDING" ]
}

consume_boot_notify_pending() {
  rm -f "$BOOT_NOTIFY_PENDING" 2>/dev/null
}

notify_start_success() {
  local current="$1"
  if boot_notify_pending; then
    notify_watch success "SMB 伺服器" "開機自啟動成功：$current" "Android 開機完成後，SMB 伺服器已在可信任區域網路啟動：$current"
    consume_boot_notify_pending
  else
    notify_watch event "SMB 伺服器" "已進入區域網路，SMB 伺服器已啟動" "可信任區域網路已恢復，SMB 伺服器已自動啟動：$current"
  fi
}

notify_start_failure() {
  local current="$1"
  if boot_notify_pending; then
    notify_watch error "SMB 伺服器啟動失敗" "開機自啟動失敗：$current" "Android 開機後已偵測到可信任區域網路，但 smbd 啟動失敗：$current。請查看模組日誌。"
    consume_boot_notify_pending
  else
    notify_watch error "SMB 伺服器啟動失敗" "已進入區域網路，但 SMB 啟動失敗" "可信任區域網路已恢復，但 smbd 啟動失敗：$current。請查看模組日誌。"
  fi
}

read_numeric_pid() {
  local value
  value="$(cat "$1" 2>/dev/null)"
  case "$value" in ''|*[!0-9]*) return 1 ;; esac
  printf '%s' "$value"
}

pid_cmdline() {
  tr '\0' ' ' < "/proc/$1/cmdline" 2>/dev/null
}

pid_exe() {
  readlink "/proc/$1/exe" 2>/dev/null
}

pid_matches_kind() {
  local pid="$1" kind="$2" cmd exe
  [ -d "/proc/$pid" ] || return 1
  cmd="$(pid_cmdline "$pid")"
  exe="$(pid_exe "$pid")"
  case "$kind" in
    watcher)
      case "$cmd" in *network_watch.sh*) return 0 ;; esac
      ;;
    netwatch)
      [ "$exe" = "$NETWATCH" ] && return 0
      case "$cmd" in *"/bin/netwatch"*|*" netwatch"*) return 0 ;; esac
      ;;
    old_monitor)
      case "$cmd" in *"ip monitor"*|*"ip"*"monitor"*) return 0 ;; esac
      ;;
  esac
  return 1
}

terminate_pid_file() {
  local file="$1" kind="$2" pid
  pid="$(read_numeric_pid "$file")" || return 0
  [ "$pid" = "$$" ] && return 0
  pid_matches_kind "$pid" "$kind" || return 0
  kill "$pid" 2>/dev/null || true
}

wait_pid_exit_once() {
  local pid="$1" kind="$2" i=0
  while pid_matches_kind "$pid" "$kind" && [ "$i" -lt 20 ]; do
    # 僅用於安裝／取代舊實例，並非常駐輪詢。
    sleep 0.05
    i=$((i + 1))
  done
  if pid_matches_kind "$pid" "$kind"; then
    kill -9 "$pid" 2>/dev/null || true
  fi
}

replace_existing() {
  local old_pid native_pid

  [ -d "$LOCK" ] || return 0

  native_pid="$(read_numeric_pid "$NETWATCH_PIDFILE")"
  terminate_pid_file "$NETWATCH_PIDFILE" netwatch

  # 相容清理由 v0.3.1～v0.3.3 留下的 ip monitor PID。
  terminate_pid_file "$LOCK/link_monitor_pid" old_monitor
  terminate_pid_file "$LOCK/address_monitor_pid" old_monitor
  terminate_pid_file "$LOCK/monitor_pid" old_monitor

  old_pid="$(read_numeric_pid "$PIDFILE")"
  if [ -n "$old_pid" ] && [ "$old_pid" != "$$" ] &&
     pid_matches_kind "$old_pid" watcher; then
    kill "$old_pid" 2>/dev/null || true
    wait_pid_exit_once "$old_pid" watcher
  fi

  [ -n "$native_pid" ] && wait_pid_exit_once "$native_pid" netwatch
  rm -rf "$LOCK" 2>/dev/null
}

if [ "$1" = "--replace" ]; then
  replace_existing
elif [ -d "$LOCK" ]; then
  old_pid="$(read_numeric_pid "$PIDFILE")"
  if [ -n "$old_pid" ] && pid_matches_kind "$old_pid" watcher; then
    exit 0
  fi
  rm -rf "$LOCK" 2>/dev/null
fi

mkdir "$LOCK" 2>/dev/null || exit 0
printf '%s\n' "$$" > "$PIDFILE" 2>/dev/null

cleanup() {
  local native_pid
  native_pid="$(read_numeric_pid "$NETWATCH_PIDFILE")"
  terminate_pid_file "$NETWATCH_PIDFILE" netwatch
  [ -n "$native_pid" ] && wait "$native_pid" 2>/dev/null || true

  # 只有目前 lock 仍屬於自己時才移除，避免舊 watcher 誤刪新版 lock。
  if [ "$(cat "$PIDFILE" 2>/dev/null)" = "$$" ]; then
    rm -rf "$LOCK" 2>/dev/null
  fi
}
trap cleanup EXIT INT TERM HUP

event_ifname() {
  local event="$1" name
  case "$event" in
    LINK_NEW\ *|LINK_DEL\ *|ADDR_NEW\ *|ADDR_DEL\ *) ;;
    *) return 1 ;;
  esac
  case "$event" in
    *" ifname="*)
      name=${event#* ifname=}
      name=${name%% *}
      ;;
    *) return 1 ;;
  esac
  [ -n "$name" ] || return 1
  printf '%s' "$name"
}

is_lan_candidate_iface() {
  local iface=${1%%@*}

  # 明確排除行動數據、VPN、虛擬/隧道與 Wi-Fi Aware/P2P。
  case "$iface" in
    lo|rmnet*|r_rmnet*|ccmni*|pdp*|wwan*|cell*|tun*|tap*|wg*|wireguard*|tailscale*|zt*|clat*|v4-*|dummy*|ifb*|ip6tnl*|sit*|gre*|gretap*|wifi-aware*|aware*|p2p*)
      return 1
      ;;
  esac

  case "$iface" in
    wlan*|wifi*|mlan*|eth*|en*|ap*|swlan*|softap*|rndis*|usb*|bnep*|bt-pan*|br*|bond*)
      return 0
      ;;
  esac

  # 廠商自訂 Wi-Fi 介面名稱。
  [ -d "/sys/class/net/$iface/wireless" ]
}

event_is_relevant() {
  local event="$1" iface
  iface="$(event_ifname "$event")" || return 1
  is_lan_candidate_iface "$iface"
}

# No timer: retries are considered only when a relevant kernel event arrives.
failed_start_key=''
failed_start_count=0
failed_start_time=0
allow_event_start() {
  local key now rest
  key="$current|$(cksum < "$CFG" 2>/dev/null)"
  read -r now rest < /proc/uptime
  now=${now%%.*}
  if [ "$key" != "$failed_start_key" ]; then
    failed_start_key="$key"; failed_start_count=0; failed_start_time=0
  fi
  [ "$failed_start_count" -ge 3 ] && return 1
  if [ "$failed_start_count" -gt 0 ] && [ $((now - failed_start_time)) -lt 30 ]; then return 1; fi
  failed_start_count=$((failed_start_count + 1))
  failed_start_time=$now
  return 0
}

reconcile_network() {
  local reason="$1" current last was_waiting

  [ "$(cat "$PIDFILE" 2>/dev/null)" = "$$" ] || return 1
  [ -f "$CFG" ] || return 0

  . "$CFG"
  was_waiting=0
  [ -f "$RUNTIME/waiting_network" ] && was_waiting=1

  if [ "${ENABLED:-0}" != "1" ]; then
    rm -f "$RUNTIME/waiting_network" "$RUNTIME/interface_key" 2>/dev/null
    if [ "$reason" = "initial" ]; then
      sh "$CONTROL" refresh_card >/dev/null 2>&1
      log_watch INFO DISABLED "ENABLED=0；native netwatch 保持阻塞等待"
    fi
    return 0
  fi

  current="$(sh "$CONTROL" interface_key 2>/dev/null)"
  last="$(cat "$RUNTIME/interface_key" 2>/dev/null)"

  if [ -z "$current" ]; then
    failed_start_key=""; failed_start_count=0
    if sh "$CONTROL" is_running >/dev/null 2>&1; then
      if sh "$CONTROL" suspend_network >/dev/null 2>&1; then
        log_watch WARN LAN_LOST "可信任 LAN 消失，已暫停 smbd；event=$reason"
        notify_watch event "SMB 伺服器" "已離開區域網路，SMB 伺服器已停止" "可信任區域網路已離線，SMB 伺服器已自動停止並等待網路恢復。"
      else
        log_watch ERROR LAN_LOST_STOP_FAIL "可信任 LAN 消失，但停止 smbd 失敗；event=$reason"
        notify_watch error "SMB 伺服器停止失敗" "已離開區域網路，但 SMB 伺服器停止失敗" "可信任區域網路已離線，但 smbd 停止流程失敗。請查看模組日誌。"
      fi
    elif [ "$was_waiting" != "1" ]; then
      touch "$RUNTIME/waiting_network" 2>/dev/null
      rm -f "$RUNTIME/interface_key" 2>/dev/null
      sh "$CONTROL" refresh_card >/dev/null 2>&1
      log_watch WARN LAN_WAIT "未偵測到可信任 LAN；保持等待；event=$reason"
    fi
    return 0
  fi

  if ! sh "$CONTROL" is_running >/dev/null 2>&1; then
    allow_event_start || return 0
    rm -f "$RUNTIME/waiting_network" 2>/dev/null
    if sh "$CONTROL" start >/dev/null 2>&1; then
      failed_start_count=0
      log_watch INFO LAN_READY "可信任 LAN 已就緒，已啟動 smbd：$current；event=$reason"
      notify_start_success "$current"
    else
      log_watch ERROR START_FAIL "偵測到 LAN，但 smbd 啟動失敗：$current；event=$reason"
      notify_start_failure "$current"
    fi
  elif [ "$current" != "$last" ]; then
    if sh "$CONTROL" restart >/dev/null 2>&1; then
      log_watch INFO LAN_CHANGED "LAN 介面或位址改變，已重新綁定 smbd：$current；event=$reason"
    else
      log_watch ERROR REBIND_FAIL "LAN 改變，但 smbd 重綁失敗：$current；event=$reason"
      notify_watch error "SMB 伺服器重綁失敗" "區域網路位址已變更，但 SMB 重綁失敗" "新的區域網路狀態：$current。請查看模組日誌。"
    fi
  elif [ "$reason" = "initial" ]; then
    rm -f "$RUNTIME/waiting_network" 2>/dev/null
    sh "$CONTROL" refresh_card >/dev/null 2>&1
    log_watch INFO LAN_STABLE "可信任 LAN 已穩定：$current"
    if boot_notify_pending; then
      notify_watch success "SMB 伺服器" "開機自啟動成功：$current" "Android 開機完成後，SMB 伺服器已在可信任區域網路運行：$current"
      consume_boot_notify_pending
    fi
  fi
}

if [ ! -x "$NETWATCH" ]; then
  log_watch ERROR MONITOR_INIT "缺少原生 netwatch：$NETWATCH"
  exit 1
fi

netwatch_version="$("$NETWATCH" --version 2>&1 | head -n 1)"
case "$netwatch_version" in
  netwatch\ *) ;;
  *)
    log_watch ERROR MONITOR_INIT "netwatch 自我檢查失敗：$netwatch_version"
    exit 1
    ;;
esac

log_watch INFO WATCHER_START "原生 rtnetlink watcher 啟動；replace=$([ "$1" = "--replace" ] && echo 1 || echo 0)；version=$netwatch_version"
log_watch INFO LAN_SCAN "all=$(sh "$CONTROL" diagnose 2>/dev/null | sed -n '/\[解析後 IPv4\]/,/^$/p' | tr '\n' ';') trusted=$(sh "$CONTROL" trusted_lan 2>/dev/null | tr '\n' ';')"

# 啟動時立即同步一次，之後完全由 kernel NETLINK_ROUTE 事件驅動。
reconcile_network initial

FIFO="$LOCK/netlink.events"
rm -f "$FIFO" 2>/dev/null
mkfifo "$FIFO" 2>/dev/null || {
  log_watch ERROR MONITOR_INIT "建立 netlink FIFO 失敗"
  exit 1
}

"$NETWATCH" > "$FIFO" 2>> "$WATCH_LOG" &
native_pid=$!
printf '%s\n' "$native_pid" > "$NETWATCH_PIDFILE" 2>/dev/null

# 與原生 writer 配對後阻塞讀取；沒有事件時 shell 與 netwatch 都不輪詢。
exec 3< "$FIFO"
log_watch INFO MONITOR_READY "native_pid=$native_pid；version=$netwatch_version"

while IFS= read -r event <&3; do
  [ -n "$event" ] || continue

  # rmnet/VPN/Wi-Fi Aware 等事件直接忽略，不寫日誌、不重新掃描 LAN。
  event_is_relevant "$event" || continue
  reconcile_network "$event"
done

wait "$native_pid" 2>/dev/null
rc=$?
log_watch ERROR MONITOR_EXIT "原生 netwatch 已結束；pid=$native_pid rc=$rc"
exit 1
