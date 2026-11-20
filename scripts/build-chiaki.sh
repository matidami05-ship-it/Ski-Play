#!/bin/bash
# Cross-compiles chiaki-ng's Remote Play library and its dependencies for iPhone (arm64)
# and leaves one static library plus headers in Vendor/. Runs on a macOS CI runner.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$ROOT/.deps"
PREFIX="$WORK/prefix"
OUT="$ROOT/Vendor"
MIN_IOS=16.0
JOBS=$(sysctl -n hw.ncpu)

CHIAKI_COMMIT=43728af2e639fecb8a7af1cd68c29820a40de973
OPENSSL_VER=3.3.2
OPUS_VER=1.5.2
LIBEVENT_VER=2.1.12

mkdir -p "$WORK" "$PREFIX"
cd "$WORK"

# Python env with an older CMake (some dependencies still declare very old minimum versions)
# and the protobuf module that nanopb's generator needs.
if [ ! -x "$WORK/venv/bin/cmake" ]; then
  python3 -m venv "$WORK/venv"
  "$WORK/venv/bin/pip" install -q "cmake>=3.28,<4" protobuf
fi
export PATH="$WORK/venv/bin:$PATH"
command -v protoc || brew install protobuf
command -v pkg-config || brew install pkgconf
cmake --version | head -1

IOS_CMAKE=(
  -DCMAKE_SYSTEM_NAME=iOS
  -DCMAKE_OSX_SYSROOT=iphoneos
  -DCMAKE_OSX_ARCHITECTURES=arm64
  -DCMAKE_OSX_DEPLOYMENT_TARGET=$MIN_IOS
  -DCMAKE_BUILD_TYPE=Release
  -DCMAKE_INSTALL_PREFIX="$PREFIX"
  -DCMAKE_PREFIX_PATH="$PREFIX"
  -DBUILD_SHARED_LIBS=OFF
  -DCMAKE_POLICY_VERSION_MINIMUM=3.5
)

fetch() { # url dir
  if [ ! -d "$2" ]; then
    curl -fsSL "$1" -o "$2.tar.gz"
    mkdir "$2" && tar -xzf "$2.tar.gz" -C "$2" --strip-components=1
  fi
}

# ---------- OpenSSL ----------
if [ ! -f "$PREFIX/lib/libcrypto.a" ]; then
  echo "::group::OpenSSL"
  fetch "https://github.com/openssl/openssl/releases/download/openssl-$OPENSSL_VER/openssl-$OPENSSL_VER.tar.gz" openssl
  (cd openssl && ./Configure ios64-xcrun no-shared no-tests no-apps no-docs no-engine no-async \
      --prefix="$PREFIX" --libdir=lib -mios-version-min=$MIN_IOS \
    && make -j"$JOBS" build_libs && make install_dev)
  echo "::endgroup::"
fi

# ---------- Opus ----------
if [ ! -f "$PREFIX/lib/libopus.a" ]; then
  echo "::group::Opus"
  fetch "https://downloads.xiph.org/releases/opus/opus-$OPUS_VER.tar.gz" opus
  cmake -S opus -B opus/build "${IOS_CMAKE[@]}" -DOPUS_BUILD_TESTING=OFF -DOPUS_BUILD_PROGRAMS=OFF -DOPUS_INSTALL_PKG_CONFIG_MODULE=ON
  cmake --build opus/build -j"$JOBS" && cmake --install opus/build
  echo "::endgroup::"
fi

# ---------- libevent ----------
if [ ! -f "$PREFIX/lib/libevent.a" ]; then
  echo "::group::libevent"
  fetch "https://github.com/libevent/libevent/releases/download/release-$LIBEVENT_VER-stable/libevent-$LIBEVENT_VER-stable.tar.gz" libevent
  cmake -S libevent -B libevent/build "${IOS_CMAKE[@]}" \
    -DEVENT__LIBRARY_TYPE=STATIC -DEVENT__DISABLE_OPENSSL=ON -DEVENT__DISABLE_MBEDTLS=ON \
    -DEVENT__DISABLE_TESTS=ON -DEVENT__DISABLE_REGRESS=ON -DEVENT__DISABLE_SAMPLES=ON \
    -DEVENT__DISABLE_BENCHMARK=ON -DEVENT__DISABLE_DEBUG_MODE=ON \
    -DEVENT__HAVE_WORKING_KQUEUE=1
  cmake --build libevent/build -j"$JOBS" && cmake --install libevent/build
  echo "::endgroup::"
fi

# ---------- chiaki-ng ----------
echo "::group::chiaki-ng"
if [ ! -d chiaki-ng/.git ]; then
  git init -q chiaki-ng
  git -C chiaki-ng remote add origin https://github.com/streetpea/chiaki-ng.git
