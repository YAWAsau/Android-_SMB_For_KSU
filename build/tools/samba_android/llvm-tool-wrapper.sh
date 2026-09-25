#!/usr/bin/env bash
set -euo pipefail
tool=$1
shift
case "$tool" in
  ar) exec "$ANDROID_AR" "$@" ;;
  ranlib) exec "$ANDROID_RANLIB" "$@" ;;
  strip) exec "$ANDROID_STRIP" "$@" ;;
  *) echo "Unsupported LLVM tool: $tool" >&2; exit 2 ;;
esac
