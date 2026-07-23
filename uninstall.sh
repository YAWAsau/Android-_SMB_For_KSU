#!/system/bin/sh
MODDIR=${0%/*}
sh "$MODDIR/control.sh" stop >/dev/null 2>&1
# Keep /data/adb/smbdwebui/config.conf intentionally, so reinstall keeps user config.

# Remove stored SMB credentials on uninstall; keep non-secret config for reinstall.
rm -f /data/adb/smbdwebui/runtime/private/smbpasswd /data/adb/smbdwebui/runtime/private/username.map 2>/dev/null
