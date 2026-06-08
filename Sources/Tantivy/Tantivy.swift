import CTantivy

/// Namespace for library-level metadata.
public enum Tantivy {
    /// Version string of the wrapped tantivy release and FFI shim,
    /// e.g. `"tantivy 0.26.1 / tantivy_ffi 0.1.0"`.
    public static var version: String { String(cString: tantivy_version()) }
}
