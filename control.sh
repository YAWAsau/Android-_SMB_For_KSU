#!/system/bin/sh
MODDIR=${0%/*}
ID=smbdwebui
DATA_DIR=/data/adb/smbdwebui
CFG=$DATA_DIR/config.conf
RUNTIME=$DATA_DIR/runtime
LOGDIR=$RUNTIME/log
LOCKDIR=$RUNTIME/lock
STATEDIR=$RUNTIME/state
CACHEDIR=$RUNTIME/cache
PRIVATEDIR=$RUNTIME/private
PIDDIR=$RUNTIME/run
CONF=$RUNTIME/smb.conf
SMBD=$MODDIR/bin/smbd
NTLMHASH=$MODDIR/bin/ntlmhash
NETWATCH=$MODDIR/bin/netwatch
PASSDB=$PRIVATEDIR/smbpasswd
USERMAP=$PRIVATEDIR/username.map
DEFAULT_PATH=/sdcard/SpeedBackup
MODULE_LOG=$LOGDIR/module.log
MODULE_LOG_OLD=$LOGDIR/module.log.1

mkdir -p "$DATA_DIR" 2>/dev/null

rotate_module_log() {
  local size
  [ -f "$MODULE_LOG" ] || return 0
  size=$(wc -c < "$MODULE_LOG" 2>/dev/null)
  case "$size" in ''|*[!0-9]*) return 0 ;; esac
  if [ "$size" -ge 1048576 ]; then
    rm -f "$MODULE_LOG_OLD" 2>/dev/null
    mv "$MODULE_LOG" "$MODULE_LOG_OLD" 2>/dev/null
  fi
}

log_module() {
  local level="$1" stage="$2"
  shift 2
  mkdir -p "$LOGDIR" 2>/dev/null
  rotate_module_log
  printf '%s pid=%s component=control level=%s stage=%s %s\n'     "$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null)" "$$" "$level" "$stage" "$*"     >> "$MODULE_LOG" 2>/dev/null
}

init_config() {
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
}

load_config() {
  init_config
  . "$CFG"
  AUTO_START=${AUTO_START:-0}
  ENABLED=${ENABLED:-0}
  SHARE_PATH=${SHARE_PATH:-$DEFAULT_PATH}
  SHARE_NAME=${SHARE_NAME:-SpeedBackup}
  READ_ONLY=${READ_ONLY:-0}
  MIN_PROTOCOL=${MIN_PROTOCOL:-SMB2_02}
  MAX_PROTOCOL=${MAX_PROTOCOL:-SMB3}
  BIND_INTERFACES=${BIND_INTERFACES:-1}
  INTERFACES_AUTO=${INTERFACES_AUTO:-1}
  EXTRA_INTERFACES=${EXTRA_INTERFACES:-}
  PORT=${PORT:-445}
  NETBIOS_NAME=${NETBIOS_NAME:-ANDROIDSMB}
  WORKGROUP=${WORKGROUP:-WORKGROUP}
  AUTH_MODE=${AUTH_MODE:-guest}
  case "$AUTH_MODE" in guest|user) ;; *) AUTH_MODE=guest ;; esac
  SMB_USERNAME=${SMB_USERNAME:-speedbackup}
}

write_config() {
  umask 077
  cat > "$CFG" <<EOF
AUTO_START=$AUTO_START
ENABLED=$ENABLED
SHARE_PATH=$SHARE_PATH
SHARE_NAME=$SHARE_NAME
READ_ONLY=$READ_ONLY
MIN_PROTOCOL=$MIN_PROTOCOL
MAX_PROTOCOL=$MAX_PROTOCOL
BIND_INTERFACES=$BIND_INTERFACES
INTERFACES_AUTO=$INTERFACES_AUTO
EXTRA_INTERFACES=$EXTRA_INTERFACES
PORT=$PORT
NETBIOS_NAME=$NETBIOS_NAME
WORKGROUP=$WORKGROUP
AUTH_MODE=$AUTH_MODE
SMB_USERNAME=$SMB_USERNAME
EOF
}

json_escape() {
  printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g; s/\t/\\t/g; s/\r//g; s/$/\\n/' | tr -d '\n' | sed 's/\\n$//'
}

shell_escape_value() {
  # Keep config as simple key=value, reject newlines/control chars.
  printf '%s' "$1" | tr -d '\r\n'
}

valid_share_name() {
  case "$1" in
    ''|*[\[\]/\\:\*\?\"\<\>\|]*) return 1 ;;
  esac
  return 0
}

valid_smb_username() {
  case "$1" in
    ''|*[!A-Za-z0-9._-]*) return 1 ;;
  esac
  [ "${#1}" -le 32 ]
}

password_set() {
  [ -s "$PASSDB" ] && grep -q '^root:0:' "$PASSDB" 2>/dev/null
}


cached_status_line() {
  # WebUI status polling is frequent.  Do not spawn heavy version commands every poll.
  # The module binaries are immutable for a given module version, so cache first line.
  local key="$1" out tmp
  shift
  mkdir -p "$CACHEDIR" 2>/dev/null
  out="$CACHEDIR/$key"
  if [ -s "$out" ]; then
    head -n 1 "$out" 2>/dev/null
    return 0
  fi
  tmp="$out.tmp.$$"
  "$@" 2>/dev/null | head -n 1 > "$tmp" 2>/dev/null || true
  if [ -s "$tmp" ]; then
    mv "$tmp" "$out" 2>/dev/null || true
    head -n 1 "$out" 2>/dev/null
  else
    rm -f "$tmp" 2>/dev/null
  fi
}

auth_label() {
  if [ "$AUTH_MODE" = "user" ]; then
    printf '帳號密碼 (%s)' "$SMB_USERNAME"
  else
    printf 'Guest / 匿名'
  fi
}

write_username_map() {
  valid_smb_username "$SMB_USERNAME" || return 1
  umask 077
  printf '!root = %s\n' "$SMB_USERNAME" > "$USERMAP.tmp.$$" || return 1
  mv "$USERMAP.tmp.$$" "$USERMAP" || return 1
  chmod 600 "$USERMAP" 2>/dev/null
}

set_password_hex() {
  local hex="$1" hash now_hex tmp
  load_config
  make_dirs
  if [ ! -x "$NTLMHASH" ]; then
    echo "缺少 NTLM 密碼雜湊工具: $NTLMHASH" >&2
    return 1
  fi
  case "$hex" in
    ''|*[!0-9A-Fa-f]*) echo "密碼資料格式錯誤" >&2; return 1 ;;
  esac
  [ $(( ${#hex} % 2 )) -eq 0 ] || { echo "密碼資料長度錯誤" >&2; return 1; }
  [ "${#hex}" -le 2048 ] || { echo "密碼過長" >&2; return 1; }
  hash="$($NTLMHASH "$hex" 2>/dev/null)" || {
    echo "密碼雜湊建立失敗" >&2
    return 1
  }
  case "$hash" in
    [0-9A-F][0-9A-F][0-9A-F][0-9A-F][0-9A-F][0-9A-F][0-9A-F][0-9A-F][0-9A-F][0-9A-F][0-9A-F][0-9A-F][0-9A-F][0-9A-F][0-9A-F][0-9A-F][0-9A-F][0-9A-F][0-9A-F][0-9A-F][0-9A-F][0-9A-F][0-9A-F][0-9A-F][0-9A-F][0-9A-F][0-9A-F][0-9A-F][0-9A-F][0-9A-F][0-9A-F][0-9A-F]) ;;
    *) echo "密碼雜湊格式錯誤" >&2; return 1 ;;
  esac
  now_hex="$(printf '%08X' "$(date +%s 2>/dev/null)" 2>/dev/null)"
  [ -n "$now_hex" ] || now_hex=00000000
  tmp="$PASSDB.tmp.$$"
  umask 077
  printf 'root:0:XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX:%s:[U          ]:LCT-%s:\n' "$hash" "$now_hex" > "$tmp" || return 1
  mv "$tmp" "$PASSDB" || return 1
  chmod 600 "$PASSDB" 2>/dev/null
  write_username_map || return 1
  if [ "$AUTH_MODE" = "user" ] && is_running; then
    restart_server >/dev/null || return 1
    log_module INFO PASSWORD "密碼 NT Hash 已更新；服務已重啟"
    echo "密碼已更新，SMB 服務已重啟"
  elif [ "$AUTH_MODE" = "user" ] && [ -f "$RUNTIME/pending_auth_start" ]; then
    rm -f "$RUNTIME/pending_auth_start" 2>/dev/null
    start_server >/dev/null || return 1
    log_module INFO PASSWORD "密碼 NT Hash 已設定；等待中的服務已啟動"
    echo "密碼已設定，SMB 服務已啟動"
  else
    module_prop_update_status
    log_module INFO PASSWORD "密碼 NT Hash 已設定；未自動啟動服務"
    echo "密碼已設定"
  fi
}

sanitize_protocol() {
  case "$1" in
    NT1|SMB2|SMB2_02|SMB2_10|SMB3|SMB3_00|SMB3_02|SMB3_10|SMB3_11) printf '%s' "$1" ;;
    *) printf '%s' "SMB2_02" ;;
  esac
}

own_ip4_records() {
  # Android 裝置上的 ip 可能是 toybox 或 iproute2。
  # 不使用部分版本不相容的「show scope global」，改抓全部 IPv4 後自行篩選。
  local raw
  if command -v ip >/dev/null 2>&1; then
    raw="$(ip -o -4 addr show 2>/dev/null)"
    if [ -n "$raw" ]; then
      printf '%s\n' "$raw" | awk '
        $3 == "inet" {
          iface=$2
          sub(/@.*/, "", iface)
          cidr=$4
          if (iface != "" && cidr ~ /^[0-9]+\./ &&
              cidr !~ /^127\./ && cidr !~ /^0\./ &&
              cidr !~ /^169\.254\./) {
            print iface, cidr
          }
        }
      '
      return
    fi

    # 某些精簡 ip 不支援 -o，改解析一般格式。
    ip -4 addr show 2>/dev/null | awk '
      /^[0-9]+:/ {
        iface=$2
        sub(/:$/, "", iface)
        sub(/@.*/, "", iface)
      }
      /^[[:space:]]+inet[[:space:]]/ {
        cidr=$2
        if (iface != "" && cidr ~ /^[0-9]+\./ &&
            cidr !~ /^127\./ && cidr !~ /^0\./ &&
            cidr !~ /^169\.254\./) {
          print iface, cidr
        }
      }
    '
    return
  fi

  if command -v ifconfig >/dev/null 2>&1; then
    ifconfig 2>/dev/null | awk '
      /^[A-Za-z0-9_.:@-]+[[:space:]]/ {
        iface=$1
        sub(/:$/, "", iface)
        sub(/@.*/, "", iface)
      }
      /inet addr:/ {
        ip=$2
        sub(/^addr:/, "", ip)
        if (iface != "" && ip ~ /^[0-9]+\./ &&
            ip !~ /^127\./ && ip !~ /^0\./ &&
            ip !~ /^169\.254\./) print iface, ip "/24"
      }
      /inet / && $2 ~ /^[0-9]+\./ {
        if (iface != "" && $2 !~ /^127\./ &&
            $2 !~ /^0\./ && $2 !~ /^169\.254\./) {
          print iface, $2 "/24"
        }
      }
    '
  fi
}

