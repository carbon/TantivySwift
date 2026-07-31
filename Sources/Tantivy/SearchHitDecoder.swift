// A `Decoder` that maps a search hit's stored fields onto a `Decodable` model.
//
// tantivy stores every field as a *list* of values, even single-valued ones.
// Rather than guess whether a given field is scalar or multi-valued, we let the
// model decide: a scalar property reads the field's first value, an array
// property reads them all (and an array property of one element still works).
// Missing / empty fields decode as `nil` for optional properties.

import Foundation

/// RFC3339 parsing for `date` fields (tantivy emits/accepts RFC3339). Tries
/// without then with fractional seconds. Uses the value-type, `Sendable`
/// `Date.ISO8601FormatStyle`, so the parsers are shared `static let`s (no
/// per-call allocation) and safe across the concurrent search path.
private enum DateParsing {
    private static let plain = Date.ISO8601FormatStyle()
    private static let fractional = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    static func date(from s: String) -> Date? {
        if let d = try? plain.parse(s) { return d }
        return try? fractional.parse(s)
    }
}

/// Conversions from a `FieldValue` to a concrete Swift scalar, raising a
/// `DecodingError` on a type/range mismatch.
private enum Convert {
    static func string(_ v: FieldValue, _ path: [CodingKey]) throws -> String {
        if case .string(let s) = v { return s }
        throw mismatch(String.self, v, path)
    }
    static func bool(_ v: FieldValue, _ path: [CodingKey]) throws -> Bool {
        if case .bool(let b) = v { return b }
        throw mismatch(Bool.self, v, path)
    }
    static func date(_ v: FieldValue, _ path: [CodingKey]) throws -> Date {
        if case .string(let s) = v, let d = DateParsing.date(from: s) { return d }
        throw mismatch(Date.self, v, path)
    }
    static func double(_ v: FieldValue, _ path: [CodingKey]) throws -> Double {
        switch v {
        case .double(let d): return d
        case .int(let i): return Double(i)
        case .unsigned(let u): return Double(u)
        default: throw mismatch(Double.self, v, path)
        }
    }
    /// Narrow to `Float`, rejecting a finite `f64` that overflows it. Plain
    /// `Float(1e300)` is `+infinity`, so without this check an out-of-range
    /// value decodes as an infinity instead of throwing — unlike every integer
    /// conversion here, which range-checks via `exactly:`.
    static func float(_ v: FieldValue, _ path: [CodingKey]) throws -> Float {
        let d = try double(v, path)
        let f = Float(d)
        guard f.isFinite || !d.isFinite else { throw mismatch(Float.self, v, path) }
        return f
    }
    static func int64(_ v: FieldValue, _ path: [CodingKey]) throws -> Int64 {
        switch v {
        case .int(let i): return i
        case .unsigned(let u): if let i = Int64(exactly: u) { return i }
        case .double(let d): if let i = Int64(exactly: d.rounded(.towardZero)) { return i }
        default: break
        }
        throw mismatch(Int64.self, v, path)
    }
    static func uint64(_ v: FieldValue, _ path: [CodingKey]) throws -> UInt64 {
        switch v {
        case .unsigned(let u): return u
        case .int(let i): if let u = UInt64(exactly: i) { return u }
        case .double(let d): if d >= 0, let u = UInt64(exactly: d.rounded(.towardZero)) { return u }
        default: break
        }
        throw mismatch(UInt64.self, v, path)
    }
    static func signed<T: FixedWidthInteger & SignedInteger>(_ v: FieldValue, _ path: [CodingKey]) throws -> T {
        guard let r = T(exactly: try int64(v, path)) else { throw mismatch(T.self, v, path) }
        return r
    }
    static func unsigned<T: FixedWidthInteger & UnsignedInteger>(_ v: FieldValue, _ path: [CodingKey]) throws -> T {
        guard let r = T(exactly: try uint64(v, path)) else { throw mismatch(T.self, v, path) }
        return r
    }
    static func mismatch(_ t: Any.Type, _ v: FieldValue, _ path: [CodingKey]) -> DecodingError {
        DecodingError.typeMismatch(t, .init(
            codingPath: path, debugDescription: "cannot decode \(t) from field value \(v)"))
    }
}

