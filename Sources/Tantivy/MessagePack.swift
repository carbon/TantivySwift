import Foundation

// A minimal MessagePack reader, covering exactly the grammar the hit envelope
// uses: nil, bool, uint, int, float, str, bin, array, map.
//
// Written by hand because Foundation has no MessagePack and this package has no
// Swift dependencies. It is a cursor over a raw buffer: values are read in place
// and turned straight into `SearchHit`s, with no intermediate `Any` tree of the
// kind `JSONSerialization` builds and no `Decodable` machinery. That is the
// point of the exercise — the format change and the "stop building
// intermediates" change are separable, and this path does both.

/// A failure while reading a MessagePack payload. These indicate a bug in the
/// encoder or a truncated buffer, not user error.
enum MessagePackError: Error, CustomStringConvertible {
    case truncated(needed: Int, available: Int)
    case unexpectedTag(UInt8, expected: String)
    case invalidUTF8
    case unexpectedKey(String)

    var description: String {
        switch self {
        case .truncated(let needed, let available):
            return "truncated MessagePack: needed \(needed) bytes, \(available) remain"
        case .unexpectedTag(let tag, let expected):
            return "unexpected MessagePack tag 0x\(String(tag, radix: 16)), expected \(expected)"
        case .invalidUTF8:
            return "MessagePack string was not valid UTF-8"
        case .unexpectedKey(let key):
            return "unexpected key '\(key)' in the hit envelope"
        }
    }
}

// MARK: - Writing

/// A MessagePack encoder — the mirror of the Rust one, and the counterpart of
/// ``MessagePackReader``.
///
/// Appends into a plain `[UInt8]`: a tag byte, an optional big-endian length,
/// and the payload. Integers use the narrowest form that fits, matching what
/// the Rust reader expects.
struct MessagePackWriter {
    private(set) var bytes: [UInt8] = []

    init(reservingCapacity capacity: Int = 256) {
        bytes.reserveCapacity(capacity)
    }

    private mutating func append<T: FixedWidthInteger>(_ value: T) {
        withUnsafeBytes(of: value.bigEndian) { bytes.append(contentsOf: $0) }
    }

    mutating func writeMapHeader(_ count: Int) {
        switch count {
        case ..<16: bytes.append(0x80 | UInt8(count))
        case ..<65_536: bytes.append(0xde); append(UInt16(count))
        default: bytes.append(0xdf); append(UInt32(count))
        }
    }

    mutating func writeArrayHeader(_ count: Int) {
        switch count {
        case ..<16: bytes.append(0x90 | UInt8(count))
        case ..<65_536: bytes.append(0xdc); append(UInt16(count))
        default: bytes.append(0xdd); append(UInt32(count))
        }
    }

    mutating func write(_ value: String) {
        let utf8 = Array(value.utf8)
        switch utf8.count {
        case ..<32: bytes.append(0xa0 | UInt8(utf8.count))
        case ..<256: bytes.append(0xd9); bytes.append(UInt8(utf8.count))
        case ..<65_536: bytes.append(0xda); append(UInt16(utf8.count))
        default: bytes.append(0xdb); append(UInt32(utf8.count))
        }
        bytes.append(contentsOf: utf8)
    }

    /// Write raw bytes. Native here — no base64, no side buffer.
    mutating func write(_ value: Data) {
        switch value.count {
        case ..<256: bytes.append(0xc4); bytes.append(UInt8(value.count))
        case ..<65_536: bytes.append(0xc5); append(UInt16(value.count))
        default: bytes.append(0xc6); append(UInt32(value.count))
        }
        bytes.append(contentsOf: value)
    }

    mutating func write(_ value: Bool) {
        bytes.append(value ? 0xc3 : 0xc2)
    }

    mutating func write(_ value: UInt64) {
        switch value {
        case ..<0x80: bytes.append(UInt8(value))
        case ..<0x100: bytes.append(0xcc); bytes.append(UInt8(value))
        case ..<0x1_0000: bytes.append(0xcd); append(UInt16(value))
        case ..<0x1_0000_0000: bytes.append(0xce); append(UInt32(value))
        default: bytes.append(0xcf); append(value)
        }
    }