own_ip4_list() {
  own_ip4_records | awk 'NF >= 2 {print $2}'
}

is_private_lan_cidr() {
  local ip=${1%%/*} a b c d
  old_ifs=$IFS
  IFS=.
  set -- $ip
  IFS=$old_ifs
  a=$1; b=$2; c=$3; d=$4

  case "$a:$b:$c:$d" in
    *:*:*:) return 1 ;;
    *[!0-9:]* ) return 1 ;;
  esac

  case "$a" in
    10) return 0 ;;
    192) [ "$b" = "168" ] && return 0 ;;
    172)
      [ "$b" -ge 16 ] 2>/dev/null &&
      [ "$b" -le 31 ] 2>/dev/null &&
      return 0
      ;;
  esac
  return 1
}

is_trusted_lan_iface() {
  local iface=${1%%@*}

  # 明確排除行動數據、VPN、隧道、虛擬測試與 CGNAT 類介面。
  case "$iface" in
    lo|rmnet*|r_rmnet*|ccmni*|pdp*|wwan*|cell*|tun*|tap*|wg*|wireguard*|tailscale*|zt*|clat*|v4-*|dummy*|ifb*|ip6tnl*|sit*|gre*|gretap*|wifi-aware*|aware*|p2p*)
      return 1
      ;;
  esac

  # 常見實體 LAN／Wi-Fi／熱點／USB／藍牙網路介面。
  case "$iface" in
    wlan*|wifi*|mlan*|eth*|en*|ap*|swlan*|softap*|rndis*|usb*|bnep*|bt-pan*|br*|bond*)
      return 0
      ;;
  esac

  # 廠商自訂 Wi-Fi 名稱仍可由 sysfs wireless 標記辨識。
  [ -d "/sys/class/net/$iface/wireless" ] && return 0
  return 1
}

lan_reject_reason() {
  local iface="$1" cidr="$2"
  if ! is_trusted_lan_iface "$iface"; then
    printf '介面類型不在可信任 LAN 清單'
  elif ! is_private_lan_cidr "$cidr"; then
    printf '位址不是 RFC1918 私有區網'
  else
    printf 'accepted'
  fi
}

trusted_lan_ip4_records() {
  local ifname cidr
  own_ip4_records |
  while read -r ifname cidr; do
    is_trusted_lan_iface "$ifname" || continue
    is_private_lan_cidr "$cidr" || continue
    printf '%s %s\n' "$ifname" "$cidr"
  done
}

trusted_lan_ip4_list() {
  trusted_lan_ip4_records | awk 'NF >= 2 {print $2}'
}

auto_interfaces_key() {
  trusted_lan_ip4_records | sort -u | tr '\n' ' ' | sed 's/[[:space:]]*$//'
}

interfaces_line() {
  local out="127.0.0.1/8" i
  if [ "${INTERFACES_AUTO:-1}" = "1" ]; then
    for i in $(trusted_lan_ip4_list); do
      case "$i" in
        127.*|0.*|'') ;;
        *) out="$out $i" ;;
      esac
    done
  fi
  if [ -n "$EXTRA_INTERFACES" ]; then
    out="$out $EXTRA_INTERFACES"
  fi
  printf '%s' "$out"
}

network_diagnostic() {
  local ifname cidr reason watcher_pid native_pid watcher_cmd native_exe native_version
  load_config

  watcher_pid="$(cat "$RUNTIME/network_watch.lock/pid" 2>/dev/null)"
  native_pid="$(cat "$RUNTIME/network_watch.lock/netwatch_pid" 2>/dev/null)"
  watcher_cmd="$(tr '\0' ' ' < "/proc/$watcher_pid/cmdline" 2>/dev/null)"
  native_exe="$(readlink "/proc/$native_pid/exe" 2>/dev/null)"
  if [ -x "$NETWATCH" ]; then
    native_version="$("$NETWATCH" --version 2>&1 | head -n 1)"
  else
    native_version="缺失"
  fi

  echo "=== SMB 網路診斷 ==="
  echo "時間: $(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null)"
  echo "IPv4 查詢指令: $(command -v ip 2>/dev/null || echo 未找到)"
  echo "事件監看: native NETLINK_ROUTE（僅處理 LAN 候選介面）"
  echo "netwatch: $NETWATCH"
  echo "netwatch 版本: $native_version"
  echo "設定: AUTO_START=$AUTO_START ENABLED=$ENABLED BIND_INTERFACES=$BIND_INTERFACES INTERFACES_AUTO=$INTERFACES_AUTO"
  echo
  echo "[原始 IPv4]"
  if command -v ip >/dev/null 2>&1; then
    ip -o -4 addr show 2>&1 || ip -4 addr show 2>&1 || true
  elif command -v ifconfig >/dev/null 2>&1; then
    ifconfig 2>&1 || true
  else
    echo "找不到 ip 或 ifconfig"
  fi
  echo
  echo "[解析後 IPv4]"
  own_ip4_records
  echo
  echo "[LAN 判斷]"
  own_ip4_records |
  while read -r ifname cidr; do
    reason="$(lan_reject_reason "$ifname" "$cidr")"
    printf '%s %s -> %s\n' "$ifname" "$cidr" "$reason"
  done
  echo
  echo "[可信任 LAN]"
  trusted_lan_ip4_records
  echo
  echo "[實際 interfaces]"
  interfaces_line
  echo
  echo "[事件過濾]"
  echo "僅處理：wlan/wifi/mlan/eth/en/ap/swlan/softap/rndis/usb/bnep/bt-pan/br/bond 與 sysfs wireless"
  echo "直接忽略：rmnet/r_rmnet/ccmni/pdp/wwan/tun/tap/wg/tailscale/wifi-aware/p2p 等"
  echo
  echo "[程序]"
  echo "watcher pid: ${watcher_pid:-無}"
  echo "watcher cmd: ${watcher_cmd:-無}"
  echo "netwatch pid: ${native_pid:-無}"
  echo "netwatch exe: ${native_exe:-無}"
  if [ -n "$native_pid" ]; then
    echo "netwatch wchan: $(cat "/proc/$native_pid/wchan" 2>/dev/null || echo 無法讀取)"
    echo "netwatch state: $(sed -n 's/^State:[[:space:]]*//p' "/proc/$native_pid/status" 2>/dev/null || echo 無法讀取)"
  fi
  echo "smbd: $(running_pids | tr '\n' ' ')"
  echo
  echo "[smb.conf 綁定]"
  grep -E '^[[:space:]]*(interfaces|bind interfaces only|server min protocol|server max protocol|change notify|kernel change notify|smb3 directory leases)[[:space:]]*=' "$CONF" 2>/dev/null || true
}

make_dirs() {
  mkdir -p "$RUNTIME" "$LOGDIR" "$STATEDIR" "$CACHEDIR" "$PRIVATEDIR" "$PIDDIR" "$SHARE_PATH" 2>/dev/null
  chmod 700 "$DATA_DIR" "$RUNTIME" "$PRIVATEDIR" 2>/dev/null
  chmod 600 "$PASSDB" "$USERMAP" 2>/dev/null
}

resolve_share_path() {
  # WebUI 保留使用者熟悉的 /storage/emulated/0 或 /sdcard 路徑，
  # smbd 內部優先改走 /data/media/0，避免多一層 emulated-storage/FUSE。
  local configured="$1" candidate
  case "$configured" in
    /storage/emulated/0)
      candidate=/data/media/0
      ;;
    /storage/emulated/0/*)
      candidate="/data/media/0/${configured#/storage/emulated/0/}"
      ;;
    /sdcard)
      candidate=/data/media/0
      ;;
    /sdcard/*)
      candidate="/data/media/0/${configured#/sdcard/}"
      ;;
    *)
      printf '%s' "$configured"
      return 0
      ;;
  esac

  if [ -d "$candidate" ] && [ -r "$candidate" ] && [ -x "$candidate" ]; then
    printf '%s' "$candidate"
  else
    printf '%s' "$configured"
  fi
}

running_pids() {
  local p exe
  for p in $(pidof smbd 2>/dev/null); do
    exe=$(readlink "/proc/$p/exe" 2>/dev/null)
    if [ "$exe" = "$SMBD" ]; then
      echo "$p"
    fi
  done
}

is_running() {
  [ -n "$(running_pids)" ]
}

stop_server() {
  local p i
  log_module INFO STOP "請求停止；pids=$(running_pids | tr '\n' ' ')"
  for p in $(running_pids); do
    kill "$p" 2>/dev/null
  done

  i=0
  while is_running && [ "$i" -lt 10 ]; do
    sleep 0.1
    i=$((i + 1))
  done

  for p in $(running_pids); do
    kill -9 "$p" 2>/dev/null
  done

  rm -f "$RUNTIME/pending_auth_start" "$RUNTIME/waiting_network" "$RUNTIME/interface_key" 2>/dev/null
  sed -i 's/^ENABLED=.*/ENABLED=0/' "$CFG" 2>/dev/null
  module_prop_update_status
  log_module INFO STOP_OK "smbd 已停止"
  echo "已停止 SMB 伺服器"
}

