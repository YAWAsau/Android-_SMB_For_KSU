#!/usr/bin/env bash
set -euo pipefail

NDK_BIN="$SAMBA_NDK/toolchains/llvm/prebuilt/windows-x86_64/bin"
export PATH="$SAMBA_HOST_TOOL/bin:$NDK_BIN:/usr/bin:/bin"
export ANDROID_CLANG="$NDK_BIN/clang.exe"
export ANDROID_AR="$NDK_BIN/llvm-ar.exe"
export ANDROID_RANLIB="$NDK_BIN/llvm-ranlib.exe"
export ANDROID_STRIP="$NDK_BIN/llvm-strip.exe"
export ANDROID_SYSROOT="$SAMBA_NDK/toolchains/llvm/prebuilt/windows-x86_64/sysroot"
export CC="bash $SAMBA_REPO/tools/samba_android/clang-wrapper.sh"
export AR="bash $SAMBA_REPO/tools/samba_android/llvm-tool-wrapper.sh ar"
export RANLIB="bash $SAMBA_REPO/tools/samba_android/llvm-tool-wrapper.sh ranlib"
export CFLAGS='-O2 -fPIC'
export CPPFLAGS="-I$SAMBA_PREFIX/include"
export LDFLAGS="-L$SAMBA_PREFIX/lib"
export PKG_CONFIG_PATH="$SAMBA_PREFIX/lib/pkgconfig"
export PKG_CONFIG_LIBDIR="$SAMBA_PREFIX/lib/pkgconfig"
unset PKG_CONFIG_SYSROOT_DIR
export PKG_CONFIG=/usr/bin/pkg-config
export CC_FOR_BUILD="$SAMBA_HOST_TOOL/bin/x86_64-w64-mingw32-gcc.exe"
export MAKEINFO=true
HOST_CC="$SAMBA_HOST_TOOL/bin/x86_64-w64-mingw32-gcc.exe --sysroot=$SAMBA_HOST_TOOL -I$SAMBA_HOST_TOOL/include -L$SAMBA_HOST_TOOL/lib -L$SAMBA_HOST_TOOL/x86_64-w64-mingw32/lib"
JOBS=${SAMBA_JOBS:-4}
SRC="$SAMBA_DEPS_SOURCE"

mkdir -p "$SAMBA_PREFIX"

if [ ! -f "$SAMBA_PREFIX/lib/libgmp.a" ]; then
  cd "$SRC/gmp-6.3.0"
  if [ ! -f Makefile ]; then
    ./configure --host=aarch64-linux-android --prefix="$SAMBA_PREFIX" \
      --enable-static --disable-shared --with-pic
  fi
  make -j"$JOBS"
  make install
fi

if [ ! -f "$SAMBA_PREFIX/lib/libnettle.a" ] || [ ! -f "$SAMBA_PREFIX/lib/libhogweed.a" ]; then
  cd "$SRC/nettle-3.10.2"
  if [ ! -f Makefile ]; then
    ./configure --host=aarch64-linux-android --prefix="$SAMBA_PREFIX" \
      --enable-static --disable-shared --disable-documentation \
      --disable-openssl --with-pic
  fi
  # Release tarballs contain generator stamps, but not Windows executables.
  # Build the host tools explicitly before make can regenerate any headers.
  make -j"$JOBS" aesdata.exe desdata.exe twofishdata.exe shadata.exe eccdata.exe \
    EXEEXT_FOR_BUILD=.exe CC_FOR_BUILD="$HOST_CC"
  make -j"$JOBS" EXEEXT_FOR_BUILD=.exe CC_FOR_BUILD="$HOST_CC"
  make install EXEEXT_FOR_BUILD=.exe CC_FOR_BUILD="$HOST_CC"
fi

if [ ! -f "$SAMBA_PREFIX/lib/libgnutls.a" ]; then
  cd "$SRC/gnutls-3.8.13"
  if [ ! -f .samba-configured ]; then
    CXX=false ./configure --host=aarch64-linux-android --prefix="$SAMBA_PREFIX" \
      --enable-static --disable-shared --disable-cxx --disable-doc \
      --disable-maintainer-mode --disable-dependency-tracking --disable-nls \
      --disable-tools --disable-tests --disable-libdane \
      --disable-openssl-compatibility --without-p11-kit --without-tpm \
      --without-zlib --without-brotli --without-zstd \
      --with-included-libtasn1 --with-included-unistring
    touch .samba-configured
  fi
  if [ -f libtool ]; then
    LIBTOOL_MACRO_VERSION=$(sed -n 's/^macro_version=\([^[:space:]]*\)$/\1/p' libtool | head -n 1)
    if [ -n "$LIBTOOL_MACRO_VERSION" ]; then
      sed -i "s/^VERSION=.*/VERSION=$LIBTOOL_MACRO_VERSION/; s/^package_revision=.*/package_revision=$LIBTOOL_MACRO_VERSION/" libtool
    fi
  fi
  make -j"$JOBS" EXEEXT_FOR_BUILD=.exe CC_FOR_BUILD="$HOST_CC"
  make install EXEEXT_FOR_BUILD=.exe CC_FOR_BUILD="$HOST_CC"
fi

test -f "$SAMBA_PREFIX/lib/libgmp.a"
test -f "$SAMBA_PREFIX/lib/libnettle.a"
test -f "$SAMBA_PREFIX/lib/libhogweed.a"
test -f "$SAMBA_PREFIX/lib/libgnutls.a"
"$PKG_CONFIG" --static --cflags --libs gnutls