    mutating func write(_ value: Int64) {
        guard value < 0 else { return write(UInt64(value)) }
        switch value {
        case (-32)...: bytes.append(UInt8(bitPattern: Int8(value)))
        case Int64(Int8.min)...: bytes.append(0xd0); bytes.append(UInt8(bitPattern: Int8(value)))
        case Int64(Int16.min)...: bytes.append(0xd1); append(Int16(value))
        case Int64(Int32.min)...: bytes.append(0xd2); append(Int32(value))
        default: bytes.append(0xd3); append(value)
        }
    }

    mutating func write(_ value: Double) {
        bytes.append(0xcb)
        append(value.bitPattern)
    }
}

// MARK: - Encoding documents

extension MessagePackWriter {
    /// Encode a document as `{field name: [values]}`.
    ///
    /// Always an array per field, even for a single value: the reader is
    /// schema-driven and needs no hint about cardinality, and it keeps
    /// multi-valued fields from being a special case.
    ///
    /// Non-finite numbers are rejected here rather than in a separate pass. The
    /// old JSON path had to pre-scan every document, because a NaN reaching
    /// `JSONSerialization` raises an *uncatchable* `NSException`; encoding
    /// directly means the check rides along with the write it guards.
    static func document(
        _ fields: [String: [DocumentValue]]
    ) throws(TantivyError) -> [UInt8] {
        var writer = MessagePackWriter()
        writer.writeMapHeader(fields.count)
        for (name, values) in fields {
            writer.write(name)
            writer.writeArrayHeader(values.count)
            for value in values {
                try writer.write(value, field: name)
            }
        }
        return writer.bytes
    }

    private mutating func write(_ value: DocumentValue, field: String) throws(TantivyError) {
        switch value {
        case .string(let s): write(s)
        case .int(let i): write(i)
        case .unsigned(let u): write(u)
        case .bool(let b): write(b)
        case .bytes(let d): write(d)
        case .date(let d): write(d.formatted(.iso8601))
        case .double(let d):
            guard d.isFinite else {
                throw TantivyError.encoding("field '\(field)' has a non-finite number (NaN/±∞)")
            }
            write(d)
        case .array:
            throw TantivyError.encoding("field '\(field)' has a nested array value")
        }
    }

    /// Encode an untyped `[String: Any]` document.
    ///
    /// `Bool` is matched before the integer cases: a bridged `NSNumber` holding
    /// a boolean satisfies both, and picking the wrong one would silently index
    /// `1` into a `bool` field.
    static func document(_ fields: [String: Any]) throws(TantivyError) -> [UInt8] {
        var writer = MessagePackWriter()
        writer.writeMapHeader(fields.count)
        for (name, value) in fields {
            writer.write(name)
            if let array = value as? [Any] {
                writer.writeArrayHeader(array.count)
                for element in array { try writer.writeAny(element, field: name) }
            } else {
                writer.writeArrayHeader(1)
                try writer.writeAny(value, field: name)
            }
        }
        return writer.bytes
    }

    private mutating func writeAny(_ value: Any, field: String) throws(TantivyError) {
        switch value {
        case let v as Bool: write(v)
        case let v as String: write(v)
        case let v as Data: write(v)
        case let v as Date: write(v.formatted(.iso8601))
        case let v as Int: write(Int64(v))
        case let v as Int64: write(v)
        case let v as UInt64: write(v)
        case let v as UInt: write(UInt64(v))
        case let v as Double:
            guard v.isFinite else {
                throw TantivyError.encoding("field '\(field)' has a non-finite number (NaN/±∞)")
            }
            write(v)
        case let v as Float:
            guard v.isFinite else {
                throw TantivyError.encoding("field '\(field)' has a non-finite number (NaN/±∞)")
            }
            write(Double(v))
        case let v as any SignedInteger: write(Int64(v))
        case let v as any UnsignedInteger: write(UInt64(v))
        case let v as NSNumber:
            // Reached only for values bridged from Objective-C that none of the
            // concrete cases above matched.
            if CFNumberIsFloatType(v) {
                guard v.doubleValue.isFinite else {
                    throw TantivyError.encoding(
                        "field '\(field)' has a non-finite number (NaN/±∞)")
                }
                write(v.doubleValue)
            } else {
                write(v.int64Value)
            }
        default:
            throw TantivyError.encoding(
                "field '\(field)' has a value of unsupported type \(type(of: value))")
        }
    }
}