clean_legacy_smbd_stderr() {
  local src="$LOGDIR/smbd.stderr.log" tmp="$LOGDIR/.smbd.stderr.clean.$$"

  [ -f "$src" ] || return 0
  mkdir -p "$LOGDIR" 2>/dev/null

  awk '
    pending != "" {
      if ($0 ~ /reopen_one_log: Unable to open new log file .*samba-android-arm64-static\/samba-install\/var\/log\.smbd/) {
        pending=""
        next
      }
      print pending
      pending=""
    }
    /lib\/util\/debug\.c:.*\(reopen_one_log\)$/ {
      pending=$0
      next
    }
    { print }
    END {
      if (pending != "") print pending
    }
  ' "$src" > "$tmp" 2>/dev/null || {
    rm -f "$tmp" 2>/dev/null
    return 1
  }

  chmod 600 "$tmp" 2>/dev/null
  mv -f "$tmp" "$src" 2>/dev/null
}

write_smb_conf() {
  load_config
  make_dirs
  MIN_PROTOCOL=$(sanitize_protocol "$MIN_PROTOCOL")
  MAX_PROTOCOL=$(sanitize_protocol "$MAX_PROTOCOL")
  if ! valid_share_name "$SHARE_NAME"; then
    echo "分享名稱含非法字元: $SHARE_NAME" >&2
    return 1
  fi
  if ! valid_smb_username "$SMB_USERNAME"; then
    echo "SMB 使用者名稱僅能包含英數字、點、底線與連字號，最長 32 字元" >&2
    return 1
  fi
  local iface bind readonly writable auth_note
  local effective_min effective_max signing_mode encrypt_mode ntlm_mode
  local effective_share_path receivefile_size
  iface=$(interfaces_line)
  [ "$BIND_INTERFACES" = "1" ] && bind=yes || bind=no
  # 無人值守的開機自啟固定啟用 LAN 安全綁定。
  [ "${AUTO_START:-0}" = "1" ] && bind=yes
  if [ "$READ_ONLY" = "1" ]; then
    readonly=yes; writable=no
  else
    readonly=no; writable=yes
  fi

  effective_min="$MIN_PROTOCOL"
  effective_max="$MAX_PROTOCOL"
  signing_mode=auto
  encrypt_mode=off
  ntlm_mode=ntlmv2-only
  receivefile_size=0
  effective_share_path="$(resolve_share_path "$SHARE_PATH")"

  if [ "$AUTH_MODE" = "user" ]; then
    password_set || {
      echo "帳號密碼模式尚未設定密碼，請先在 WebUI 輸入密碼" >&2
      return 1
    }
    write_username_map || {
      echo "建立 Samba 使用者對應失敗" >&2
      return 1
    }
    auth_note="user"
    cat > "$CONF" <<EOF
[global]
   server role = standalone server
   security = user
   workgroup = $WORKGROUP
   netbios name = $NETBIOS_NAME
   server string = Android SMB Server WebUI
   disable netbios = yes
   smb ports = $PORT
   interfaces = $iface
   bind interfaces only = $bind
   server min protocol = $effective_min
   server max protocol = $effective_max
   server signing = $signing_mode
   server smb encrypt = $encrypt_mode
   ntlm auth = $ntlm_mode
   lanman auth = no
   use sendfile = yes
   aio read size = 1
   aio write size = 1
   min receivefile size = $receivefile_size
   change notify = yes
   kernel change notify = yes
   smb3 directory leases = no
   map to guest = Never
   passdb backend = smbpasswd:$PASSDB
   username map = $USERMAP
   username map cache time = 0
   load printers = no
   printing = bsd
   printcap name = /dev/null
   log level = 0
   log file = $LOGDIR/smbd.log
   max log size = 512
   lock directory = $LOCKDIR
   state directory = $STATEDIR
   cache directory = $CACHEDIR
   private dir = $PRIVATEDIR
   pid directory = $PIDDIR
   ncalrpc dir = $RUNTIME/ncalrpc

[$SHARE_NAME]
   path = $effective_share_path
   browseable = yes
   read only = $readonly
   writable = $writable
   guest ok = no
   guest only = no
   valid users = root
   force user = root
   force group = root
   create mask = 0666
   directory mask = 0777
EOF
  else
    auth_note="guest"
    cat > "$CONF" <<EOF
[global]
   server role = standalone server
   security = user
   workgroup = $WORKGROUP
   netbios name = $NETBIOS_NAME
   server string = Android SMB Server WebUI
   disable netbios = yes
   smb ports = $PORT
   interfaces = $iface
   bind interfaces only = $bind
   server min protocol = $effective_min
   server max protocol = $effective_max
   server signing = $signing_mode
   server smb encrypt = $encrypt_mode
   ntlm auth = $ntlm_mode
   lanman auth = no
   use sendfile = yes
   aio read size = 1
   aio write size = 1
   min receivefile size = $receivefile_size
   change notify = yes
   kernel change notify = yes
   smb3 directory leases = no
   map to guest = Bad User
   guest account = root
   usershare allow guests = yes
   load printers = no
   printing = bsd
   printcap name = /dev/null
   log level = 0
   log file = $LOGDIR/smbd.log
   max log size = 512
   lock directory = $LOCKDIR
   state directory = $STATEDIR
   cache directory = $CACHEDIR
   private dir = $PRIVATEDIR
   pid directory = $PIDDIR
   ncalrpc dir = $RUNTIME/ncalrpc

[$SHARE_NAME]
   path = $effective_share_path
   browseable = yes
   read only = $readonly
   writable = $writable
   guest ok = yes
   guest only = yes
   force user = root
   force group = root
   create mask = 0666
   directory mask = 0777
EOF
  fi
  echo "$auth_note" > "$RUNTIME/auth_mode" 2>/dev/null
  printf '%s' "$effective_share_path" > "$RUNTIME/effective_share_path" 2>/dev/null
}

