import Foundation
import Testing
@testable import Tantivy

/// Targeted coverage for `SearchHit.decode(_:)`.
///
/// Deliberately not exhaustive over the `Decodable` surface: the decoder has
/// ~42 one-line overloads (`Int8`, `Int16`, `UInt32`, … across three container
/// types) that all funnel into four `Convert` generics. Enumerating them would
/// move the coverage number a long way and assure very little, since testing
/// three integer types exercises the same generic code as testing fourteen.
///
/// What is worth pinning is the logic those overloads share:
///
///  * the `exactly:` range checks, where a mistake means a stored `300` quietly
///    arriving as `44` rather than an error;
///  * the `Date` and `Data` interceptions, which are duplicated verbatim in all
///    three containers — the pattern most likely to be half-applied when the
///    next special-cased type is added.
struct HitDecoderTests {

    // MARK: - Fixtures

    /// A hit whose single stored field `v` holds `value`, typed per the builder.
    private func hit(_ build: (SchemaBuilder) -> Void, _ set: (inout Document) -> Void) throws
        -> SearchHit {
        let builder = SchemaBuilder()
        build(builder)
        let index = try Index.inMemory(schema: builder.build())
        var doc = Document()
        set(&doc)
        try index.add(doc)
        return try #require(try index.search(.matchAll).first)
    }

    private func hit(i64 value: Int64) throws -> SearchHit {
        try hit({ $0.addI64Field("v", stored: true) }, { $0["v"] = .int(value) })
    }
    private func hit(u64 value: UInt64) throws -> SearchHit {
        try hit({ $0.addU64Field("v", stored: true) }, { $0["v"] = .unsigned(value) })
    }
    private func hit(f64 value: Double) throws -> SearchHit {
        try hit({ $0.addF64Field("v", stored: true) }, { $0["v"] = .double(value) })
    }

    // MARK: - Range checks

    private struct Int8Row: Decodable { let v: Int8 }
    private struct Int16Row: Decodable { let v: Int16 }
    private struct Int32Row: Decodable { let v: Int32 }
    private struct UInt8Row: Decodable { let v: UInt8 }
    private struct UInt16Row: Decodable { let v: UInt16 }
    private struct UInt64Row: Decodable { let v: UInt64 }
    private struct Int64Row: Decodable { let v: Int64 }

    @Test func narrowSignedTypesAcceptTheirRange() throws {
        #expect(try hit(i64: 127).decode(Int8Row.self).v == 127)
        #expect(try hit(i64: -128).decode(Int8Row.self).v == -128)
        #expect(try hit(i64: 32_767).decode(Int16Row.self).v == 32_767)
        #expect(try hit(i64: -32_768).decode(Int16Row.self).v == -32_768)
        #expect(try hit(i64: 2_147_483_647).decode(Int32Row.self).v == 2_147_483_647)
        #expect(try hit(i64: Int64.min).decode(Int64Row.self).v == Int64.min)
    }

    /// The important half: one past the boundary must throw, not wrap.
    @Test func narrowSignedTypesRejectOverflow() throws {
        #expect(throws: DecodingError.self) { try hit(i64: 128).decode(Int8Row.self) }
        #expect(throws: DecodingError.self) { try hit(i64: -129).decode(Int8Row.self) }
        #expect(throws: DecodingError.self) { try hit(i64: 32_768).decode(Int16Row.self) }
        #expect(throws: DecodingError.self) { try hit(i64: -32_769).decode(Int16Row.self) }
        #expect(throws: DecodingError.self) { try hit(i64: 2_147_483_648).decode(Int32Row.self) }
    }

    @Test func narrowUnsignedTypesAcceptTheirRange() throws {
        #expect(try hit(u64: 255).decode(UInt8Row.self).v == 255)
        #expect(try hit(u64: 0).decode(UInt8Row.self).v == 0)
        #expect(try hit(u64: 65_535).decode(UInt16Row.self).v == 65_535)
        #expect(try hit(u64: UInt64.max).decode(UInt64Row.self).v == UInt64.max)
    }

    @Test func narrowUnsignedTypesRejectOverflow() throws {
        #expect(throws: DecodingError.self) { try hit(u64: 256).decode(UInt8Row.self) }
        #expect(throws: DecodingError.self) { try hit(u64: 65_536).decode(UInt16Row.self) }
    }

    /// A negative value cannot become unsigned, and a `u64` above `Int64.max`
    /// cannot become signed. Both would otherwise wrap silently.
    @Test func signednessMismatchesAreRejected() throws {
        #expect(throws: DecodingError.self) { try hit(i64: -1).decode(UInt8Row.self) }
        #expect(throws: DecodingError.self) { try hit(i64: -1).decode(UInt64Row.self) }
        #expect(throws: DecodingError.self) { try hit(u64: UInt64.max).decode(Int64Row.self) }
    }

    /// `Float(1e300)` is `+infinity`, so narrowing has to range-check rather
    /// than let an out-of-range value decode as an infinity.
    @Test func narrowingToFloatRejectsOverflow() throws {
        struct FloatRow: Decodable { let v: Float }
        #expect(try hit(f64: 2.5).decode(FloatRow.self).v == 2.5)
        #expect(throws: DecodingError.self) { try hit(f64: 1e300).decode(FloatRow.self) }
    }

