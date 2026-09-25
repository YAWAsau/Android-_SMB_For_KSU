#!/usr/bin/env bash
set -euo pipefail
cd "$SAMBA_BUILD_ROOT"

NDK_BIN="$SAMBA_NDK/toolchains/llvm/prebuilt/windows-x86_64/bin"
HOST_BIN="$SAMBA_HOST_TOOL/bin"
export PATH="$SAMBA_YAPP_BIN:$HOST_BIN:$NDK_BIN:/usr/bin:/bin"
export HOME="$SAMBA_CACHE/home"
export TMPDIR="$SAMBA_CACHE/tmp"
export PERL5LIB="$SAMBA_PERL5LIB${PERL5LIB:+:$PERL5LIB}"
export PYTHONHASHSEED=1
mkdir -p "$HOME" "$TMPDIR"

# The smbclient target links Samba, crypto, Bionic and zlib into one static ELF.
export ANDROID_CLANG="$NDK_BIN/clang.exe"
export ANDROID_AR="$NDK_BIN/llvm-ar.exe"
export ANDROID_RANLIB="$NDK_BIN/llvm-ranlib.exe"
export ANDROID_STRIP="$NDK_BIN/llvm-strip.exe"
export ANDROID_SYSROOT="$SAMBA_NDK/toolchains/llvm/prebuilt/windows-x86_64/sysroot"
export CC="bash $SAMBA_REPO/tools/samba_android/clang-wrapper.sh"
export AR="bash $SAMBA_REPO/tools/samba_android/llvm-tool-wrapper.sh ar"
export RANLIB="bash $SAMBA_REPO/tools/samba_android/llvm-tool-wrapper.sh ranlib"
export STRIP="bash $SAMBA_REPO/tools/samba_android/llvm-tool-wrapper.sh strip"
export CFLAGS='-O2 -fPIE'
export LDFLAGS='-pie'
profile=${SAMBA_BUILD_PROFILE:-standard}
targets=client/smbclient,smbd/smbd,samba-dcerpcd,rpcd_classic,rpcd_lsad,rpcd_winreg,compile_et,asn1_compile
server_targets='smbd/smbd rpc_server/samba-dcerpcd rpc_server/rpcd_classic rpc_server/rpcd_lsad rpc_server/rpcd_winreg'
if [ "$profile" = size ]; then
  export CFLAGS='-Os -fPIE -ffunction-sections -fdata-sections -flto=thin'
  export LDFLAGS='-pie -flto=thin'
fi
if [ "${SAMBA_BUILD_SCOPE:-all}" = client ]; then
  targets=client/smbclient,compile_et,asn1_compile
  server_targets=''
fi
export PKG_CONFIG="bash $SAMBA_REPO/tools/samba_android/pkg-config-static.sh"
export PKG_CONFIG_PATH="$SAMBA_PREFIX/lib/pkgconfig"
export PKG_CONFIG_LIBDIR="$SAMBA_PREFIX/lib/pkgconfig"
unset PKG_CONFIG_SYSROOT_DIR

# Android NDK ships zlib as a platform library but does not provide a
# pkg-config file. Samba's Waf checks zlib through pkg-config, so describe the
# NDK's own headers/library rather than using a Windows host zlib.
cat > "$SAMBA_PREFIX/lib/pkgconfig/zlib.pc" <<EOF
prefix=$ANDROID_SYSROOT/usr
exec_prefix=\${prefix}
libdir=\${exec_prefix}/lib/aarch64-linux-android/28
includedir=\${prefix}/include

Name: zlib
Description: Android NDK zlib platform library
Version: 1.3
Libs: -L\${libdir} -lz
Cflags: -I\${includedir}
EOF

# Samba configure describes Android's Linux headers, but hostcc compiles with
# UCRT64. Provide the Linux device-number macros needed by shared replace.h.
mkdir -p "$SAMBA_HOST_TOOL/include/sys"
cat > "$SAMBA_HOST_TOOL/include/sys/sysmacros.h" <<'EOF'
#ifndef SAMBA_HOST_SYSMACROS_H
#define SAMBA_HOST_SYSMACROS_H
#define major(dev) ((((dev) >> 8) & 0xfff) | (((dev) >> 32) & 0xfffff000))
#define minor(dev) (((dev) & 0xff) | (((dev) >> 12) & 0xffffff00))
#define makedev(maj, min) ((((maj) & 0xfff) << 8) | ((min) & 0xff) | \
                           (((unsigned long long)(maj) & 0xfffff000) << 32) | \
                           (((unsigned long long)(min) & 0xffffff00) << 12))
#endif
EOF

# Select Android arm64's Linux per-thread credential syscalls explicitly.
python3 "$SAMBA_REPO/tools/samba_android/patch-samba.py" "$SAMBA_BUILD_ROOT"

