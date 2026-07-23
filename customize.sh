# shellcheck disable=SC2034
SKIPUNZIP=1

MODID=smbdwebui
LIVE_MODPATH="/data/adb/modules/$MODID"
DATA_DIR="/data/adb/smbdwebui"
CFG="$DATA_DIR/config.conf"
INSTALL_LOG="$DATA_DIR/runtime/log/module.log"

mkdir -p "$DATA_DIR/runtime/log" 2>/dev/null
log_install() {
  printf '%s pid=%s component=install level=%s stage=%s %s\n'     "$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null)" "$$" "$1" "$2" "$3"     >> "$INSTALL_LOG" 2>/dev/null
}
log_install INFO INSTALL_START "開始安裝/熱更新"
ui_print "- Installing Android SMB Server WebUI"
ui_print "- ARCH=$ARCH API=$API"
if [ "$ARCH" != "arm64" ]; then
  abort "! This build currently includes arm64-v8a smbd only"
fi

stop_old_network_watcher() {
  local lock="$DATA_DIR/runtime/network_watch.lock" file pid cmd exe i

  [ -d "$lock" ] || return 0

  for file in \
    "$lock/netwatch_pid" \
    "$lock/link_monitor_pid" \
    "$lock/address_monitor_pid" \
    "$lock/monitor_pid"; do
    pid="$(cat "$file" 2>/dev/null)"
    case "$pid" in ''|*[!0-9]*) continue ;; esac
    cmd="$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null)"
    exe="$(readlink "/proc/$pid/exe" 2>/dev/null)"
    case "$cmd:$exe" in
      *"/bin/netwatch"*|*"ip"*"monitor"*|*"/netwatch") kill "$pid" 2>/dev/null ;;
    esac
  done

  pid="$(cat "$lock/pid" 2>/dev/null)"
  case "$pid" in
    ''|*[!0-9]*) ;;
    *)
      cmd="$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null)"
      case "$cmd" in
        *network_watch.sh*)
          kill "$pid" 2>/dev/null
          i=0
          while [ -d "/proc/$pid" ] && [ "$i" -lt 20 ]; do
            sleep 0.05
            i=$((i + 1))
          done
          [ -d "/proc/$pid" ] && kill -9 "$pid" 2>/dev/null
          ;;
      esac
      ;;
  esac

  rm -rf "$lock" 2>/dev/null
}

log_install INFO WATCHER_STOP "停止更新前的舊 network watcher"
stop_old_network_watcher

# 記住更新前狀態。停止舊服務後會暫時把 ENABLED 寫成 0，
# 所以另外保存原值，更新完成後再恢復。
WAS_RUNNING=0
OLD_ENABLED=0
OLD_AUTO_START=0
if [ -f "$CFG" ]; then
  OLD_ENABLED="$(sed -n 's/^ENABLED=//p' "$CFG" 2>/dev/null | tail -n 1)"
  OLD_AUTO_START="$(sed -n 's/^AUTO_START=//p' "$CFG" 2>/dev/null | tail -n 1)"
fi
case "$OLD_ENABLED" in 1) ;; *) OLD_ENABLED=0 ;; esac
case "$OLD_AUTO_START" in 1) ;; *) OLD_AUTO_START=0 ;; esac

if [ -x "$LIVE_MODPATH/control.sh" ] &&
   sh "$LIVE_MODPATH/control.sh" is_running >/dev/null 2>&1; then
  WAS_RUNNING=1
  ui_print "- Stopping current smbd instance for live update"
  sh "$LIVE_MODPATH/control.sh" stop >/dev/null 2>&1
fi

log_install INFO EXTRACT "開始解壓模組檔案"
ui_print "- Extracting module files"
unzip -o "$ZIPFILE" 'module.prop' -d "$MODPATH" >&2
unzip -o "$ZIPFILE" 'service.sh' 'network_watch.sh' 'notify.sh' 'diagnose.sh' 'action.sh' 'uninstall.sh' 'control.sh' 'README.md' 'sha256sum.txt' -d "$MODPATH" >&2
mkdir -p "$MODPATH/bin" "$MODPATH/webroot"
unzip -o "$ZIPFILE" 'bin/*' 'webroot/*' -d "$MODPATH" >&2
touch "$MODPATH/skip_mount"