    /// Floats coerce to integers by truncating toward zero — `Convert.int64`
    /// applies `.rounded(.towardZero)` before its range check, matching
    /// ``SearchHit/int(_:)``. Deliberate, and worth pinning: the alternative
    /// reading (reject anything fractional) is equally plausible from the
    /// signature, so a future edit could "fix" it into a behaviour change.
    @Test func floatToIntegerCoercionTruncatesTowardZero() throws {
        #expect(try hit(f64: 4.0).decode(Int64Row.self).v == 4)
        #expect(try hit(f64: 4.5).decode(Int64Row.self).v == 4)
        #expect(try hit(f64: -4.5).decode(Int64Row.self).v == -4)
        // Truncation does not rescue an out-of-range or negative-to-unsigned
        // conversion.
        #expect(throws: DecodingError.self) { try hit(f64: -1.0).decode(UInt64Row.self) }
        #expect(throws: DecodingError.self) { try hit(f64: 1e300).decode(Int64Row.self) }
    }

    @Test func typeMismatchesAreRejected() throws {
        struct StringRow: Decodable { let v: String }
        struct BoolRow: Decodable { let v: Bool }
        #expect(throws: DecodingError.self) { try hit(i64: 1).decode(StringRow.self) }
        // `1` must not decode as `true` — tantivy stores bools distinctly.
        #expect(throws: DecodingError.self) { try hit(i64: 1).decode(BoolRow.self) }
    }

    // MARK: - Date and Data across all three containers

    private static let when = Date(timeIntervalSince1970: 1_000_000)
    private static let bytes = Data([0x00, 0xFF, 0x80])

    /// Scalar property — `FieldsKeyed.decode(_:forKey:)`.
    @Test func dateAndDataDecodeAsScalars() throws {
        struct Row: Decodable, Equatable { let d: Date; let b: Data }
        let hit = try hit({
            $0.addDateField("d", stored: true)
            $0.addBytesField("b", stored: true, indexed: true)
        }, {
            $0.set("d", Self.when)
            $0.set("b", Self.bytes)
        })
        let row = try hit.decode(Row.self)
        #expect(row.d == Self.when)
        #expect(row.b == Self.bytes)
    }

    /// Array property — `FieldUnkeyed.decode(_:)`. The interception is a
    /// separate copy here, so a scalar test does not cover it.
    @Test func dateAndDataDecodeInsideArrays() throws {
        struct Row: Decodable { let d: [Date]; let b: [Data] }
        let later = Self.when.addingTimeInterval(86_400)
        let hit = try hit({
            $0.addDateField("d", stored: true)
            $0.addBytesField("b", stored: true, indexed: true)
        }, {
            $0["d"] = .array([.date(Self.when), .date(later)])
            $0["b"] = .array([.bytes(Self.bytes), .bytes(Data())])
        })
        let row = try hit.decode(Row.self)
        #expect(row.d == [Self.when, later])
        #expect(row.b == [Self.bytes, Data()])
    }

    /// Single-value container — `FieldSingle.decode(_:)`, reached through a type
    /// that decodes itself from a single value. The third copy of the same
    /// interception.
    @Test func dateAndDataDecodeThroughASingleValueContainer() throws {
        struct BoxedDate: Decodable {
            let value: Date
            init(from decoder: Decoder) throws {
                value = try decoder.singleValueContainer().decode(Date.self)
            }
        }
        struct BoxedData: Decodable {
            let value: Data
            init(from decoder: Decoder) throws {
                value = try decoder.singleValueContainer().decode(Data.self)
            }
        }
        struct Row: Decodable { let d: BoxedDate; let b: BoxedData }

        let hit = try hit({
            $0.addDateField("d", stored: true)
            $0.addBytesField("b", stored: true, indexed: true)
        }, {
            $0.set("d", Self.when)
            $0.set("b", Self.bytes)
        })
        let row = try hit.decode(Row.self)
        #expect(row.d.value == Self.when)
        #expect(row.b.value == Self.bytes)
    }

    /// Asking for a `Date` where a byte string is stored, and vice versa.
    @Test func dateAndDataRejectTheWrongStoredType() throws {
        struct DateRow: Decodable { let b: Date }
        struct DataRow: Decodable { let d: Data }
        let hit = try hit({
            $0.addDateField("d", stored: true)
            $0.addBytesField("b", stored: true, indexed: true)
        }, {
            $0.set("d", Self.when)
            $0.set("b", Self.bytes)
        })
        #expect(throws: DecodingError.self) { try hit.decode(DateRow.self) }
        #expect(throws: DecodingError.self) { try hit.decode(DataRow.self) }
    }

    // MARK: - Absence

    @Test func missingFieldsDecodeAsNilAndRequiredOnesThrow() throws {
        struct Optional: Decodable { let v: Int64?; let absent: String? }
        struct Required: Decodable { let absent: String }
        let hit = try hit(i64: 7)
        let row = try hit.decode(Optional.self)
        #expect(row.v == 7)
        #expect(row.absent == nil)
        #expect(throws: DecodingError.self) { try hit.decode(Required.self) }
    }

    /// A single-valued field read as an array yields one element, and an array
    /// property over a multi-valued field yields all of them.
    @Test func cardinalityIsFlexible() throws {
        struct ArrayRow: Decodable { let v: [Int64] }
        struct ScalarRow: Decodable { let v: Int64 }

        #expect(try hit(i64: 7).decode(ArrayRow.self).v == [7])

        let multi = try hit({ $0.addI64Field("v", stored: true) },
                            { $0["v"] = .array([.int(1), .int(2), .int(3)]) })
        #expect(try multi.decode(ArrayRow.self).v == [1, 2, 3])
        // A scalar property reads the first value.
        #expect(try multi.decode(ScalarRow.self).v == 1)
    }
}
