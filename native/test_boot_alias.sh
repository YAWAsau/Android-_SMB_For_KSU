#!/system/bin/sh
set -eu
BASE=/data/local/tmp/smb-bootfix-test
/data/adb/ksu/bin/busybox mount --make-rprivate /
/data/adb/ksu/bin/busybox mount -t tmpfs tmpfs /storage
mkdir -p /data/media/0/.smb-bootfix-test
export SMBDWEBUI_DATA=$BASE/data
OLD=$BASE/old/bin/smbctl
NEW=$BASE/new/bin/smbctl
trap '$NEW stop >/dev/null 2>&1; rmdir /data/media/0/.smb-bootfix-test' EXIT
$NEW set_config SHARE_PATH=/sdcard/.smb-bootfix-test SHARE_NAME=BootFix PORT=1445 AUTH_MODE=user SMB_USERNAME=boottest READ_ONLY=1
$NEW set_password_hex 426f6f744669782d544553542d3230323631303131
if $OLD start >$BASE/old-result.txt 2>&1; then
 echo 'FAIL old unexpectedly started'; exit 1
fi
cat $BASE/old-result.txt
$NEW start
$NEW is_running
echo 'PASS dangling sdcard: old fails, new owned listeners ready'