fi
if [ "$(git -C chiaki-ng rev-parse HEAD 2>/dev/null || true)" != "$CHIAKI_COMMIT" ]; then
  git -C chiaki-ng fetch -q --depth 1 origin "$CHIAKI_COMMIT"
  git -C chiaki-ng checkout -q -f FETCH_HEAD
fi
git -C chiaki-ng submodule update -q --init --depth 1 third-party/nanopb third-party/jerasure third-party/gf-complete third-party/curl

# chiaki forces the deployment target to the build Mac's macOS version; skip that for iOS.
sed -i '' 's/^if(APPLE)$/if(APPLE AND NOT IOS)/' chiaki-ng/CMakeLists.txt
# libevent lookup calls pkg_search_module without initializing pkg-config first.
sed -i '' 's/find_program(PKG_CONFIG_EXECUTABLE pkg-config)/find_package(PkgConfig)/' chiaki-ng/lib/CMakeLists.txt

export PKG_CONFIG_LIBDIR="$PREFIX/lib/pkgconfig"
cmake -S chiaki-ng -B chiaki-ng/build-ios "${IOS_CMAKE[@]}" \
  -DCHIAKI_ENABLE_TESTS=OFF -DCHIAKI_ENABLE_CLI=OFF -DCHIAKI_ENABLE_GUI=OFF \
  -DCHIAKI_ENABLE_SETSU=OFF -DCHIAKI_ENABLE_STEAMDECK_NATIVE=OFF -DCHIAKI_ENABLE_STEAM_SHORTCUT=OFF \
  -DCHIAKI_ENABLE_FFMPEG_DECODER=OFF -DCHIAKI_ENABLE_PI_DECODER=OFF -DCHIAKI_ENABLE_SPEEX=OFF \
  -DCHIAKI_LIB_ENABLE_OPUS=ON -DCHIAKI_USE_SYSTEM_JERASURE=OFF -DCHIAKI_USE_SYSTEM_NANOPB=OFF \
  -DCHIAKI_USE_SYSTEM_CURL=OFF \
  -DCHIAKI_LIB_JSONC_EXTERNAL_PROJECT=ON -DCHIAKI_LIB_MINIUPNPC_EXTERNAL_PROJECT=ON \
  -DOpus_INCLUDE_DIRS="$PREFIX/include" -DOpus_LIBRARIES="$PREFIX/lib/libopus.a" \
  -DOPENSSL_ROOT_DIR="$PREFIX" -DOPENSSL_USE_STATIC_LIBS=ON \
  -DOPENSSL_INCLUDE_DIR="$PREFIX/include" \
  -DOPENSSL_CRYPTO_LIBRARY="$PREFIX/lib/libcrypto.a" -DOPENSSL_SSL_LIBRARY="$PREFIX/lib/libssl.a" \
  -DPROTOC="$(command -v protoc)" -DPYTHON_EXECUTABLE="$WORK/venv/bin/python3" \
  -DCURL_USE_OPENSSL=ON -DCURL_USE_LIBPSL=OFF -DCURL_USE_LIBSSH2=OFF -DUSE_LIBIDN2=OFF \
  -DCURL_ZLIB=OFF -DCURL_BROTLI=OFF -DCURL_ZSTD=OFF -DUSE_NGHTTP2=OFF -DCURL_DISABLE_LDAP=ON \
  -DCURL_CA_BUNDLE=none -DCURL_CA_PATH=none -DENABLE_UNIX_SOCKETS=OFF
cmake --build chiaki-ng/build-ios --target chiaki-lib -j"$JOBS"
echo "::endgroup::"

# ---------- Collect ----------
rm -rf "$OUT" && mkdir -p "$OUT/include" "$OUT/lib"
cp -R chiaki-ng/lib/include/chiaki "$OUT/include/"
cp chiaki-ng/build-ios/lib/include/chiaki/config.h "$OUT/include/chiaki/"

LIBS=()
while IFS= read -r a; do LIBS+=("$a"); done < <(find chiaki-ng/build-ios -name '*.a')
LIBS+=("$PREFIX/lib/libssl.a" "$PREFIX/lib/libcrypto.a" "$PREFIX/lib/libopus.a" "$PREFIX/lib/libevent.a")
printf '  %s\n' "${LIBS[@]}"
libtool -static -no_warning_for_no_symbols -o "$OUT/lib/libchiakiall.a" "${LIBS[@]}" 2>&1 | grep -v "same member name" || true
ls -la "$OUT/lib"
echo "chiaki-ng $CHIAKI_COMMIT built for iOS $MIN_IOS"
