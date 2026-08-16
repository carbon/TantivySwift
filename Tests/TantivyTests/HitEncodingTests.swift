import Foundation
import Testing
@testable import Tantivy

/// Round-trip coverage for the MessagePack hit envelope.
///
/// These began as parity tests against a second, JSON-based hit path. That path
/// is gone, so there is no longer an oracle to compare against — each test now
/// asserts the round trip directly: write a known value, read it back, and
/// require it unchanged. The size-class cases exist because MessagePack widens
/// its length prefixes at 2^5, 2^8, and 2^16, and a decoder that mishandles one
/// of those boundaries would otherwise pass every ordinary test.
struct HitEncodingTests {

    @Test func everyScalarTypeRoundTrips() throws {
        let schema = SchemaBuilder()
            .addTextField("title", stored: true)
            .addStringField("tag", stored: true)
            .addU64Field("u", stored: true)
            .addI64Field("i", stored: true)
            .addF64Field("f", stored: true)
            .addBoolField("b", stored: true)
            .addDateField("created", stored: true)
            .addBytesField("key", stored: true, indexed: true)
            .build()
        let index = try Index.inMemory(schema: schema)
        let created = Date(timeIntervalSince1970: 1_000_000)
        let key = Data([0x00, 0xFF, 0x80])

        var doc = Document()
        doc["title"] = "the old man and the sea"
        doc["tag"] = "book"
        doc["u"] = .unsigned(42)
        doc["i"] = .int(-7)
        doc["f"] = .double(2.5)
        doc["b"] = true
        doc.set("created", created)
        doc.set("key", key)
        try index.add(doc)

        let hit = try #require(try index.search(.matchAll).first)
        #expect(hit.string("title") == "the old man and the sea")
        #expect(hit.string("tag") == "book")
        #expect(hit.uint("u") == 42)
        #expect(hit.int("i") == -7)
        #expect(hit.double("f") == 2.5)
        #expect(hit.bool("b") == true)
        #expect(hit.data("key") == key)
        #expect(hit["created"].first?.description.hasPrefix("1970-01-12") == true)
    }

    @Test func integerExtremesRoundTrip() throws {
        // MessagePack picks the narrowest encoding for each value, so the full
        // i64 and u64 ranges have to survive — including values above Int64.max,
        // which must stay `.unsigned`.
        let schema = SchemaBuilder()
            .addU64Field("u", stored: true)
            .addI64Field("i", stored: true)
            .build()
        let index = try Index.inMemory(schema: schema)
        let pairs: [(UInt64, Int64)] = [
            (0, 0), (1, -1), (127, -32), (128, -33), (65_535, Int64(Int16.min)),
            (UInt64(Int64.max), Int64.min), (UInt64.max, Int64.max),
        ]
        let w = try index.writer()
        for (u, i) in pairs {
            var doc = Document()
            doc["u"] = .unsigned(u)
            doc["i"] = .int(i)
            try w.addDocument(doc)
        }
        try w.commitAndReload()

        let hits = try index.search(.matchAll, limit: 100)
        #expect(hits.count == pairs.count)
        #expect(Set(hits.compactMap { $0.uint("u") }) == Set(pairs.map(\.0)))
        #expect(Set(hits.compactMap { $0.int("i") }) == Set(pairs.map(\.1)))
    }

    @Test func floatValuesRoundTrip() throws {
        let schema = SchemaBuilder().addF64Field("f", stored: true).build()
        let index = try Index.inMemory(schema: schema)
        let values = [0.0, -0.0, 1.5, -2.25, Double.pi, 1e300, -1e-300, 4.0]
        let w = try index.writer()
        for value in values {
            var doc = Document()
            doc["f"] = .double(value)
            try w.addDocument(doc)
        }
        try w.commitAndReload()

        let read = try index.search(.matchAll, limit: 100).compactMap { $0.double("f") }
        #expect(read.sorted() == values.sorted())
    }

    /// A whole-valued `f64` keeps its type. The JSON envelope could not do this:
    /// once `4.0` is decimal text it is indistinguishable from an integer, so it
    /// decoded as `.int(4)`. MessagePack tags the value, so the field's declared
    /// type survives.
    @Test func wholeValuedFloatsKeepTheirType() throws {
        let schema = SchemaBuilder().addF64Field("f", stored: true).build()
        let index = try Index.inMemory(schema: schema)
        var doc = Document()
        doc["f"] = .double(4.0)
        try index.add(doc)

        let hit = try #require(try index.search(.matchAll).first)
        #expect(hit["f"] == [.double(4.0)])
    }

    @Test func multiValuedFieldsKeepOrder() throws {
        let schema = SchemaBuilder()
            .addStringField("tag", stored: true)
            .addBytesField("key", stored: true, indexed: true)
            .build()
        let index = try Index.inMemory(schema: schema)
        var doc = Document()
        doc["tag"] = ["a", "b", "c"]
        doc["key"] = .array([.bytes(Data([0x01])), .bytes(Data()), .bytes(Data([0xFF, 0xFE]))])
        try index.add(doc)

        let hit = try #require(try index.search(.matchAll).first)
        #expect(hit["tag"] == [.string("a"), .string("b"), .string("c")])
        #expect(hit["key"] == [.bytes(Data([0x01])), .bytes(Data()), .bytes(Data([0xFF, 0xFE]))])
    }

