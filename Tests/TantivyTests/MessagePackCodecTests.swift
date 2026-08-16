import Foundation
import Testing
@testable import Tantivy

/// Boundary coverage for the MessagePack codec.
///
/// MessagePack widens its length prefixes at 2^4, 2^5, 2^8, and 2^16, and picks
/// the narrowest integer encoding that fits. Ordinary documents only ever
/// exercise the small forms, so the wide branches — `str32`, `bin32`,
/// `array32`, `map32`, and the 64-bit integer forms — would otherwise never
/// execute. A mistake in one of those is silent corruption rather than a crash,
/// which is the worst kind to leave untested.
///
/// Tested at the codec rather than through a real index deliberately:
/// `map32` needs a document with 65,536 *fields*, which is tantivy's hard limit
/// on field count, and `array32` needs 65,536 values in one field. Neither is a
/// realistic index, but both are reachable payloads, so the codec must handle
/// them.
struct MessagePackCodecTests {

    private func roundTrip<T>(
        _ write: (inout MessagePackWriter) -> Void,
        _ read: (inout MessagePackReader) throws -> T
    ) rethrows -> (value: T, tag: UInt8, size: Int) {
        var writer = MessagePackWriter()
        write(&writer)
        let bytes = writer.bytes
        let value = try bytes.withUnsafeBufferPointer { buffer -> T in
            var reader = MessagePackReader(UnsafeRawBufferPointer(buffer))
            return try read(&reader)
        }
        return (value, bytes[0], bytes.count)
    }

    // MARK: - Length-prefix width

    @Test func mapHeadersWidenCorrectly() throws {
        // fixmap, map16, map32.
        for (count, tag) in [(0, UInt8(0x80)), (15, 0x8f), (16, 0xde),
                             (65_535, 0xde), (65_536, 0xdf)] {
            let result = try roundTrip({ $0.writeMapHeader(count) }, { try $0.readMapHeader() })
            #expect(result.value == count, "map header \(count)")
            #expect(result.tag == tag, "map header \(count) used tag 0x\(String(result.tag, radix: 16))")
        }
    }

    @Test func arrayHeadersWidenCorrectly() throws {
        for (count, tag) in [(0, UInt8(0x90)), (15, 0x9f), (16, 0xdc),
                             (65_535, 0xdc), (65_536, 0xdd)] {
            let result = try roundTrip({ $0.writeArrayHeader(count) }, { try $0.readArrayHeader() })
            #expect(result.value == count, "array header \(count)")
            #expect(result.tag == tag, "array header \(count) used tag 0x\(String(result.tag, radix: 16))")
        }
    }

    @Test func stringsWidenCorrectly() throws {
        // fixstr, str8, str16, str32.
        for (length, tag) in [(0, UInt8(0xa0)), (31, 0xbf), (32, 0xd9), (255, 0xd9),
                              (256, 0xda), (65_535, 0xda), (65_536, 0xdb)] {
            let value = String(repeating: "a", count: length)
            let result = try roundTrip({ $0.write(value) }, { try $0.readString() })
            #expect(result.value == value, "string of \(length)")
            #expect(result.tag == tag, "string of \(length) used tag 0x\(String(result.tag, radix: 16))")
        }
    }

    @Test func byteStringsWidenCorrectly() throws {
        // bin8, bin16, bin32.
        for (length, tag) in [(0, UInt8(0xc4)), (255, 0xc4), (256, 0xc5),
                              (65_535, 0xc5), (65_536, 0xc6)] {
            let value = Data(repeating: 0xAB, count: length)
            let result = try roundTrip({ $0.write(value) }, { try $0.readData() })
            #expect(result.value == value, "bytes of \(length)")
            #expect(result.tag == tag, "bytes of \(length) used tag 0x\(String(result.tag, radix: 16))")
        }
    }

    /// Multi-byte UTF-8 must be measured in *bytes*, not characters — a string
    /// of 40,000 emoji is well past the str16 boundary despite the character
    /// count suggesting otherwise.
    @Test func stringWidthFollowsUTF8LengthNotCharacterCount() throws {
        let value = String(repeating: "🙂", count: 20_000)   // 80,000 UTF-8 bytes
        let result = try roundTrip({ $0.write(value) }, { try $0.readString() })
        #expect(result.value == value)
        #expect(result.tag == 0xdb, "expected str32")
    }

    // MARK: - Integer width