log_install INFO CONFIG "準備設定目錄"
ui_print "- Preparing config directory"
mkdir -p "$DATA_DIR"
if [ ! -f "$CFG" ]; then
  cat > "$CFG" <<'EOF'
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
EOF
fi

# 恢復更新前的自啟/執行意圖。
sed -i "s/^AUTO_START=.*/AUTO_START=$OLD_AUTO_START/" "$CFG" 2>/dev/null
sed -i "s/^ENABLED=.*/ENABLED=$OLD_ENABLED/" "$CFG" 2>/dev/null

log_install INFO PERMISSION "設定 staged 權限"
ui_print "- Setting staged module permissions"
set_perm_recursive "$MODPATH" 0 0 0755 0644
set_perm "$MODPATH/bin/smbd" 0 0 0755
set_perm "$MODPATH/bin/ntlmhash" 0 0 0755
set_perm "$MODPATH/bin/netwatch" 0 0 0755
set_perm "$MODPATH/bin/propwait" 0 0 0755
set_perm "$MODPATH/control.sh" 0 0 0755
set_perm "$MODPATH/action.sh" 0 0 0755
set_perm "$MODPATH/service.sh" 0 0 0755
set_perm "$MODPATH/network_watch.sh" 0 0 0755
set_perm "$MODPATH/notify.sh" 0 0 0755
set_perm "$MODPATH/diagnose.sh" 0 0 0755
set_perm "$MODPATH/uninstall.sh" 0 0 0755

# 此模組沒有 system overlay，只是 /data/adb 下的 daemon + WebUI。
# 將本次安裝內容同步到正式模組目錄後即可立即使用，不必等待重啟掛載。
if [ "$MODPATH" != "$LIVE_MODPATH" ]; then
  log_install INFO LIVE_ACTIVATE "同步到正式模組目錄"
  ui_print "- Activating module immediately (no reboot required)"
  mkdir -p "$LIVE_MODPATH"

  # 移除上一版程式與 WebUI，設定保存在獨立 DATA_DIR，不會被清掉。
  rm -rf "$LIVE_MODPATH/bin" "$LIVE_MODPATH/webroot"
  rm -f "$LIVE_MODPATH/module.prop"         "$LIVE_MODPATH/control.sh"         "$LIVE_MODPATH/action.sh"         "$LIVE_MODPATH/service.sh"         "$LIVE_MODPATH/network_watch.sh"         "$LIVE_MODPATH/notify.sh"         "$LIVE_MODPATH/diagnose.sh"         "$LIVE_MODPATH/uninstall.sh"         "$LIVE_MODPATH/README.md"         "$LIVE_MODPATH/sha256sum.txt"         "$LIVE_MODPATH/skip_mount"

  cp -af "$MODPATH/." "$LIVE_MODPATH/" || abort "! Failed to activate live module"

  set_perm_recursive "$LIVE_MODPATH" 0 0 0755 0644
  set_perm "$LIVE_MODPATH/bin/smbd" 0 0 0755
  set_perm "$LIVE_MODPATH/bin/ntlmhash" 0 0 0755
  set_perm "$LIVE_MODPATH/bin/netwatch" 0 0 0755
  set_perm "$LIVE_MODPATH/bin/propwait" 0 0 0755
  set_perm "$LIVE_MODPATH/control.sh" 0 0 0755
  set_perm "$LIVE_MODPATH/action.sh" 0 0 0755
  set_perm "$LIVE_MODPATH/service.sh" 0 0 0755
  set_perm "$LIVE_MODPATH/network_watch.sh" 0 0 0755
  set_perm "$LIVE_MODPATH/notify.sh" 0 0 0755
  [ -f "$LIVE_MODPATH/bin/smbnotify.dex" ] && set_perm "$LIVE_MODPATH/bin/smbnotify.dex" 0 0 0644
  set_perm "$LIVE_MODPATH/diagnose.sh" 0 0 0755
  set_perm "$LIVE_MODPATH/uninstall.sh" 0 0 0755
fi

# 使用正式模組目錄即時刷新狀態；更新前正在執行或設定為啟用/自啟時，
# 立即用新版重新啟動。
ACTIVE_CONTROL="$LIVE_MODPATH/control.sh"
if [ "$MODPATH" = "$LIVE_MODPATH" ]; then
  ACTIVE_CONTROL="$MODPATH/control.sh"
