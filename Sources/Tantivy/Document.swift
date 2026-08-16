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
    /// A value for a `bytes` field. Unlike every other case this never enters
    /// the JSON handed to the engine — it travels as raw memory alongside it.
    case bytes(Data)
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

    /// Set a `bytes` value (`Data` isn't expressible as a literal either).
    public mutating func set(_ field: String, _ data: Data) { fields[field] = .bytes(data) }

    /// The MessagePack payload handed to the FFI. Every value type — dates as
    /// RFC3339 strings, bytes as native byte strings — travels in one buffer.
    func encoded() throws(TantivyError) -> [UInt8] {
        var normalized: [String: [DocumentValue]] = [:]
        normalized.reserveCapacity(fields.count)
        for (name, value) in fields {
            if case .array(let values) = value {
                normalized[name] = values
            } else {
                normalized[name] = [value]
            }
        }
        return try MessagePackWriter.document(normalized)
    }
}

extension IndexWriter {
    /// Add a typed `Document` (handles `Date`, `Data`, and multi-valued fields).
    public func addDocument(_ document: Document) throws(TantivyError) {
        try addDocument(messagePack: document.encoded())
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