/// A cursor over a MessagePack buffer.
///
/// Non-owning: it reads from memory the caller keeps alive for the duration.
/// Every read bounds-checks, so a truncated or corrupt payload throws rather
/// than reading past the end.
struct MessagePackReader {
    private let buffer: UnsafeRawBufferPointer
    private var index: Int = 0

    init(_ buffer: UnsafeRawBufferPointer) {
        self.buffer = buffer
    }

    var isAtEnd: Bool { index >= buffer.count }

    // MARK: - Primitive reads

    private mutating func byte() throws -> UInt8 {
        guard index < buffer.count else {
            throw MessagePackError.truncated(needed: 1, available: buffer.count - index)
        }
        defer { index += 1 }
        return buffer[index]
    }

    private func peek() throws -> UInt8 {
        guard index < buffer.count else {
            throw MessagePackError.truncated(needed: 1, available: buffer.count - index)
        }
        return buffer[index]
    }

    /// Read `count` big-endian bytes as an unsigned integer.
    private mutating func bigEndian(_ count: Int) throws -> UInt64 {
        guard index + count <= buffer.count else {
            throw MessagePackError.truncated(needed: count, available: buffer.count - index)
        }
        var value: UInt64 = 0
        for offset in 0..<count {
            value = (value << 8) | UInt64(buffer[index + offset])
        }
        index += count
        return value
    }

    private mutating func span(_ count: Int) throws -> UnsafeRawBufferPointer {
        guard index + count <= buffer.count else {
            throw MessagePackError.truncated(needed: count, available: buffer.count - index)
        }
        defer { index += count }
        return UnsafeRawBufferPointer(rebasing: buffer[index ..< index + count])
    }

    // MARK: - Typed reads

    mutating func readMapHeader() throws -> Int {
        let tag = try byte()
        switch tag {
        case 0x80...0x8f: return Int(tag & 0x0f)
        case 0xde: return Int(try bigEndian(2))
        case 0xdf: return Int(try bigEndian(4))
        default: throw MessagePackError.unexpectedTag(tag, expected: "a map header")
        }
    }

    mutating func readArrayHeader() throws -> Int {
        let tag = try byte()
        switch tag {
        case 0x90...0x9f: return Int(tag & 0x0f)
        case 0xdc: return Int(try bigEndian(2))
        case 0xdd: return Int(try bigEndian(4))
        default: throw MessagePackError.unexpectedTag(tag, expected: "an array header")
        }
    }

    mutating func readString() throws -> String {
        let tag = try byte()
        let count: Int
        switch tag {
        case 0xa0...0xbf: count = Int(tag & 0x1f)
        case 0xd9: count = Int(try bigEndian(1))
        case 0xda: count = Int(try bigEndian(2))
        case 0xdb: count = Int(try bigEndian(4))
        default: throw MessagePackError.unexpectedTag(tag, expected: "a string")
        }
        let bytes = try span(count)
        guard let string = String(bytes: bytes, encoding: .utf8) else {
            throw MessagePackError.invalidUTF8
        }
        return string
    }

    mutating func readDouble() throws -> Double {
        let tag = try byte()
        switch tag {
        case 0xca: return Double(Float(bitPattern: UInt32(try bigEndian(4))))
        case 0xcb: return Double(bitPattern: try bigEndian(8))
        default:
            // A whole-valued score can arrive as an integer form.
            index -= 1
            guard let value = try readFieldValue().double else {
                throw MessagePackError.unexpectedTag(tag, expected: "a float")
            }
            return value
        }
    }