suspend_server_for_network() {
  local p i
  log_module WARN LAN_LOST "可信任 LAN 消失；準備暫停 smbd"
  for p in $(running_pids); do
    kill "$p" 2>/dev/null
  done

  i=0
  while is_running && [ "$i" -lt 10 ]; do
    sleep 0.1
    i=$((i + 1))
  done

  for p in $(running_pids); do
    kill -9 "$p" 2>/dev/null
  done

  touch "$RUNTIME/waiting_network" 2>/dev/null
  rm -f "$RUNTIME/interface_key" 2>/dev/null
  sed -i 's/^ENABLED=.*/ENABLED=1/' "$CFG" 2>/dev/null
  module_prop_update_status
  log_module INFO LAN_WAIT "smbd 已暫停；等待可信任 LAN"
  echo "已暫停 SMB：等待可信任區域網路"
}

start_server() {
  local i
  load_config
  log_module INFO START "請求啟動；auth=$AUTH_MODE auto_start=$AUTO_START enabled=$ENABLED share=$SHARE_PATH"
  if [ ! -x "$SMBD" ]; then
    echo "找不到 smbd 或無執行權限: $SMBD" >&2
    return 1
  fi

  if is_running; then
    echo "SMB 伺服器已在執行"
    module_prop_update_status
    status_text
    return 0
  fi

  write_smb_conf || {
    log_module ERROR START "建立 smb.conf 失敗"
    return 1
  }
  clean_legacy_smbd_stderr >/dev/null 2>&1 || true
  log_module INFO START "啟動前 LAN=$(auto_interfaces_key) interfaces=$(interfaces_line) change_notify=yes kernel_notify=yes dir_leases=no"
  "$SMBD" --log-basename="$LOGDIR" -D -s "$CONF" >>"$LOGDIR/smbd.stdout.log" 2>>"$LOGDIR/smbd.stderr.log"

  i=0
  while ! is_running && [ "$i" -lt 15 ]; do
    sleep 0.1
    i=$((i + 1))
  done

  if is_running; then
    rm -f "$RUNTIME/pending_auth_start" "$RUNTIME/waiting_network" 2>/dev/null
    auto_interfaces_key > "$RUNTIME/interface_key" 2>/dev/null
    sed -i 's/^ENABLED=.*/ENABLED=1/' "$CFG" 2>/dev/null
    echo "SMB 伺服器已啟動"
    log_module INFO START_OK "smbd=$(running_pids | tr '\n' ' ') LAN=$(auto_interfaces_key)"
    module_prop_update_status
    status_text
    return 0
  fi

  log_module ERROR START_FAIL "smbd 未進入執行狀態；LAN=$(auto_interfaces_key)"
  echo "SMB 伺服器啟動失敗，請查看日誌: $LOGDIR/smbd.log / smbd.stderr.log" >&2
  tail -n 40 "$LOGDIR/smbd.stderr.log" 2>/dev/null
  return 1
}