extension SearchHit {
    /// Decode this hit's stored fields into a `Decodable` model.
    ///
    /// Scalar properties read a field's first stored value; array properties
    /// read every value. Optional properties become `nil` when the field is
    /// absent or not stored. Throws `DecodingError` on a type/range mismatch.
    public func decode<T: Decodable>(_ type: T.Type = T.self) throws -> T {
        try T(from: FieldsDecoder(fields: fields, codingPath: []))
    }
}

// MARK: - Top-level decoder over [String: [FieldValue]]

private struct FieldsDecoder: Decoder {
    let fields: [String: [FieldValue]]
    let codingPath: [CodingKey]
    var userInfo: [CodingUserInfoKey: Any] { [:] }

    func container<Key: CodingKey>(keyedBy type: Key.Type) -> KeyedDecodingContainer<Key> {
        KeyedDecodingContainer(FieldsKeyed(fields: fields, codingPath: codingPath))
    }
    func unkeyedContainer() throws -> UnkeyedDecodingContainer {
        throw DecodingError.typeMismatch([Any].self, .init(
            codingPath: codingPath, debugDescription: "a search hit decodes as an object, not an array"))
    }
    func singleValueContainer() throws -> SingleValueDecodingContainer {
        throw DecodingError.typeMismatch(Any.self, .init(
            codingPath: codingPath, debugDescription: "a search hit decodes as an object"))
    }
}

private struct FieldsKeyed<Key: CodingKey>: KeyedDecodingContainerProtocol {
    let fields: [String: [FieldValue]]
    let codingPath: [CodingKey]
    var allKeys: [Key] { fields.keys.compactMap(Key.init(stringValue:)) }

    private func values(_ key: Key) -> [FieldValue] { fields[key.stringValue] ?? [] }
    private func path(_ key: Key) -> [CodingKey] { codingPath + [key] }
    private func first(_ key: Key) throws -> FieldValue {
        guard let v = values(key).first else {
            throw DecodingError.keyNotFound(key, .init(
                codingPath: codingPath, debugDescription: "no value for '\(key.stringValue)'"))
        }
        return v
    }

    func contains(_ key: Key) -> Bool { !(values(key).isEmpty) }
    func decodeNil(forKey key: Key) throws -> Bool { values(key).isEmpty }

    func decode(_ type: Bool.Type, forKey key: Key) throws -> Bool { try Convert.bool(first(key), path(key)) }
    func decode(_ type: String.Type, forKey key: Key) throws -> String { try Convert.string(first(key), path(key)) }
    func decode(_ type: Double.Type, forKey key: Key) throws -> Double { try Convert.double(first(key), path(key)) }
    func decode(_ type: Float.Type, forKey key: Key) throws -> Float { try Convert.float(first(key), path(key)) }
    func decode(_ type: Int.Type, forKey key: Key) throws -> Int { try Convert.signed(first(key), path(key)) }
    func decode(_ type: Int8.Type, forKey key: Key) throws -> Int8 { try Convert.signed(first(key), path(key)) }
    func decode(_ type: Int16.Type, forKey key: Key) throws -> Int16 { try Convert.signed(first(key), path(key)) }
    func decode(_ type: Int32.Type, forKey key: Key) throws -> Int32 { try Convert.signed(first(key), path(key)) }
    func decode(_ type: Int64.Type, forKey key: Key) throws -> Int64 { try Convert.int64(first(key), path(key)) }
    func decode(_ type: UInt.Type, forKey key: Key) throws -> UInt { try Convert.unsigned(first(key), path(key)) }
    func decode(_ type: UInt8.Type, forKey key: Key) throws -> UInt8 { try Convert.unsigned(first(key), path(key)) }
    func decode(_ type: UInt16.Type, forKey key: Key) throws -> UInt16 { try Convert.unsigned(first(key), path(key)) }
    func decode(_ type: UInt32.Type, forKey key: Key) throws -> UInt32 { try Convert.unsigned(first(key), path(key)) }
    func decode(_ type: UInt64.Type, forKey key: Key) throws -> UInt64 { try Convert.uint64(first(key), path(key)) }

