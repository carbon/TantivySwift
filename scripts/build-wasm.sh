#!/usr/bin/env bash
#
# Build the engine as WebAssembly for the JavaScript package in js/.
#
# The same Rust library the Swift package links, compiled for wasm32-wasip1
# with:
#   * --no-default-features: no memory-mapped (on-disk) indexes and no zstd,
#     which is C and would need a WASI C toolchain;
#   * --features single-threaded: the writer that indexes, merges and
#     compresses on the calling thread, since there are no threads to spawn;
#   * --crate-type cdylib: a module exporting the C ABI, in place of the
#     static library Swift links;
#   * symbols stripped: the name section is ~550 KB and only labels stack
#     frames. opt-level stays 3 — "s" saves ~280 KB gzipped but searches
#     ~1.6x slower.
#
# Writes js/dist/tantivy.wasm. Needs the target: rustup target add wasm32-wasip1

set -euo pipefail
cd "$(dirname "$0")/.."

TARGET=wasm32-wasip1

echo "==> Building tantivy_ffi.wasm ($TARGET, single-threaded)"
( cd rust && CARGO_PROFILE_RELEASE_STRIP=symbols cargo rustc --release --target "$TARGET" \
    --no-default-features --features single-threaded --crate-type cdylib )

mkdir -p js/dist
cp "rust/target/$TARGET/release/tantivy_ffi.wasm" js/dist/tantivy.wasm

echo "==> Done: js/dist/tantivy.wasm ($(wc -c < js/dist/tantivy.wasm | tr -d ' ') bytes)"
