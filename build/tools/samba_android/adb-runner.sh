#!/usr/bin/env bash
set -euo pipefail
ADB=$1
SERIAL=$2
shift 2
export MSYS_NO_PATHCONV=1
EXE=$1
shift
REMOTE="/data/local/tmp/samba-cross-$$"
cleanup() { "$ADB" -s "$SERIAL" shell rm -f "$REMOTE" >/dev/null 2>&1 || true; }
trap cleanup EXIT
EXE=$(cygpath -w "$EXE")
"$ADB" -s "$SERIAL" push "$EXE" "$REMOTE" >/dev/null
"$ADB" -s "$SERIAL" shell chmod 700 "$REMOTE"

quote_sh() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\''/g")"; }
CMD="cd /data/local/tmp && $(quote_sh "$REMOTE")"
for arg in "$@"; do CMD="$CMD $(quote_sh "$arg")"; done
# The module runs smbclient as KernelSU root. Samba's configure also probes
# Linux per-thread credential transitions, which fail when run as adb shell
# (uid 2000), so execute only these temporary probe binaries through su.
"$ADB" -s "$SERIAL" shell su -c "$(quote_sh "$CMD")"