restart_server() {
  stop_server >/dev/null 2>&1
  start_server
}

addresses() {
  local share="$SHARE_NAME" ip
  for ip in $(trusted_lan_ip4_list | sed 's#/.*##'); do
    case "$ip" in 127.*|0.*|'') ;; *) echo "smb://$ip/$share/" ;; esac
  done
}


module_prop_update_status() {
  # 模組列表卡片讀 module.prop description；在啟停/保存設定後同步狀態。
  local prop="$MODDIR/module.prop" running state addr desc safe_path safe_share mode_text
  [ -f "$prop" ] || return 0
  load_config
  if is_running; then
    running=1
    state="啟動中"
  elif [ -f "$RUNTIME/waiting_network" ] && [ "${ENABLED:-0}" = "1" ]; then
    running=0
    state="等待區域網路"
  else
    running=0
    state="已停止"
  fi
  safe_path="${SHARE_PATH:-/sdcard/SpeedBackup}"
  safe_share="${SHARE_NAME:-SpeedBackup}"
  mode_text="$(auth_label)"
  if [ "$running" = "1" ]; then
    addr="$(addresses | tr '\n' ' ' | sed 's/[[:space:]]*$//')"
    [ -n "$addr" ] || addr="smb://目前無可用IP/$safe_share/"
    desc="狀態：$state｜分享：$safe_path｜位址：$addr｜模式：$mode_text"
  elif [ "$state" = "等待區域網路" ]; then
    desc="狀態：等待區域網路｜分享：$safe_path｜Wi-Fi／乙太網路就緒後自動啟動｜模式：$mode_text"
  else
    desc="狀態：$state｜分享：$safe_path｜名稱：$safe_share｜模式：$mode_text"
  fi
  desc="$(printf '%s' "$desc" | tr '\n\r' ' ' | cut -c 1-240)"
  awk -v d="$desc" 'BEGIN{done=0} /^description=/{print "description=" d; done=1; next} {print} END{if(!done) print "description=" d}' "$prop" > "$prop.tmp.$$" 2>/dev/null && mv "$prop.tmp.$$" "$prop"
  rm -f "$prop.tmp.$$" 2>/dev/null
  return 0
}