fi

if [ -x "$ACTIVE_CONTROL" ]; then
  sh "$ACTIVE_CONTROL" clean_stderr >/dev/null 2>&1 || true
  log_install INFO LOG_CLEAN "已清理舊版 Samba 預設路徑警告"

  if [ "$WAS_RUNNING" = "1" ] ||
     [ "$OLD_ENABLED" = "1" ] ||
     [ "$OLD_AUTO_START" = "1" ]; then
    LAN_KEY="$(sh "$ACTIVE_CONTROL" interface_key 2>/dev/null)"
    log_install INFO LAN_GATE "trusted_lan=$LAN_KEY"
    if [ -n "$LAN_KEY" ]; then
      ui_print "- Starting smbd on trusted LAN"
      sh "$ACTIVE_CONTROL" start >/dev/null 2>&1 || ui_print "! Immediate start failed; check WebUI log"
    else
      ui_print "- No trusted LAN; waiting for Wi-Fi/Ethernet"
      mkdir -p "$DATA_DIR/runtime" 2>/dev/null
      touch "$DATA_DIR/runtime/waiting_network" 2>/dev/null
      sed -i 's/^ENABLED=.*/ENABLED=1/' "$CFG" 2>/dev/null
      sh "$ACTIVE_CONTROL" refresh_card >/dev/null 2>&1
    fi
  else
    sh "$ACTIVE_CONTROL" refresh_card >/dev/null 2>&1
  fi
fi

ACTIVE_MODDIR="$LIVE_MODPATH"
[ "$MODPATH" = "$LIVE_MODPATH" ] && ACTIVE_MODDIR="$MODPATH"

if [ -x "$ACTIVE_MODDIR/bin/propwait" ]; then
  PROPWAIT_VERSION="$("$ACTIVE_MODDIR/bin/propwait" --version 2>&1 | head -n 1)"
  BOOT_VALUE="$(getprop sys.boot_completed 2>/dev/null)"
  log_install INFO PROPWAIT_READY "$PROPWAIT_VERSION；boot_completed=$BOOT_VALUE"
  ui_print "- Native propwait ready: $PROPWAIT_VERSION"
  if [ -n "$BOOT_VALUE" ]; then
    if "$ACTIVE_MODDIR/bin/propwait" equals sys.boot_completed "$BOOT_VALUE" >/dev/null 2>&1; then
      log_install INFO PROPWAIT_SELFTEST "即時命中測試通過"
    else
      log_install WARN PROPWAIT_SELFTEST "即時命中測試失敗；開機時將使用 fallback"
      ui_print "! propwait self-test failed; boot fallback remains available"
    fi
  fi
else
  log_install ERROR PROPWAIT_MISSING "bin/propwait 缺失"
  ui_print "! Native propwait missing; boot fallback will be used"
fi

rm -rf "$ACTIVE_MODDIR/logs" 2>/dev/null
ln -s "$DATA_DIR/runtime/log" "$ACTIVE_MODDIR/logs" 2>/dev/null
log_install INFO LOG_LINK "建立 logs -> $DATA_DIR/runtime/log"

if [ -x "$ACTIVE_MODDIR/network_watch.sh" ] &&
   [ -x "$ACTIVE_MODDIR/bin/netwatch" ]; then
  NETWATCH_VERSION="$("$ACTIVE_MODDIR/bin/netwatch" --version 2>&1 | head -n 1)"
  log_install INFO WATCHER_START "啟動原生 rtnetlink watcher；$NETWATCH_VERSION"
  ui_print "- Starting native netwatch"
  sh "$ACTIVE_MODDIR/network_watch.sh" --replace >/dev/null 2>&1 &
else
  log_install ERROR WATCHER_MISSING "network_watch.sh 或 bin/netwatch 缺失"
  ui_print "! Native netwatch missing; automatic LAN recovery unavailable"
fi

log_install INFO INSTALL_DONE "安裝/熱更新完成"
ui_print "- Done"
ui_print "- Reopen the module page to use WebUI immediately"
ui_print "- Reboot is not required for this module"
ui_print "- The module manager itself may still show a generic reboot prompt"