    /// Values up to `Int64.max` decode as `.int`; larger unsigned values keep
    /// their range as `.unsigned`.
    @Test func unsignedIntegersUseTheNarrowestForm() throws {
        let cases: [(UInt64, UInt8?)] = [
            (0, nil), (127, nil),                 // positive fixint, no tag byte
            (128, 0xcc), (255, 0xcc),
            (256, 0xcd), (65_535, 0xcd),
            (65_536, 0xce), (4_294_967_295, 0xce),
            (4_294_967_296, 0xcf), (UInt64.max, 0xcf),
        ]
        for (value, tag) in cases {
            let result = try roundTrip({ $0.write(value) }, { try $0.readFieldValue() })
            let expected: FieldValue =
                value <= UInt64(Int64.max) ? .int(Int64(value)) : .unsigned(value)
            #expect(result.value == expected, "u64 \(value)")
            if let tag { #expect(result.tag == tag, "u64 \(value)") }
            else { #expect(result.tag == UInt8(value), "u64 \(value) should be a fixint") }
        }
    }

    @Test func signedIntegersUseTheNarrowestForm() throws {
        let cases: [(Int64, UInt8?)] = [
            (0, nil), (127, nil),                 // positive fixint
            (-1, nil), (-32, nil),                // negative fixint
            (-33, 0xd0), (-128, 0xd0),
            (-129, 0xd1), (Int64(Int16.min), 0xd1),
            (Int64(Int16.min) - 1, 0xd2), (Int64(Int32.min), 0xd2),
            (Int64(Int32.min) - 1, 0xd3), (Int64.min, 0xd3),
            (Int64.max, 0xcf),                    // widens through the unsigned form
        ]
        for (value, tag) in cases {
            let result = try roundTrip({ $0.write(value) }, { try $0.readFieldValue() })
            #expect(result.value == .int(value), "i64 \(value)")
            if let tag { #expect(result.tag == tag, "i64 \(value) used 0x\(String(result.tag, radix: 16))") }
        }
    }

    @Test func doublesSurviveExactly() throws {
        for value in [0.0, -0.0, 1.5, -2.25, Double.pi, 1e300, -1e-300,
                      Double.leastNormalMagnitude, Double.greatestFiniteMagnitude] {
            let result = try roundTrip({ $0.write(value) }, { try $0.readDouble() })
            #expect(result.value.bitPattern == value.bitPattern, "double \(value)")
        }
    }

    @Test func booleansRoundTrip() throws {
        for value in [true, false] {
            var writer = MessagePackWriter()
            writer.write(value)
            let decoded = writer.bytes.withUnsafeBufferPointer { buffer -> FieldValue in
                var reader = MessagePackReader(UnsafeRawBufferPointer(buffer))
                return try! reader.readFieldValue()
            }
            #expect(decoded == .bool(value))
        }
    }

    // MARK: - Wide structures end to end through the reader

    /// A hit envelope past the `array32` boundary. The Rust encoder would only
    /// produce this for a search returning 65,536+ hits; the decoder still has
    /// to read it, so the payload is built here directly.
    @Test func aHitEnvelopeWithArray32Decodes() throws {
        let hitCount = 65_536
        var writer = MessagePackWriter(reservingCapacity: hitCount * 24)
        writer.writeMapHeader(1)
        writer.write("hits")
        writer.writeArrayHeader(hitCount)
        for n in 0..<hitCount {
            writer.writeMapHeader(2)
            writer.write("score")
            writer.write(Double(n))
            writer.write("doc")
            writer.writeMapHeader(1)
            writer.write("n")
            writer.writeArrayHeader(1)
            writer.write(UInt64(n))
        }

        let hits = try writer.bytes.withUnsafeBufferPointer { buffer in
            try MessagePackReader.decodeHits(UnsafeRawBufferPointer(buffer))
        }
        #expect(hits.count == hitCount)
        #expect(hits.first?.uint("n") == 0)
        #expect(hits.last?.uint("n") == UInt64(hitCount - 1))
    }

    /// A document map past the `map32` boundary.
    @Test func aDocumentMapWithMap32Decodes() throws {
        let fieldCount = 65_536
        var writer = MessagePackWriter(reservingCapacity: fieldCount * 16)
        writer.writeMapHeader(1)
        writer.write("hits")
        writer.writeArrayHeader(1)
        writer.writeMapHeader(2)
        writer.write("score")
        writer.write(1.0)
        writer.write("doc")
        writer.writeMapHeader(fieldCount)
        for n in 0..<fieldCount {
            writer.write("f\(n)")
            writer.writeArrayHeader(1)
            writer.write(UInt64(n))
        }

        let hits = try writer.bytes.withUnsafeBufferPointer { buffer in
            try MessagePackReader.decodeHits(UnsafeRawBufferPointer(buffer))
        }
        #expect(hits.count == 1)
        #expect(hits[0].fields.count == fieldCount)
        #expect(hits[0].uint("f0") == 0)
        #expect(hits[0].uint("f\(fieldCount - 1)") == UInt64(fieldCount - 1))
    }

    /// A single field holding more values than `fixarray`/`array16` can express.
    @Test func aFieldWithArray32ValuesDecodes() throws {
        let valueCount = 65_536
        var writer = MessagePackWriter(reservingCapacity: valueCount * 8)
        writer.writeMapHeader(1)
        writer.write("hits")
        writer.writeArrayHeader(1)
        writer.writeMapHeader(2)
        writer.write("score")
        writer.write(1.0)
        writer.write("doc")
        writer.writeMapHeader(1)
        writer.write("tags")
        writer.writeArrayHeader(valueCount)
        for n in 0..<valueCount { writer.write(UInt64(n)) }

        let hits = try writer.bytes.withUnsafeBufferPointer { buffer in
            try MessagePackReader.decodeHits(UnsafeRawBufferPointer(buffer))
        }
        #expect(hits[0]["tags"].count == valueCount)
    }

    // MARK: - Malformed input

    @Test func aTruncatedPayloadThrows() throws {
        var writer = MessagePackWriter()
        writer.write(String(repeating: "a", count: 1_000))
        for cut in [0, 1, 2, 500] {
            let truncated = Array(writer.bytes.prefix(cut))
            #expect(throws: (any Error).self, "cut at \(cut)") {
                try truncated.withUnsafeBufferPointer { buffer in
                    var reader = MessagePackReader(UnsafeRawBufferPointer(buffer))
                    return try reader.readString()
                }
            }
        }
    }

    @Test func aWrongTypeThrows() throws {
        var writer = MessagePackWriter()
        writer.write("not a number")
        try writer.bytes.withUnsafeBufferPointer { buffer in
            let raw = UnsafeRawBufferPointer(buffer)
            #expect(throws: (any Error).self) {
                var r = MessagePackReader(raw); return try r.readDouble()
            }
            #expect(throws: (any Error).self) {
                var r = MessagePackReader(raw); return try r.readData()
            }
            #expect(throws: (any Error).self) {
                var r = MessagePackReader(raw); return try r.readMapHeader()
            }
            #expect(throws: (any Error).self) {
                var r = MessagePackReader(raw); return try r.readArrayHeader()
            }
        }
    }

    @Test func anUnexpectedEnvelopeKeyThrows() throws {
        var writer = MessagePackWriter()
        writer.writeMapHeader(1)
        writer.write("not_hits")
        writer.writeArrayHeader(0)
        #expect(throws: (any Error).self) {
            try writer.bytes.withUnsafeBufferPointer { buffer in
                try MessagePackReader.decodeHits(UnsafeRawBufferPointer(buffer))
            }
        }
    }

    @Test func invalidUTF8InAStringThrows() throws {
        // A str8 header claiming 2 bytes, followed by a lone continuation byte.
        let bytes: [UInt8] = [0xd9, 0x02, 0xFF, 0x80]
        #expect(throws: (any Error).self) {
            try bytes.withUnsafeBufferPointer { buffer in
                var reader = MessagePackReader(UnsafeRawBufferPointer(buffer))
                return try reader.readString()
            }
        }
    }

    // MARK: - Through the real index

    /// `str32` on the live path: a stored text field past 65,536 bytes has to
    /// survive both encoders and both decoders.
    @Test func aVeryLongStringRoundTripsThroughTheIndex() throws {
        let long = String(repeating: "search engine corpus ", count: 5_000)   // ~105 KB
        #expect(long.utf8.count > 65_536)

        let schema = SchemaBuilder()
            .addTextField("body", stored: true)
            .addStringField("id", stored: true)
            .build()
        let index = try Index.inMemory(schema: schema)
        var doc = Document()
        doc["body"] = .string(long)
        doc["id"] = .string("big")
        try index.add(doc)

        let hit = try #require(try index.search(.term("id", "big")).first)
        #expect(hit.string("body") == long)
    }
}