status_text() {
  load_config
  if is_running; then
    echo "狀態: 執行中"
  elif [ -f "$RUNTIME/waiting_network" ] && [ "${ENABLED:-0}" = "1" ]; then
    echo "狀態: 等待區域網路（Wi-Fi／乙太網路就緒後自動啟動）"
  else
    echo "狀態: 已停止"
  fi
  echo "PID: $(running_pids | tr '\n' ' ')"
  echo "分享: //$SHARE_NAME -> $SHARE_PATH"
  local _effective_share
  _effective_share="$(resolve_share_path "$SHARE_PATH")"
  if [ "$_effective_share" != "$SHARE_PATH" ]; then
    echo "實際路徑: $_effective_share（已繞過模擬儲存層）"
  fi
  echo "權限: $([ "$READ_ONLY" = "1" ] && echo 唯讀 || echo 可讀寫)"
  echo "協議: $MIN_PROTOCOL ~ $MAX_PROTOCOL"
  echo "目錄同步: 即時通知（SMB3 目錄租約已停用）"
  echo "Port: $PORT"
  echo "介面: $(interfaces_line)"
  echo "位址:"
  addresses | sed 's/^/  /'
  echo "認證模式: $(auth_label)"
  if [ "$AUTH_MODE" = "user" ]; then
    echo "密碼狀態: $(password_set && echo 已設定 || echo 未設定)"
  fi
}

