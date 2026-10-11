#!/system/bin/sh
MODDIR=${0%/*}
# Compatibility entry for module managers and upgrades. State machine lives in Rust.
if [ "$1" = "--replace" ]; then
  "$MODDIR/bin/smbctl" watch-stop || exit $?
fi
exec "$MODDIR/bin/smbctl" watch