    @Test func byteValuesOfEverySizeClassRoundTrip() throws {
        // bin8 / bin16 / bin32 boundaries, plus empty.
        let sizes = [0, 1, 255, 256, 65_535, 65_536]
        let schema = SchemaBuilder()
            .addBytesField("key", stored: true, indexed: true)
            .addU64Field("n", stored: true)
            .build()
        let index = try Index.inMemory(schema: schema)
        let w = try index.writer()
        for size in sizes {
            var doc = Document()
            doc.set("key", Data((0..<size).map { UInt8($0 % 256) }))
            doc["n"] = .unsigned(UInt64(size))
            try w.addDocument(doc)
        }
        try w.commitAndReload()

        for hit in try index.search(.matchAll, limit: 100) {
            let size = try #require(hit.uint("n"))
            let key = try #require(hit.data("key"))
            #expect(key == Data((0..<Int(size)).map { UInt8($0 % 256) }))
        }
    }

    @Test func stringsOfEverySizeClassRoundTrip() throws {
        // fixstr / str8 / str16 boundaries, plus multi-byte UTF-8.
        let values = ["", "x", String(repeating: "a", count: 31),
                      String(repeating: "a", count: 32),
                      String(repeating: "a", count: 255),
                      String(repeating: "a", count: 256),
                      String(repeating: "é🙂", count: 40)]
        let schema = SchemaBuilder().addStringField("s", stored: true).build()
        let index = try Index.inMemory(schema: schema)
        let w = try index.writer()
        for value in values {
            var doc = Document()
            doc["s"] = .string(value)
            try w.addDocument(doc)
        }
        try w.commitAndReload()

        let read = try index.search(.matchAll, limit: 100).compactMap { $0.string("s") }
        #expect(read.sorted() == values.sorted())
    }

    @Test func snippetsRoundTrip() throws {
        let index = try Fixtures.animalsIndex()
        let hits = try index.search(.parsed("sea"), highlight: ["title"])
        #expect(hits.count == 2)
        #expect(hits.allSatisfy { $0.snippet("title") != nil })
    }

    @Test func scoresSurvive() throws {
        // The score is the one f32 in the envelope, widened to a double on the
        // wire. Ordering and non-zero-ness both have to hold.
        let index = try Fixtures.animalsIndex()
        let hits = try index.search(.parsed("red sea"), limit: 10)
        #expect(!hits.isEmpty)
        #expect(hits.allSatisfy { $0.score > 0 })
        #expect(hits.map(\.score) == hits.map(\.score).sorted(by: >))
    }

    @Test func emptyResultDecodes() throws {
        let index = try Fixtures.animalsIndex()
        #expect(try index.search(.term("title", "nothingmatchesthis")).isEmpty)
    }

    @Test func manyHitsRoundTrip() throws {
        let schema = SchemaBuilder()
            .addTextField("body", stored: true)
            .addU64Field("n", stored: true, indexed: true, fast: true)
            .addBytesField("key", stored: true, indexed: true)
            .build()
        let index = try Index.inMemory(schema: schema)
        let w = try index.writer()
        for n in 0..<500 {
            var doc = Document()
            doc["body"] = .string("document number \(n) about search engines")
            doc["n"] = .unsigned(UInt64(n))
            doc.set("key", withUnsafeBytes(of: UInt64(n).bigEndian) { Data($0) })
            try w.addDocument(doc)
        }
        try w.commitAndReload()

        let hits = try index.search(.matchAll, limit: 500)
        #expect(hits.count == 500)
        for hit in hits {
            let n = try #require(hit.uint("n"))
            #expect(hit.data("key") == withUnsafeBytes(of: n.bigEndian) { Data($0) })
        }
        // The array header widens past fixarray at 16 elements, so a 500-hit
        // result exercises the array16 form.
        #expect(Set(hits.compactMap { $0.uint("n") }) == Set(0..<500))
    }

    @Test func unstoredFieldsAreAbsent() throws {
        let schema = SchemaBuilder()
            .addTextField("title", stored: true)
            .addTextField("body", stored: false)
            .build()
        let index = try Index.inMemory(schema: schema)
        let w = try index.writer()
        try w.addDocument(["title": "kept", "body": "dropped"])
        try w.commitAndReload()

        let hit = try #require(try index.search(.matchAll).first)
        #expect(hit.string("title") == "kept")
        #expect(hit["body"].isEmpty)
    }

    @Test func stringQueryPathUsesTheSameEnvelope() throws {
        // Both search entry points go through the same encoder; this pins the
        // query-string one, which the structured tests above do not cover.
        let index = try Fixtures.animalsIndex()
        let hits = try index.search("sea", limit: 10)
        #expect(hits.count == 2)
        #expect(hits.allSatisfy { $0.string("title") != nil })
    }
}
