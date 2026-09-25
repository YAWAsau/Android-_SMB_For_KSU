#!/usr/bin/env bash
set -euo pipefail
HOST_BIN=/usr/bin
ARGS=()
for arg in "$@"; do
  case "$arg" in
    -pie|-Wl,-z,relro,-z,now|-Wl,-no-undefined|-flto=thin) ;;
    *) ARGS+=("$arg") ;;
  esac
done
"$HOST_BIN/gcc.exe" -D_GNU_SOURCE -D_SAMBA_HOSTCC_ "${ARGS[@]}"
# MSYS GCC adds .exe to linked programs, while Waf expects its exact -o path.
output=''
previous=''
compile_only=false
for arg in "${ARGS[@]}"; do
  if [ "$previous" = '-o' ]; then output="$arg"; fi
  case "$arg" in -o?*) output="${arg:2}" ;; esac
  if [ "$arg" = '-c' ]; then compile_only=true; fi
  previous="$arg"
done
if ! "$compile_only" && [ -n "$output" ] && [ -f "$output.exe" ] && [ ! "$output.exe" -ef "$output" ]; then
  cp -f "$output.exe" "$output"
fi
if ! "$compile_only" && [ -n "$output" ] && [ -f "$output.exe" ]; then
  generator=$(basename "$output")
  case "$generator" in
    compile_et|asn1_compile)
      # Publish after linking, including on a clean build where Waf cannot
      # create a Windows symlink to a not-yet-existing executable.
      cp -f "$output.exe" "$SAMBA_BUILD_ROOT/bin/$generator.exe"
      ;;
  esac
fi
