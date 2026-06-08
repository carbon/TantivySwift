/* The CTantivy target only exposes the C header in include/; the actual
 * implementation lives in the prebuilt Rust static library (libtantivy_ffi.a),
 * which is linked into the final binary via the Tantivy target's linker
 * settings. This translation unit exists solely because SwiftPM requires a
 * clang target to contain at least one compiled source file. */