if [ ! -f bin/.android-samba-server-configured ]; then
  ./configure \
    --cross-compile \
    --hostcc="bash $SAMBA_REPO/tools/samba_android/hostcc-wrapper.sh" \
    --cross-execute="bash $SAMBA_REPO/tools/samba_android/adb-runner.sh $SAMBA_ADB $SAMBA_DEVICE" \
    --cross-answers="$SAMBA_ANSWERS" \
    --without-ad-dc --without-ads --without-ldap --without-winbind \
    --without-ldb-lmdb \
    --without-acl-support --without-cluster-support --without-pam \
    --without-quotas --without-gpgme --without-regedit --disable-cups \
    --without-libunwind \
    --without-json \
    --without-libarchive \
    --disable-python \
    --bundled-libraries=ALL --with-static-modules=ALL \
    --nonshared-binary=client/smbclient,smbd/smbd,samba-dcerpcd,rpcd_classic,rpcd_lsad,rpcd_winreg
  touch bin/.android-samba-server-configured
fi

# Repair cached host outputs produced before the wrapper normalized .exe names.
for generator in compile_et asn1_compile; do
  host_exe="bin/default/third_party/heimdal_build/$generator.exe"
  if [ -f "$host_exe" ]; then
    if [ ! "$host_exe" -ef "${host_exe%.exe}" ]; then
      cp -f "$host_exe" "${host_exe%.exe}"
    fi
    cp -f "$host_exe" "bin/$generator.exe"
    if [ -f "bin/$generator" ] && [ ! "bin/$generator.exe" -ef "bin/$generator" ]; then
      cp -f "$host_exe" "bin/$generator"
    fi
  fi
done
python3 ./buildtools/bin/waf build --targets="$targets" -j"$(nproc)"
python3 ./buildtools/bin/waf install --destdir="$SAMBA_CACHE/stage" --targets=client/smbclient

SMBCLIENT=bin/default/source3/client/smbclient
test -f "$SMBCLIENT"
"$ANDROID_STRIP" --strip-unneeded "$SMBCLIENT"
elf_program_headers=$("$NDK_BIN/llvm-readelf.exe" -l "$SMBCLIENT")
elf_dynamic=$("$NDK_BIN/llvm-readelf.exe" -d "$SMBCLIENT")
if printf '%s\n%s\n' "$elf_program_headers" "$elf_dynamic" | grep -Eq 'INTERP|NEEDED'; then
  echo 'ERROR: smbclient is not fully static; refusing to publish.' >&2
  exit 1
fi
mkdir -p "$SAMBA_OUT"
for target in $server_targets; do
  binary="bin/default/source3/$target"
  test -f "$binary"
  "$ANDROID_STRIP" --strip-unneeded "$binary"
  if "$NDK_BIN/llvm-readelf.exe" -l -d "$binary" | grep -Eq 'INTERP|NEEDED'; then
    echo "ERROR: $target is not fully static" >&2
    exit 1
  fi
  cp "$binary" "$SAMBA_OUT/${target##*/}"
  "$NDK_BIN/llvm-readelf.exe" -h -l -d -n "$binary" > "$SAMBA_OUT/${target##*/}-elf-static-check.txt"
done
cp "$SMBCLIENT" "$SAMBA_OUT/smbclient"
cp COPYING "$SAMBA_OUT/COPYING.txt"
cp "$SAMBA_ANSWERS" "$SAMBA_OUT/cross-answers.txt"
printf '%s\n' "$SAMBA_VERSION" > "$SAMBA_OUT/source-version.txt"
file "$SAMBA_OUT/smbclient"
"$NDK_BIN/llvm-readelf.exe" -h "$SMBCLIENT" | grep -E 'Class:|Machine:'
printf '%s\n' 'Verified: no PT_INTERP and no DT_NEEDED (fully static).'
printf '%s\n%s\n' "$elf_program_headers" "$elf_dynamic" > "$SAMBA_OUT/elf-static-check.txt"
"$NDK_BIN/llvm-readelf.exe" -n "$SMBCLIENT" >> "$SAMBA_OUT/elf-static-check.txt"

SMBCLIENT_WIN=$(cygpath -w "$SMBCLIENT")
export MSYS2_ARG_CONV_EXCL='*'
MSYS_NO_PATHCONV=1 "$SAMBA_ADB" -s "$SAMBA_DEVICE" push "$SMBCLIENT_WIN" /data/local/tmp/smbclient-codex-test >/dev/null
MSYS_NO_PATHCONV=1 "$SAMBA_ADB" -s "$SAMBA_DEVICE" shell chmod 755 /data/local/tmp/smbclient-codex-test
MSYS_NO_PATHCONV=1 "$SAMBA_ADB" -s "$SAMBA_DEVICE" shell /data/local/tmp/smbclient-codex-test --version
MSYS_NO_PATHCONV=1 "$SAMBA_ADB" -s "$SAMBA_DEVICE" shell rm -f /data/local/tmp/smbclient-codex-test