    /// Read one stored field value.
    ///
    /// The integer cases mirror `FieldValue`'s JSON decoding: values that fit
    /// `Int64` become `.int`, larger unsigned values `.unsigned`.
    mutating func readFieldValue() throws -> FieldValue {
        let tag = try peek()
        switch tag {
        case 0x00...0x7f:            // positive fixint
            index += 1
            return .int(Int64(tag))
        case 0xe0...0xff:            // negative fixint
            index += 1
            return .int(Int64(Int8(bitPattern: tag)))
        case 0xa0...0xbf, 0xd9, 0xda, 0xdb:
            return .string(try readString())
        case 0xc0:
            index += 1
            return .string("")       // tantivy never stores nulls; be lenient
        case 0xc2:
            index += 1
            return .bool(false)
        case 0xc3:
            index += 1
            return .bool(true)
        case 0xc4, 0xc5, 0xc6:
            return .bytes(try readData())
        case 0xca:
            index += 1
            return .double(Double(Float(bitPattern: UInt32(try bigEndian(4)))))
        case 0xcb:
            index += 1
            return .double(Double(bitPattern: try bigEndian(8)))
        case 0xcc, 0xcd, 0xce, 0xcf:
            index += 1
            let width = 1 << Int(tag - 0xcc)
            let value = try bigEndian(width)
            return value <= UInt64(Int64.max) ? .int(Int64(value)) : .unsigned(value)
        case 0xd0, 0xd1, 0xd2, 0xd3:
            index += 1
            let width = 1 << Int(tag - 0xd0)
            let raw = try bigEndian(width)
            // Sign-extend from the encoded width.
            let shift = UInt64(64 - width * 8)
            return .int(Int64(bitPattern: (raw << shift)) >> Int(shift))
        default:
            throw MessagePackError.unexpectedTag(tag, expected: "a field value")
        }
    }

    mutating func readData() throws -> Data {
        let tag = try byte()
        let count: Int
        switch tag {
        case 0xc4: count = Int(try bigEndian(1))
        case 0xc5: count = Int(try bigEndian(2))
        case 0xc6: count = Int(try bigEndian(4))
        default: throw MessagePackError.unexpectedTag(tag, expected: "a byte string")
        }
        return Data(try span(count))
    }
}

// MARK: - Hit envelope

extension MessagePackReader {
    /// Decode the `{hits: [{score, doc, snippets?}]}` envelope.
    ///
    /// Reads straight into `SearchHit`s: no intermediate representation exists
    /// at any point, which is the structural difference from the JSON path.
    static func decodeHits(_ buffer: UnsafeRawBufferPointer) throws -> [SearchHit] {
        var reader = MessagePackReader(buffer)
        let topLevel = try reader.readMapHeader()
        var hits: [SearchHit] = []

        for _ in 0..<topLevel {
            let key = try reader.readString()
            guard key == "hits" else { throw MessagePackError.unexpectedKey(key) }
            let count = try reader.readArrayHeader()
            hits.reserveCapacity(count)
            for _ in 0..<count {
                hits.append(try reader.readHit())
            }
        }
        return hits
    }

    private mutating func readHit() throws -> SearchHit {
        var score: Float = 0
        var fields: [String: [FieldValue]] = [:]
        var snippets: [String: String] = [:]

        for _ in 0..<(try readMapHeader()) {
            switch try readString() {
            case "score":
                score = Float(try readDouble())
            case "doc":
                let fieldCount = try readMapHeader()
                fields.reserveCapacity(fieldCount)
                for _ in 0..<fieldCount {
                    let name = try readString()
                    let valueCount = try readArrayHeader()
                    var values: [FieldValue] = []
                    values.reserveCapacity(valueCount)
                    for _ in 0..<valueCount {
                        values.append(try readFieldValue())
                    }
                    fields[name] = values
                }
            case "snippets":
                for _ in 0..<(try readMapHeader()) {
                    snippets[try readString()] = try readString()
                }
            case let other:
                throw MessagePackError.unexpectedKey(other)
            }
        }
        return SearchHit(score: score, fields: fields, snippets: snippets)
    }
}

extension FieldValue {
    /// This value as a `Double`, widening integers — used when reading a score
    /// that the encoder narrowed to an integer form.
    fileprivate var double: Double? {
        switch self {
        case .double(let d): return d
        case .int(let i): return Double(i)
        case .unsigned(let u): return Double(u)
        default: return nil
        }
    }
}
