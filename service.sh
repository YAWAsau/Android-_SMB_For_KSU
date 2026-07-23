#!/system/bin/sh
MODDIR=${0%/*}
CFG=/data/adb/smbdwebui/config.conf
RUNTIME=/data/adb/smbdwebui/runtime
LOGDIR="$RUNTIME/log"
MODULE_LOG="$LOGDIR/module.log"
CONTROL="$MODDIR/control.sh"
WATCHER="$MODDIR/network_watch.sh"
NETWATCH="$MODDIR/bin/netwatch"
PROPWAIT="$MODDIR/bin/propwait"
NOTIFY="$MODDIR/notify.sh"
BOOT_NOTIFY_PENDING="$RUNTIME/boot_notify_pending"

mkdir -p "$RUNTIME" "$LOGDIR" 2>/dev/null

log_service() {
  printf '%s pid=%s component=service level=%s stage=%s %s\n' \
    "$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null)" "$$" "$1" "$2" "$3" \
    >> "$MODULE_LOG" 2>/dev/null
}

log_service INFO BOOT_START "service.sh 開始"

# 只在開機階段等待 Android 完成。
# 優先使用 native propwait 阻塞在 bionic property futex；120 秒 watchdog
# 只是一顆一次性 sleep，不是週期輪詢。若工具缺失或執行失敗，才退回舊流程。
wait_boot_completed() {
  local current prop_pid guard_pid rc i version

  current="$(getprop sys.boot_completed 2>/dev/null)"
  if [ "$current" = "1" ]; then
    log_service INFO BOOT_ALREADY_READY "sys.boot_completed 已為 1，不需等待"
    return 0
  fi

  if [ -x "$PROPWAIT" ]; then
    version="$("$PROPWAIT" --version 2>&1 | head -n 1)"
    log_service INFO PROPWAIT_START "使用 native property wait；$version；timeout=120s"

    "$PROPWAIT" equals sys.boot_completed 1 >/dev/null 2>&1 &
    prop_pid=$!

    (
      sleep 120
      kill "$prop_pid" 2>/dev/null
      sleep 1
      [ -d "/proc/$prop_pid" ] && kill -9 "$prop_pid" 2>/dev/null
    ) &
    guard_pid=$!

    wait "$prop_pid" 2>/dev/null
    rc=$?
    kill "$guard_pid" 2>/dev/null
    wait "$guard_pid" 2>/dev/null

    current="$(getprop sys.boot_completed 2>/dev/null)"
    if [ "$current" = "1" ]; then
      log_service INFO PROPWAIT_DONE "native property wait 完成 rc=$rc"
      return 0
    fi

    log_service WARN PROPWAIT_FALLBACK "native property wait 未等到完成 rc=$rc value=$current；回退有限輪詢"
  else
    log_service WARN PROPWAIT_MISSING "缺少 bin/propwait；回退有限輪詢"
  fi

  i=0
  while [ "$(getprop sys.boot_completed 2>/dev/null)" != "1" ] && [ "$i" -lt 120 ]; do
    sleep 1
    i=$((i + 1))
  done

  current="$(getprop sys.boot_completed 2>/dev/null)"
  if [ "$current" = "1" ]; then
    log_service INFO BOOT_FALLBACK_DONE "有限輪詢完成 iterations=$i"
    return 0
  fi

  log_service WARN BOOT_WAIT_TIMEOUT "等待 120 秒後仍未完成；繼續啟動流程 value=$current"
  return 1
}

wait_boot_completed

[ -f "$CFG" ] && . "$CFG"
log_service INFO BOOT_READY "boot_completed=$(getprop sys.boot_completed 2>/dev/null) auto_start=${AUTO_START:-0} enabled=${ENABLED:-0}"

if [ "${AUTO_START:-0}" = "1" ] || [ "${ENABLED:-0}" = "1" ]; then
  sed -i 's/^ENABLED=.*/ENABLED=1/' "$CFG" 2>/dev/null
  printf '%s\n' "$(cat /proc/sys/kernel/random/boot_id 2>/dev/null)" > "$BOOT_NOTIFY_PENDING" 2>/dev/null
  log_service INFO ENABLE_INTENT "保留 SMB 啟用／自啟意圖；建立開機通知 pending"
else
  rm -f "$RUNTIME/waiting_network" "$BOOT_NOTIFY_PENDING" 2>/dev/null
  sh "$CONTROL" refresh_card >/dev/null 2>&1
  log_service INFO BOOT_DISABLED "自啟與啟用意圖均為關閉"
fi

if [ -x "$WATCHER" ] && [ -x "$NETWATCH" ]; then
  version="$("$NETWATCH" --version 2>&1 | head -n 1)"
  sh "$WATCHER" --replace >/dev/null 2>&1 &
  watcher_pid=$!
  log_service INFO WATCHER_START "network_watch.sh --replace 已啟動 pid=$watcher_pid；$version"
else
  log_service ERROR WATCHER_MISSING "缺少 network_watch.sh 或 bin/netwatch；只執行一次 LAN 同步"

  # 封裝異常時不使用輪詢；只對當下狀態做一次處理。
  [ -f "$CFG" ] && . "$CFG"
  if [ "${ENABLED:-0}" = "1" ]; then
    key="$(sh "$CONTROL" interface_key 2>/dev/null)"
    if [ -n "$key" ]; then
      if sh "$CONTROL" start >/dev/null 2>&1; then
        log_service INFO ONE_SHOT_START "一次性啟動 smbd；trusted_lan=$key rc=0"
        [ -x "$NOTIFY" ] && sh "$NOTIFY" event success "SMB 伺服器" "開機自啟動成功：$key" "network watcher 缺失時的一次性 fallback 啟動成功：$key" >/dev/null 2>&1 || true
        rm -f "$BOOT_NOTIFY_PENDING" 2>/dev/null
      else
        rc=$?
        log_service ERROR ONE_SHOT_START_FAIL "一次性啟動 smbd 失敗；trusted_lan=$key rc=$rc"
        [ -x "$NOTIFY" ] && sh "$NOTIFY" event error "SMB 伺服器啟動失敗" "開機自啟動失敗：$key" "network watcher 缺失，且一次性 fallback 啟動失敗。請查看模組日誌。" >/dev/null 2>&1 || true
        rm -f "$BOOT_NOTIFY_PENDING" 2>/dev/null
      fi
    else
      touch "$RUNTIME/waiting_network" 2>/dev/null
      sh "$CONTROL" refresh_card >/dev/null 2>&1
      log_service WARN LAN_WAIT "一次性檢查未找到可信任 LAN；不啟用 fallback 輪詢"
    fi
  fi
fi
