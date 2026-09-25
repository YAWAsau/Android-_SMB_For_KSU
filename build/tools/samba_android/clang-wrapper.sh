#!/usr/bin/env bash
set -euo pipefail
extra=()
if [ -n "${SAMBA_PREFIX:-}" ]; then extra+=("-I$SAMBA_PREFIX/include"); fi
all_args="$*"
case " $all_args " in
  *' -static '*)
    filtered=()
    for arg in "$@"; do
      case "$arg" in
        -pie|-no-pie) ;;
        -Wl,-Bdynamic|-Wl,--Bdynamic) filtered+=('-Wl,-Bstatic') ;;
        *) filtered+=("$arg") ;;
      esac
    done
    set -- "${filtered[@]}"
    ;;
esac
link_deps=()
case "$all_args" in
  *-lgnutls*|*libgnutls.a*) link_deps=("-L$SAMBA_PREFIX/lib" -lhogweed -lnettle -lgmp) ;;
esac
if [ "${#all_args}" -gt 20000 ]; then
  response=$(mktemp "${TMPDIR:-/tmp}/samba-clang-XXXXXX.rsp")
  trap 'rm -f "$response"' EXIT
  for arg in --target=aarch64-linux-android28 "--sysroot=$(cygpath -m "$ANDROID_SYSROOT")" "${extra[@]}" "$@" "${link_deps[@]}"; do
    case "$arg" in
      /[a-zA-Z]/*) arg=$(cygpath -m "$arg") ;;
      -I/[a-zA-Z]/*|-L/[a-zA-Z]/*|-o/[a-zA-Z]/*) arg="${arg:0:2}$(cygpath -m "${arg:2}")" ;;
    esac
    arg=${arg//\\/\\\\}
    arg=${arg//\"/\\\"}
    printf '"%s"\n' "$arg" >> "$response"
  done
  if [ -n "${SAMBA_CACHE:-}" ]; then cp "$response" "$SAMBA_CACHE/last-smbclient-link.rsp"; fi
  "$ANDROID_CLANG" "@$(cygpath -m "$response")"
else
  exec "$ANDROID_CLANG" --target=aarch64-linux-android28 --sysroot="$ANDROID_SYSROOT" "${extra[@]}" "$@" "${link_deps[@]}"
fi
