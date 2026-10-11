#!/system/bin/sh
MODDIR=${0%/*}
"$MODDIR/bin/smbctl" boot || exit $?
exec "$MODDIR/bin/smbctl" watch