    func decode<T: Decodable>(_ type: T.Type, forKey key: Key) throws -> T {
        if type == Date.self { return try Convert.date(first(key), path(key)) as! T }
        return try T(from: FieldDecoder(values: values(key), codingPath: path(key)))
    }

    func nestedContainer<NestedKey>(keyedBy type: NestedKey.Type, forKey key: Key) throws
        -> KeyedDecodingContainer<NestedKey> {
        throw DecodingError.typeMismatch([String: Any].self, .init(
            codingPath: path(key), debugDescription: "tantivy fields are not nested objects"))
    }
    func nestedUnkeyedContainer(forKey key: Key) throws -> UnkeyedDecodingContainer {
        FieldUnkeyed(values: values(key), codingPath: path(key))
    }
    func superDecoder() throws -> Decoder { FieldsDecoder(fields: fields, codingPath: codingPath) }
    func superDecoder(forKey key: Key) throws -> Decoder {
        FieldDecoder(values: values(key), codingPath: path(key))
    }
}

// MARK: - Per-field decoder (drives arrays and single scalars)

private struct FieldDecoder: Decoder {
    let values: [FieldValue]
    let codingPath: [CodingKey]
    var userInfo: [CodingUserInfoKey: Any] { [:] }

    func container<Key: CodingKey>(keyedBy type: Key.Type) throws -> KeyedDecodingContainer<Key> {
        throw DecodingError.typeMismatch([String: Any].self, .init(
            codingPath: codingPath, debugDescription: "a field value is not a nested object"))
    }
    func unkeyedContainer() throws -> UnkeyedDecodingContainer {
        FieldUnkeyed(values: values, codingPath: codingPath)
    }
    func singleValueContainer() throws -> SingleValueDecodingContainer {
        FieldSingle(value: values.first, codingPath: codingPath)
    }
}

private struct FieldUnkeyed: UnkeyedDecodingContainer {
    let values: [FieldValue]
    let codingPath: [CodingKey]
    var count: Int? { values.count }
    var isAtEnd: Bool { currentIndex >= values.count }
    private(set) var currentIndex: Int = 0

    private mutating func next() throws -> FieldValue {
        guard !isAtEnd else {
            throw DecodingError.valueNotFound(FieldValue.self, .init(
                codingPath: codingPath, debugDescription: "unkeyed container is at end"))
        }
        defer { currentIndex += 1 }
        return values[currentIndex]
    }

