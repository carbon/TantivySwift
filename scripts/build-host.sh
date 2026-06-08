#!/usr/bin/env bash
#
# Build the Rust static library for the host Mac only.
#
# This backs "host/dev mode": with no XCFramework present, Package.swift links
# directly against rust/target/release/libtantivy_ffi.a so you can run
# `swift build` / `swift test` locally. For a redistributable, multi-platform
# package, run build-xcframework.sh instead.

set -euo pipefail
cd "$(dirname "$0")/.."

# Match Package.swift's minimum so the linker doesn't warn about version skew.
export MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-15.0}"

echo "==> Building libtantivy_ffi.a for the host ($(uname -m))"
( cd rust && cargo build --release )

echo "==> Done: rust/target/release/libtantivy_ffi.a"
