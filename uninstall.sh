#!/system/bin/sh
MODDIR=${0%/*}
"$MODDIR/bin/smbctl" watch-stop
"$MODDIR/bin/smbctl" stop
# Keep non-secret settings for reinstall; remove credentials.
rm -f /data/adb/smbdwebui/runtime/private/smbpasswd /data/adb/smbdwebui/runtime/private/username.map
