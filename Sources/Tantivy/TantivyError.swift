import Foundation

/// Errors surfaced by the Swift wrapper around the tantivy C library.
public enum TantivyError: Error, Sendable, CustomStringConvertible {
    /// An error reported by the underlying tantivy/FFI layer.
    case ffi(String)
    /// A document or schema could not be encoded to / decoded from JSON.
    case encoding(String)

    public var description: String {
        switch self {
        case .ffi(let m): return "tantivy: \(m)"
        case .encoding(let m): return "tantivy encoding: \(m)"
        }
    }

    /// The underlying message, without the `tantivy:` prefix.
    public var message: String {
        switch self {
        case .ffi(let m), .encoding(let m): return m
        }
    }

    /// True if this is a Swift-side encode/decode failure rather than an error
    /// from the tantivy engine.
    public var isEncoding: Bool {
        if case .encoding = self { return true }
        return false
    }
}

extension TantivyError: LocalizedError {
    /// So `error.localizedDescription` and SwiftUI error surfaces read well.
    public var errorDescription: String? { description }
}