status_json() {
  load_config
  local run waiting p addr auth logtail ver netwatch_ver
  is_running && run=true || run=false
  if [ -f "$RUNTIME/waiting_network" ] && [ "${ENABLED:-0}" = "1" ]; then
    waiting=true
  else
    waiting=false
  fi
  p=$(running_pids | tr '\n' ' ' | sed 's/[ ]*$//')
  addr=$(addresses | tr '\n' ' ' | sed 's/[ ]*$//')
  auth=$(cat "$RUNTIME/auth_mode" 2>/dev/null)
  ver=$(cached_status_line smbd_version "$SMBD" -V)
  netwatch_ver=$(cached_status_line netwatch_version "$NETWATCH" --version)
  printf '{'
  printf '"running":%s,' "$run"
  printf '"waitingNetwork":%s,' "$waiting"
  printf '"pid":"%s",' "$(json_escape "$p")"
  printf '"version":"%s",' "$(json_escape "$ver")"
  printf '"sharePath":"%s",' "$(json_escape "$SHARE_PATH")"
  printf '"effectiveSharePath":"%s",' "$(json_escape "$(resolve_share_path "$SHARE_PATH")")"
  printf '"performanceProfile":"smb2-smb3",'
  printf '"shareName":"%s",' "$(json_escape "$SHARE_NAME")"
  printf '"readOnly":"%s",' "$(json_escape "$READ_ONLY")"
  if [ "$AUTH_MODE" = "guest" ]; then printf '"guest":true,'; else printf '"guest":false,'; fi
  printf '"authMode":"%s",' "$(json_escape "$AUTH_MODE")"
  printf '"authLabel":"%s",' "$(json_escape "$(auth_label)")"
  printf '"smbUsername":"%s",' "$(json_escape "$SMB_USERNAME")"
  if password_set; then printf '"passwordSet":true,'; else printf '"passwordSet":false,'; fi
  printf '"minProtocol":"%s",' "$(json_escape "$MIN_PROTOCOL")"
  printf '"maxProtocol":"%s",' "$(json_escape "$MAX_PROTOCOL")"
  printf '"effectiveMinProtocol":"%s",' "$(json_escape "$MIN_PROTOCOL")"
  printf '"effectiveMaxProtocol":"%s",' "$(json_escape "$MAX_PROTOCOL")"
  printf '"port":"%s",' "$(json_escape "$PORT")"
  printf '"interfaces":"%s",' "$(json_escape "$(interfaces_line)")"
  printf '"trustedLanInterfaces":"%s",' "$(json_escape "$(auto_interfaces_key)")"
  printf '"lanGuard":true,'
  printf '"networkWatchMode":"native-rtnetlink-lan-filter",'
  printf '"changeNotify":true,'
  printf '"kernelChangeNotify":true,'
  printf '"smb3DirectoryLeases":false,'
  printf '"netwatchVersion":"%s",' "$(json_escape "$netwatch_ver")"
  printf '"addresses":"%s",' "$(json_escape "$addr")"
  printf '"configPath":"%s",' "$(json_escape "$CFG")"
  printf '"confPath":"%s"' "$(json_escape "$CONF")"
  printf '}\n'
}

get_config_json() {
  load_config
  printf '{'
  printf '"AUTO_START":"%s",' "$(json_escape "$AUTO_START")"
  printf '"SHARE_PATH":"%s",' "$(json_escape "$SHARE_PATH")"
  printf '"SHARE_NAME":"%s",' "$(json_escape "$SHARE_NAME")"
  printf '"READ_ONLY":"%s",' "$(json_escape "$READ_ONLY")"
  printf '"MIN_PROTOCOL":"%s",' "$(json_escape "$MIN_PROTOCOL")"
  printf '"MAX_PROTOCOL":"%s",' "$(json_escape "$MAX_PROTOCOL")"
  printf '"BIND_INTERFACES":"%s",' "$(json_escape "$BIND_INTERFACES")"
  printf '"INTERFACES_AUTO":"%s",' "$(json_escape "$INTERFACES_AUTO")"
  printf '"EXTRA_INTERFACES":"%s",' "$(json_escape "$EXTRA_INTERFACES")"
  printf '"PORT":"%s",' "$(json_escape "$PORT")"
  printf '"NETBIOS_NAME":"%s",' "$(json_escape "$NETBIOS_NAME")"
  printf '"WORKGROUP":"%s",' "$(json_escape "$WORKGROUP")"
  printf '"AUTH_MODE":"%s",' "$(json_escape "$AUTH_MODE")"
  printf '"SMB_USERNAME":"%s",' "$(json_escape "$SMB_USERNAME")"
  if password_set; then printf '"PASSWORD_SET":"1"'; else printf '"PASSWORD_SET":"0"'; fi
  printf '}\n'
}

