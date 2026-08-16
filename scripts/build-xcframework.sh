#!/usr/bin/env bash
#
# Cross-compile the Rust FFI library for every Apple platform we ship and
# assemble artifacts/CTantivy.xcframework. This is the redistributable that
# makes the Swift package work on macOS, iOS and iPadOS (device + simulator).
#
# Requirements: full Xcode (not just Command Line Tools) and rustup.
# If your active developer dir is the CLT, point this at Xcode, e.g.:
#   DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer scripts/build-xcframework.sh

set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"

# --- sanity: need Xcode, not just CLT ---------------------------------------
if ! xcodebuild -version >/dev/null 2>&1; then
  echo "error: xcodebuild not available. Install Xcode and/or set DEVELOPER_DIR" >&2
  echo "       e.g. DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer $0" >&2
  exit 1
fi
echo "==> Using $(xcodebuild -version | head -1) ($(xcode-select -p))"

# --- single-instance lock ----------------------------------------------------
# Two concurrent runs share rust/target and both race to delete and recreate
# $OUT, which can leave a half-written xcframework for release.sh to publish.
# cargo locks its own build directory, but nothing guards the assembly step.
# mkdir is atomic everywhere; flock is not available on stock macOS.
LOCK="$ROOT/.xcframework-build.lock"
if ! mkdir "$LOCK" 2>/dev/null; then
  echo "error: another xcframework build is already running." >&2
  echo "       lock: $LOCK" >&2
  echo "       if no build is running, the lock is stale: rmdir '$LOCK'" >&2
  exit 1
fi
trap 'rmdir "$LOCK" 2>/dev/null || true' EXIT

# Deployment targets baked into the object files; match Package.swift's platforms.
export MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-15.0}"
export IPHONEOS_DEPLOYMENT_TARGET="${IPHONEOS_DEPLOYMENT_TARGET:-18.0}"

LIB=libtantivy_ffi.a
HEADERS="$ROOT/Sources/CTantivy/include"   # ctantivy.h + module.modulemap (module CTantivy)
BUILD="$ROOT/.xcframework-build"
OUT="$ROOT/artifacts/CTantivy.xcframework"

# Rust targets, grouped by the XCFramework slice they belong to.
MACOS_TARGETS=(aarch64-apple-darwin x86_64-apple-darwin)
IOS_TARGETS=(aarch64-apple-ios)                          # device
IOSSIM_TARGETS=(aarch64-apple-ios-sim x86_64-apple-ios)  # simulator (arm64 + Intel)
CATALYST_TARGETS=(aarch64-apple-ios-macabi x86_64-apple-ios-macabi)  # Mac Catalyst
ALL_TARGETS=("${MACOS_TARGETS[@]}" "${IOS_TARGETS[@]}" "${IOSSIM_TARGETS[@]}" "${CATALYST_TARGETS[@]}")

echo "==> Ensuring rust targets are installed"
rustup target add "${ALL_TARGETS[@]}"

echo "==> Compiling for each target"
for t in "${ALL_TARGETS[@]}"; do
  echo "    - $t"
  # IPHONEOS_DEPLOYMENT_TARGET=18.0 is a valid floor for the macabi triples too.
  ( cd rust && cargo build --release --target "$t" )
done

# --- combine same-platform arches with lipo ---------------------------------
rm -rf "$BUILD" "$OUT"
mkdir -p "$BUILD"

lipo_slice() {  # <out-name> <triple...>
  local name="$1"; shift
  local inputs=()
  for t in "$@"; do inputs+=("rust/target/$t/release/$LIB"); done
  if [ "${#inputs[@]}" -eq 1 ]; then
    cp "${inputs[0]}" "$BUILD/$name"
  else
    lipo -create "${inputs[@]}" -output "$BUILD/$name"
  fi
  echo "    $name: $(lipo -archs "$BUILD/$name")"
}

echo "==> Creating fat libraries"
lipo_slice "libtantivy_macos.a"      "${MACOS_TARGETS[@]}"
lipo_slice "libtantivy_ios.a"        "${IOS_TARGETS[@]}"
lipo_slice "libtantivy_iossim.a"     "${IOSSIM_TARGETS[@]}"
lipo_slice "libtantivy_maccatalyst.a" "${CATALYST_TARGETS[@]}"

# --- assemble the xcframework ------------------------------------------------
# xcodebuild infers each slice's platform/variant from the object files, so the
# macabi library lands as an "ios-…-maccatalyst" slice automatically.
echo "==> Creating $OUT"
mkdir -p "$ROOT/artifacts"
xcodebuild -create-xcframework \
  -library "$BUILD/libtantivy_macos.a"       -headers "$HEADERS" \
  -library "$BUILD/libtantivy_ios.a"         -headers "$HEADERS" \
  -library "$BUILD/libtantivy_iossim.a"      -headers "$HEADERS" \
  -library "$BUILD/libtantivy_maccatalyst.a" -headers "$HEADERS" \
  -output "$OUT"

rm -rf "$BUILD"
echo
echo "==> Built $OUT"
echo "    Package.swift will now consume it as a binary target (distribution mode)."
ls "$OUT"
