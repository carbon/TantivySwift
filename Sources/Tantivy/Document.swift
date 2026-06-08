import Foundation

/// A typed value in a `Document`. Unlike the `[String: Any]` add path (which
/// `JSONSerialization` rejects `Date` in), this carries `Date` and converts it
/// to RFC3339 on the way to a `date` field.
public enum DocumentValue: Sendable {
    case string(String)
    case int(Int64)
    case unsigned(UInt64)
    case double(Double)
    case bool(Bool)
    case date(Date)
    case array([DocumentValue])
}

extension DocumentValue: ExpressibleByStringLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
}
extension DocumentValue: ExpressibleByIntegerLiteral {
    public init(integerLiteral value: Int64) { self = .int(value) }
}
extension DocumentValue: ExpressibleByFloatLiteral {
    public init(floatLiteral value: Double) { self = .double(value) }
}
extension DocumentValue: ExpressibleByBooleanLiteral {
    public init(booleanLiteral value: Bool) { self = .bool(value) }
}
extension DocumentValue: ExpressibleByArrayLiteral {
    public init(arrayLiteral elements: DocumentValue...) { self = .array(elements) }
}

extension DocumentValue {
    fileprivate func jsonValue() -> Any {
        switch self {
        case .string(let s): return s
        case .int(let i): return i
        case .unsigned(let u): return u
        case .double(let d): return d
        case .bool(let b): return b
        case .date(let date): return date.formatted(.iso8601)
        case .array(let values): return values.map { $0.jsonValue() }
        }
    }

    /// False if this value (or any element) is a non-finite `Double` (NaN/±∞).
    fileprivate var isFinite: Bool {
        switch self {
        case .double(let d): return d.isFinite
        case .array(let values): return values.allSatisfy(\.isFinite)
        default: return true
        }
    }
}

/// A document built with typed values, supporting `Date` and multi-valued fields
/// through literals:
///
/// ```swift
/// var doc = Document()
/// doc["title"] = "Dune"
/// doc["year"] = 1965
/// doc["tags"] = ["sci-fi", "classic"]
/// doc["created"] = .date(Date())
/// try index.add(doc)
/// ```
public struct Document: Sendable {
    public private(set) var fields: [String: DocumentValue] = [:]

    public init() {}

    /// Build from a dictionary of typed values.
    public init(_ fields: [String: DocumentValue]) { self.fields = fields }

    public subscript(_ field: String) -> DocumentValue? {
        get { fields[field] }
        set { fields[field] = newValue }
    }

    /// Set a `Date` value (dates aren't expressible as a literal).
    public mutating func set(_ field: String, _ date: Date) { fields[field] = .date(date) }

    /// The JSON object handed to the FFI (dates rendered as RFC3339). Throws on a
    /// non-finite number rather than letting `JSONSerialization` raise an
    /// uncatchable `NSException`.
    func jsonString() throws(TantivyError) -> String {
        for (name, value) in fields where !value.isFinite {
            throw TantivyError.encoding("field '\(name)' has a non-finite number (NaN/±∞)")
        }
        let object = fields.mapValues { $0.jsonValue() }
        guard let data = try? JSONSerialization.data(withJSONObject: object) else {
            throw TantivyError.encoding("could not serialize document")
        }
        return String(decoding: data, as: UTF8.self)
    }
}

extension IndexWriter {
    /// Add a typed `Document` (handles `Date` and multi-valued fields).
    public func addDocument(_ document: Document) throws(TantivyError) {
        try addDocument(json: document.jsonString())
    }
}

extension Index {
    /// Add a typed `Document` and make it searchable.
    public func add(_ document: Document) throws {
        try write { try $0.addDocument(document) }
    }
    /// Add many typed `Document`s in one commit.
    public func add(contentsOf documents: [Document]) throws {
        try write { writer in for document in documents { try writer.addDocument(document) } }
    }
}