set_config() {
  load_config
  local kv k v
  for kv in "$@"; do
    k=${kv%%=*}; v=${kv#*=}; v=$(shell_escape_value "$v")
    case "$k" in
      AUTO_START) case "$v" in 1|true|yes|on) AUTO_START=1 ;; *) AUTO_START=0 ;; esac ;;
      SHARE_PATH) [ -n "$v" ] && SHARE_PATH="$v" ;;
      SHARE_NAME) [ -n "$v" ] && SHARE_NAME="$v" ;;
      READ_ONLY) case "$v" in 1|true|yes|on) READ_ONLY=1 ;; *) READ_ONLY=0 ;; esac ;;
      MIN_PROTOCOL) MIN_PROTOCOL=$(sanitize_protocol "$v") ;;
      MAX_PROTOCOL) MAX_PROTOCOL=$(sanitize_protocol "$v") ;;
      BIND_INTERFACES) case "$v" in 1|true|yes|on) BIND_INTERFACES=1 ;; *) BIND_INTERFACES=0 ;; esac ;;
      INTERFACES_AUTO) case "$v" in 1|true|yes|on) INTERFACES_AUTO=1 ;; *) INTERFACES_AUTO=0 ;; esac ;;
      EXTRA_INTERFACES) EXTRA_INTERFACES="$v" ;;
      PORT) case "$v" in ''|*[!0-9]*) PORT=445 ;; *) PORT="$v" ;; esac ;;
      NETBIOS_NAME) [ -n "$v" ] && NETBIOS_NAME="$v" ;;
      WORKGROUP) [ -n "$v" ] && WORKGROUP="$v" ;;
      AUTH_MODE) case "$v" in guest|user) AUTH_MODE="$v" ;; *) AUTH_MODE=guest ;; esac ;;
      SMB_USERNAME) valid_smb_username "$v" && SMB_USERNAME="$v" || { echo "使用者名稱格式錯誤" >&2; return 1; } ;;
    esac
  done
  write_config
  write_username_map 2>/dev/null || true
  log_module INFO CONFIG_SAVE "設定已保存；auth=$AUTH_MODE auto_start=$AUTO_START bind=$BIND_INTERFACES auto_if=$INTERFACES_AUTO"

  # 如果先前服務因等待帳密而暫停，改回 Guest 後立即恢復。
  if [ "$AUTH_MODE" = "guest" ] && [ -f "$RUNTIME/pending_auth_start" ]; then
    rm -f "$RUNTIME/pending_auth_start" 2>/dev/null
    start_server >/dev/null 2>&1 || true
  fi

  module_prop_update_status
  echo "設定已保存"
}

save_restart_config() {
  shift
  set_config "$@" >/dev/null || return 1
  load_config

  if [ "$AUTH_MODE" = "user" ] && ! password_set; then
    if is_running; then
      stop_server >/dev/null 2>&1
      touch "$RUNTIME/pending_auth_start" 2>/dev/null
      sed -i 's/^ENABLED=.*/ENABLED=1/' "$CFG" 2>/dev/null
    fi
    module_prop_update_status
    echo "AUTH_PASSWORD_REQUIRED"
    echo "帳號密碼模式已保存；設定密碼後會自動啟動 SMB 服務"
    return 0
  fi

  rm -f "$RUNTIME/pending_auth_start" 2>/dev/null
  restart_server
}

show_log() {
  echo "日誌目錄: $LOGDIR"
  echo "一鍵診斷: $MODDIR/diagnose.sh"
  echo
  echo "===== module.log（最近 250 行）====="
  if [ -f "$MODULE_LOG" ]; then
    tail -n 250 "$MODULE_LOG" 2>/dev/null
  else
    echo "尚無模組執行日誌"
  fi
  echo
  echo "===== 即時網路診斷 ====="
  network_diagnostic
  echo
  echo "===== smbd.log（最近 120 行）====="
  if [ -f "$LOGDIR/smbd.log" ]; then
    tail -n 120 "$LOGDIR/smbd.log" 2>/dev/null
  elif [ -f "$LOGDIR/smbd.stderr.log" ]; then
    tail -n 120 "$LOGDIR/smbd.stderr.log" 2>/dev/null
  else
    echo "尚無 smbd 日誌"
  fi
}

case "$1" in
  start) load_config; start_server ;;
  stop) load_config; stop_server ;;
  restart) load_config; restart_server ;;
  status) status_json ;;
  status_text) status_text ;;
  get_config) get_config_json ;;
  set_config) shift; set_config "$@" ;;
  save_restart) save_restart_config "$@" ;;
  set_password_hex) shift; set_password_hex "$1" ;;
  log) show_log ;;
  is_running) is_running ;;
  conf) [ -f "$CONF" ] && cat "$CONF" || true ;;
  interface_key) load_config; auto_interfaces_key ;;
  trusted_lan) load_config; trusted_lan_ip4_records ;;
  diagnose) network_diagnostic ;;
  clean_stderr) clean_legacy_smbd_stderr ;;
  suspend_network) load_config; suspend_server_for_network ;;
  refresh_card) module_prop_update_status ;;
  *) echo "用法: $0 {start|stop|restart|status|status_text|get_config|set_config|save_restart|set_password_hex|log|diagnose|clean_stderr|conf|interface_key|trusted_lan|suspend_network|is_running|refresh_card}" ;;
esac
