import Foundation

/// A stored field value returned in a search hit.
///
/// tantivy stores every field as a list of values. Integers are preserved
/// exactly across the full `i64` *and* `u64` ranges: values up to `Int64.max`
/// decode as `.int`, larger unsigned values as `.unsigned`.
public enum FieldValue: Equatable, Sendable, CustomStringConvertible {
    case string(String)
    case int(Int64)
    case unsigned(UInt64)
    case double(Double)
    case bool(Bool)

    public var description: String {
        switch self {
        case .string(let s): return s
        case .int(let i): return String(i)
        case .unsigned(let u): return String(u)
        case .double(let d): return String(d)
        case .bool(let b): return String(b)
        }
    }
}

extension FieldValue: Decodable {
    /// Decode a single JSON scalar from tantivy's result, preserving exact
    /// integer precision across the full `i64` and `u64` ranges.
    ///
    /// Order matters: `Bool` first (Foundation's `JSONDecoder` accepts only
    /// `true`/`false` here, never `0`/`1`), then `Int64`, then `UInt64` for
    /// values above `Int64.max`, then `Double`, then `String`. A whole-valued
    /// `f64` such as `4.0` is categorized as `.int(4)`; read numeric fields
    /// through the accessors (`double`, `int`, `uint`), which coerce, rather
    /// than pattern-matching the raw case.
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let b = try? c.decode(Bool.self) { self = .bool(b); return }
        if let i = try? c.decode(Int64.self) { self = .int(i); return }
        if let u = try? c.decode(UInt64.self) { self = .unsigned(u); return }
        if let d = try? c.decode(Double.self) { self = .double(d); return }
        if let s = try? c.decode(String.self) { self = .string(s); return }
        throw DecodingError.dataCorruptedError(
            in: c, debugDescription: "unsupported tantivy field value")
    }
}

/// One search result: its relevance score and the stored fields of the matched
/// document.
public struct SearchHit: Sendable {
    /// BM25 / tf-idf relevance score (higher is better).
    public let score: Float
    /// Stored fields, keyed by field name. Each field is an array of values.
    public let fields: [String: [FieldValue]]
    /// Highlighted HTML snippets per field, for fields passed to `highlight:`
    /// (empty otherwise). Matched terms are wrapped in `<b>…</b>`.
    public let snippets: [String: String]

    init(score: Float, fields: [String: [FieldValue]], snippets: [String: String] = [:]) {
        self.score = score
        self.fields = fields
        self.snippets = snippets
    }

    /// The highlighted HTML snippet for `name`, if one was generated.
    public func snippet(_ name: String) -> String? { snippets[name] }

    /// All values for `name` (empty if absent / not stored).
    public subscript(_ name: String) -> [FieldValue] { fields[name] ?? [] }

    /// First string value of `name`, if any.
    public func string(_ name: String) -> String? {
        for v in self[name] { if case .string(let s) = v { return s } }
        return nil
    }

    /// First value of `name` as a signed integer, if one fits.
    public func int(_ name: String) -> Int64? {
        for v in self[name] {
            switch v {
            case .int(let i): return i
            case .unsigned(let u): if u <= UInt64(Int64.max) { return Int64(u) }
            case .double(let d): if let i = Int64(exactly: d.rounded(.towardZero)) { return i }
            default: break
            }
        }
        return nil
    }

    /// First value of `name` as an unsigned integer, if one fits.
    public func uint(_ name: String) -> UInt64? {
        for v in self[name] {
            switch v {
            case .unsigned(let u): return u
            case .int(let i): if i >= 0 { return UInt64(i) }
            case .double(let d): if d >= 0, let u = UInt64(exactly: d.rounded(.towardZero)) { return u }
            default: break
            }
        }
        return nil
    }

    /// First floating-point value of `name`, if any (ints/uints are widened).
    public func double(_ name: String) -> Double? {
        for v in self[name] {
            switch v {
            case .double(let d): return d
            case .int(let i): return Double(i)
            case .unsigned(let u): return Double(u)
            default: break
            }
        }
        return nil
    }

    /// First boolean value of `name`, if any.
    public func bool(_ name: String) -> Bool? {
        for v in self[name] { if case .bool(let b) = v { return b } }
        return nil
    }
}