    mutating func decodeNil() throws -> Bool { false }  // tantivy never stores nulls
    mutating func decode(_ type: Bool.Type) throws -> Bool { try Convert.bool(next(), codingPath) }
    mutating func decode(_ type: String.Type) throws -> String { try Convert.string(next(), codingPath) }
    mutating func decode(_ type: Double.Type) throws -> Double { try Convert.double(next(), codingPath) }
    mutating func decode(_ type: Float.Type) throws -> Float { try Convert.float(next(), codingPath) }
    mutating func decode(_ type: Int.Type) throws -> Int { try Convert.signed(next(), codingPath) }
    mutating func decode(_ type: Int8.Type) throws -> Int8 { try Convert.signed(next(), codingPath) }
    mutating func decode(_ type: Int16.Type) throws -> Int16 { try Convert.signed(next(), codingPath) }
    mutating func decode(_ type: Int32.Type) throws -> Int32 { try Convert.signed(next(), codingPath) }
    mutating func decode(_ type: Int64.Type) throws -> Int64 { try Convert.int64(next(), codingPath) }
    mutating func decode(_ type: UInt.Type) throws -> UInt { try Convert.unsigned(next(), codingPath) }
    mutating func decode(_ type: UInt8.Type) throws -> UInt8 { try Convert.unsigned(next(), codingPath) }
    mutating func decode(_ type: UInt16.Type) throws -> UInt16 { try Convert.unsigned(next(), codingPath) }
    mutating func decode(_ type: UInt32.Type) throws -> UInt32 { try Convert.unsigned(next(), codingPath) }
    mutating func decode(_ type: UInt64.Type) throws -> UInt64 { try Convert.uint64(next(), codingPath) }
    mutating func decode<T: Decodable>(_ type: T.Type) throws -> T {
        let v = try next()
        if type == Date.self { return try Convert.date(v, codingPath) as! T }
        return try T(from: FieldDecoder(values: [v], codingPath: codingPath))
    }

    mutating func nestedContainer<NestedKey>(keyedBy type: NestedKey.Type) throws
        -> KeyedDecodingContainer<NestedKey> {
        throw DecodingError.typeMismatch([String: Any].self, .init(
            codingPath: codingPath, debugDescription: "field values are not nested objects"))
    }
    mutating func nestedUnkeyedContainer() throws -> UnkeyedDecodingContainer {
        throw DecodingError.typeMismatch([Any].self, .init(
            codingPath: codingPath, debugDescription: "field values are not nested arrays"))
    }
    mutating func superDecoder() throws -> Decoder {
        FieldDecoder(values: values, codingPath: codingPath)
    }
}

private struct FieldSingle: SingleValueDecodingContainer {
    let value: FieldValue?
    let codingPath: [CodingKey]

    private func req() throws -> FieldValue {
        guard let v = value else {
            throw DecodingError.valueNotFound(FieldValue.self, .init(
                codingPath: codingPath, debugDescription: "no value"))
        }
        return v
    }

    func decodeNil() -> Bool { value == nil }
    func decode(_ type: Bool.Type) throws -> Bool { try Convert.bool(req(), codingPath) }
    func decode(_ type: String.Type) throws -> String { try Convert.string(req(), codingPath) }
    func decode(_ type: Double.Type) throws -> Double { try Convert.double(req(), codingPath) }
    func decode(_ type: Float.Type) throws -> Float { try Convert.float(req(), codingPath) }
    func decode(_ type: Int.Type) throws -> Int { try Convert.signed(req(), codingPath) }
    func decode(_ type: Int8.Type) throws -> Int8 { try Convert.signed(req(), codingPath) }
    func decode(_ type: Int16.Type) throws -> Int16 { try Convert.signed(req(), codingPath) }
    func decode(_ type: Int32.Type) throws -> Int32 { try Convert.signed(req(), codingPath) }
    func decode(_ type: Int64.Type) throws -> Int64 { try Convert.int64(req(), codingPath) }
    func decode(_ type: UInt.Type) throws -> UInt { try Convert.unsigned(req(), codingPath) }
    func decode(_ type: UInt8.Type) throws -> UInt8 { try Convert.unsigned(req(), codingPath) }
    func decode(_ type: UInt16.Type) throws -> UInt16 { try Convert.unsigned(req(), codingPath) }
    func decode(_ type: UInt32.Type) throws -> UInt32 { try Convert.unsigned(req(), codingPath) }
    func decode(_ type: UInt64.Type) throws -> UInt64 { try Convert.uint64(req(), codingPath) }
    func decode<T: Decodable>(_ type: T.Type) throws -> T {
        if type == Date.self { return try Convert.date(req(), codingPath) as! T }
        return try T(from: FieldDecoder(values: value.map { [$0] } ?? [], codingPath: codingPath))
    }
}
