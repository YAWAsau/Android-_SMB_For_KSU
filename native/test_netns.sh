#!/system/bin/sh
# Test driver only. Run under `su -c 'unshare -n sh ...'` on the spare device.
set -eu
export SMBDWEBUI_DATA=/data/local/tmp/smb-rust-test/data
CTL=/data/local/tmp/smb-rust-test/module/bin/smbctl
cleanup() { "$CTL" watch-stop; "$CTL" stop; }
trap cleanup EXIT
wait_state() {
  attempts=0
  while [ "$attempts" -lt 60 ]; do
    if "$CTL" status | grep -q "$1"; then return 0; fi
    attempts=$((attempts + 1))
    sleep .2
  done
  echo "FAIL waiting for $1" >&2
  exit 1
}
ip link set lo up
"$CTL" set_config AUTH_MODE=guest SHARE_NAME=RustNetns ENABLED=1
"$CTL" watch >/data/local/tmp/smb-rust-test/netns-watch.log 2>&1 &
wait_state '"waitingNetwork":true'
ip link add ethsmbrust type dummy
ip addr add 10.223.1.1/24 dev ethsmbrust
ip link set ethsmbrust up
wait_state '"running":true'
echo 'PASS LAN appearance starts service'
before=$(cat "$SMBDWEBUI_DATA/runtime/run/smbd.pid")
ip addr replace 10.223.1.1/24 dev ethsmbrust
sleep 1
after=$(cat "$SMBDWEBUI_DATA/runtime/run/smbd.pid")
[ "$before" = "$after" ]
echo 'PASS duplicate address event keeps existing service'
ip addr del 10.223.1.1/24 dev ethsmbrust
wait_state '"waitingNetwork":true'
wait_state '"processRunning":false'
echo 'PASS LAN loss stops owned processes'
ip addr add 10.223.1.2/24 dev ethsmbrust
wait_state '"running":true'
"$CTL" conf | grep -q '10.223.1.2/24'
echo 'PASS LAN recovery rebinds new address'
