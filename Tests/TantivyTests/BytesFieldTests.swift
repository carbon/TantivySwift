import Foundation
import Testing
@testable import Tantivy

/// Coverage for `bytes` fields — the one value type that crosses the FFI as raw
/// memory rather than inside JSON. The point of most of these tests is that a
/// value survives *unchanged*, including the byte patterns (NULs, invalid UTF-8)
/// that the JSON path could not have carried.
struct BytesFieldTests {

    /// A key with an interior NUL, a lone continuation byte, and 0xFF — none of
    /// which can appear in a valid UTF-8 JSON string.
    private static let awkwardKey = Data([0x00, 0xFF, 0x80, 0x00, 0x41, 0xC3, 0x28])

    private func keyedIndex(fast: Bool = false) throws -> Index {
        let schema = SchemaBuilder()
            .addBytesField("key", stored: true, indexed: true, fast: fast)
            .addTextField("body", stored: true)
            .build()
        return try Index.inMemory(schema: schema)
    }

    // MARK: - Round trip

    @Test func storedBytesRoundTripUnchanged() throws {
        let index = try keyedIndex()
        let w = try index.writer()
        try w.addDocument(["key": Self.awkwardKey, "body": "hello"])
        try w.commitAndReload()

        let hit = try #require(try index.search("hello").first)
        #expect(hit.data("key") == Self.awkwardKey)
        #expect(hit.string("body") == "hello")
    }

    @Test func everyByteValueSurvives() throws {
        // All 256 byte values in one key: nothing is escaped, dropped, or
        // remapped on the way through.
        let allBytes = Data((0...255).map { UInt8($0) })
        let index = try keyedIndex()
        let w = try index.writer()
        try w.addDocument(["key": allBytes, "body": "full"])
        try w.commitAndReload()

        let hit = try #require(try index.search("full").first)
        #expect(hit.data("key") == allBytes)
    }

    @Test func emptyBytesValueRoundTrips() throws {
        let index = try keyedIndex()
        let w = try index.writer()
        try w.addDocument(["key": Data(), "body": "empty"])
        try w.commitAndReload()

        let hit = try #require(try index.search("empty").first)
        #expect(hit.data("key") == Data())
    }

    @Test func largeBytesValueRoundTrips() throws {
        let large = Data((0..<100_000).map { UInt8($0 % 256) })
        let index = try keyedIndex()
        let w = try index.writer()
        try w.addDocument(["key": large, "body": "large"])
        try w.commitAndReload()

        let hit = try #require(try index.search("large").first)
        #expect(hit.data("key") == large)
    }

    // MARK: - Querying

    @Test func termQueryMatchesExactBytes() throws {
        let index = try keyedIndex()
        let w = try index.writer()
        try w.addDocument(["key": Self.awkwardKey, "body": "target"])
        try w.addDocument(["key": Data([0x01, 0x02]), "body": "other"])
        try w.commitAndReload()

        let hits = try index.search(.term("key", Self.awkwardKey))
        #expect(hits.count == 1)
        #expect(hits.first?.string("body") == "target")
    }

    @Test func termQueryDoesNotMatchAPrefix() throws {
        // A truncation bug at the C boundary would make the prefix match; the
        // whole value is one term, so it must not.
        let index = try keyedIndex()
        let w = try index.writer()
        try w.addDocument(["key": Data([0x01, 0x02, 0x03]), "body": "full"])
        try w.commitAndReload()

        #expect(try index.search(.term("key", Data([0x01, 0x02]))).isEmpty)
        #expect(try index.search(.term("key", Data([0x01, 0x02, 0x03]))).count == 1)
    }

    @Test func termQueryDistinguishesKeysSharingALeadingNUL() throws {
        // Both keys start with a NUL: if either were carried as a C string they
        // would collapse to the same empty term.
        let a = Data([0x00, 0x01])
        let b = Data([0x00, 0x02])
        let index = try keyedIndex()
        let w = try index.writer()
        try w.addDocument(["key": a, "body": "first"])
        try w.addDocument(["key": b, "body": "second"])
        try w.commitAndReload()

        #expect(try index.search(.term("key", a)).first?.string("body") == "first")
        #expect(try index.search(.term("key", b)).first?.string("body") == "second")
    }

    @Test func countMatchesSearch() throws {
        let index = try keyedIndex()
        let w = try index.writer()
        try w.addDocument(["key": Self.awkwardKey, "body": "one"])
        try w.addDocument(["key": Data([0x09]), "body": "two"])
        try w.commitAndReload()

        #expect(try index.count(.term("key", Self.awkwardKey)) == 1)
        #expect(try index.count(.term("key", Data([0xAB]))) == 0)
    }

    @Test func byteArgumentsSurviveBooleanComposition() throws {
        // Three byte values in one tree: each `{"$bytes":i}` must resolve to the
        // value at that index, so mis-threading the collector would swap them.
        let a = Data([0xAA])
        let b = Data([0xBB])
        let c = Data([0xCC])
        let index = try keyedIndex()
        let w = try index.writer()
        try w.addDocument(["key": a, "body": "alpha"])
        try w.addDocument(["key": b, "body": "beta"])
        try w.addDocument(["key": c, "body": "gamma"])
        try w.commitAndReload()

        let query = (Query.term("key", a) || Query.term("key", b))
            .excluding(.term("key", c))
        let bodies = try index.search(query).compactMap { $0.string("body") }.sorted()
        #expect(bodies == ["alpha", "beta"])
    }

    @Test func mixedByteAndScalarTermsInOneQuery() throws {
        let schema = SchemaBuilder()
            .addBytesField("key", stored: true, indexed: true)
            .addStringField("tag", stored: true, indexed: true)
            .build()
        let index = try Index.inMemory(schema: schema)
        let w = try index.writer()
        try w.addDocument(["key": Data([0x01]), "tag": "keep"])
        try w.addDocument(["key": Data([0x01]), "tag": "drop"])
        try w.commitAndReload()

        let hits = try index.search(.term("key", Data([0x01])) && .term("tag", "keep"))
        #expect(hits.count == 1)
        #expect(hits.first?.string("tag") == "keep")
    }

    // MARK: - Delete and upsert

    @Test func deleteByBytesKey() throws {
        let index = try keyedIndex()
        let w = try index.writer()
        try w.addDocument(["key": Self.awkwardKey, "body": "doomed"])
        try w.addDocument(["key": Data([0x07]), "body": "spared"])
        try w.commitAndReload()

        try w.deleteDocuments(field: "key", equals: Self.awkwardKey)
        try w.commitAndReload()

        #expect(index.documentCount == 1)
        #expect(try index.search(.matchAll).first?.string("body") == "spared")
    }

    @Test func upsertOnABytesKeyReplacesInPlace() throws {
        let index = try keyedIndex()
        let w = try index.writer()
        try w.addDocument(["key": Self.awkwardKey, "body": "first"])
        try w.commitAndReload()

        try w.deleteDocuments(field: "key", equals: Self.awkwardKey)
        try w.addDocument(["key": Self.awkwardKey, "body": "second"])
        try w.commitAndReload()

        #expect(index.documentCount == 1)
        let hit = try #require(try index.search(.term("key", Self.awkwardKey)).first)
        #expect(hit.string("body") == "second")
        #expect(hit.data("key") == Self.awkwardKey)
    }

    @Test func deleteByAnyOfBytesKeys() throws {
        let index = try keyedIndex()
        let w = try index.writer()
        try w.addDocument(["key": Data([0x01]), "body": "a"])
        try w.addDocument(["key": Data([0x02]), "body": "b"])
        try w.addDocument(["key": Data([0x03]), "body": "c"])
        try w.commitAndReload()

        try w.deleteDocuments(field: "key", equalsAnyOf: [Data([0x01]), Data([0x03])])
        try w.commitAndReload()

        #expect(index.documentCount == 1)
        #expect(try index.search(.matchAll).first?.string("body") == "b")
    }

    @Test func deleteByQueryWithABytesTerm() throws {
        let index = try keyedIndex()
        let w = try index.writer()
        try w.addDocument(["key": Self.awkwardKey, "body": "doomed"])
        try w.addDocument(["key": Data([0x07]), "body": "spared"])
        try w.commitAndReload()

        try w.deleteDocuments(matching: .term("key", Self.awkwardKey))
        try w.commitAndReload()

        #expect(index.documentCount == 1)
    }

    // MARK: - Document and typed paths

    @Test func typedDocumentCarriesBytes() throws {
        let index = try keyedIndex()
        var doc = Document()
        doc.set("key", Self.awkwardKey)
        doc["body"] = "typed"
        try index.add(doc)

        let hit = try #require(try index.search("typed").first)
        #expect(hit.data("key") == Self.awkwardKey)
    }

    @Test func multiValuedBytesFieldKeepsEveryValueInOrder() throws {
        let index = try keyedIndex()
        var doc = Document()
        doc["key"] = .array([.bytes(Data([0x01])), .bytes(Data([0x02])), .bytes(Data([0x03]))])
        doc["body"] = "multi"
        try index.add(doc)

        let hit = try #require(try index.search("multi").first)
        let values: [Data] = hit["key"].compactMap {
            if case .bytes(let d) = $0 { return d } else { return nil }
        }
        #expect(values == [Data([0x01]), Data([0x02]), Data([0x03])])
        // Each value is its own term, so any of them finds the document.
        #expect(try index.count(.term("key", Data([0x02]))) == 1)
    }

    @Test func arrayOfDataInTheDictionaryPath() throws {
        let index = try keyedIndex()
        let w = try index.writer()
        try w.addDocument(["key": [Data([0x0A]), Data([0x0B])], "body": "pair"])
        try w.commitAndReload()

        #expect(try index.count(.term("key", Data([0x0A]))) == 1)
        #expect(try index.count(.term("key", Data([0x0B]))) == 1)
    }

    /// A field holds exactly one type, so a mixed array is always a mistake.
    /// The decoder is schema-driven — it reads each value as the field's
    /// declared type — so the string in this array is rejected as "not a byte
    /// string" when the document is added.
    @Test func mixingBytesWithOtherTypesInOneFieldThrows() throws {
        let index = try keyedIndex()
        let w = try index.writer()
        var doc = Document()
        doc["key"] = .array([.bytes(Data([0x01])), .string("nope")])
        #expect(throws: TantivyError.self) { try w.addDocument(doc) }
    }

    @Test func decodableModelReadsDataProperty() throws {
        struct Row: Decodable, Equatable {
            let key: Data
            let body: String
        }
        let index = try keyedIndex()
        let w = try index.writer()
        try w.addDocument(["key": Self.awkwardKey, "body": "model"])
        try w.commitAndReload()

        let rows = try index.search(.matchAll, as: Row.self)
        #expect(rows == [Row(key: Self.awkwardKey, body: "model")])
    }

    @Test func encodableModelRoundTripsViaBase64() throws {
        // The `Encodable` path is the documented exception: `Data` goes through
        // JSONEncoder's base64, which the engine decodes back into the field.
        // The value must still come back identical.
        struct Row: Encodable {
            let key: Data
            let body: String
        }
        let index = try keyedIndex()
        let w = try index.writer()
        try w.addDocument(Row(key: Self.awkwardKey, body: "encoded"))
        try w.commitAndReload()

        let hit = try #require(try index.search("encoded").first)
        #expect(hit.data("key") == Self.awkwardKey)
    }

    // MARK: - Persistence and errors

    @Test func bytesSurviveReopeningFromDisk() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("tantivy-bytes-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }

        let schema = SchemaBuilder()
            .addBytesField("key", stored: true, indexed: true)
            .addTextField("body", stored: true)
            .build()

        do {
            let index = try Index(path: dir, schema: schema)
            let w = try index.writer()
            try w.addDocument(["key": Self.awkwardKey, "body": "persisted"])
            try w.commitAndReload()
        }

        let reopened = try Index(path: dir, schema: schema)
        let hit = try #require(try reopened.search(.term("key", Self.awkwardKey)).first)
        #expect(hit.data("key") == Self.awkwardKey)
        #expect(hit.string("body") == "persisted")
    }

    @Test func bytesTermOnANonBytesFieldThrows() throws {
        let schema = SchemaBuilder().addStringField("tag", stored: true).build()
        let index = try Index.inMemory(schema: schema)
        #expect(throws: TantivyError.self) {
            try index.search(.term("tag", Data([0x01])))
        }
    }

    @Test func deleteByBytesOnANonBytesFieldThrows() throws {
        let schema = SchemaBuilder().addStringField("tag", stored: true).build()
        let index = try Index.inMemory(schema: schema)
        let w = try index.writer()
        #expect(throws: TantivyError.self) {
            try w.deleteDocuments(field: "tag", equals: Data([0x01]))
        }
    }

    @Test func addingBytesToANonBytesFieldThrows() throws {
        let schema = SchemaBuilder().addStringField("tag", stored: true).build()
        let index = try Index.inMemory(schema: schema)
        let w = try index.writer()
        #expect(throws: TantivyError.self) {
            try w.addDocument(["tag": Data([0x01])])
        }
    }

    @Test func bytesFieldNameWithInteriorNULThrows() throws {
        let index = try keyedIndex()
        let w = try index.writer()
        #expect(throws: TantivyError.self) {
            try w.addDocument(["ke\u{0}y": Data([0x01])])
        }
    }

    // MARK: - Blob mechanics

    @Test func manyBytesValuesInOneResultResolveIndependently() throws {
        // Every hit's value lands in one shared blob; each must slice back out
        // at its own offset.
        let index = try keyedIndex()
        let w = try index.writer()
        let keys = (0..<50).map { i in Data((0...UInt8(i)).map { $0 }) }
        for (i, key) in keys.enumerated() {
            try w.addDocument(["key": key, "body": "row \(i)"])
        }
        try w.commitAndReload()

        let hits = try index.search(.matchAll, limit: 50)
        #expect(hits.count == 50)
        let recovered = Set(hits.compactMap { $0.data("key") })
        #expect(recovered == Set(keys))
    }

    @Test func documentsWithoutBytesLeaveTheBlobEmpty() throws {
        // The blob path must not disturb an ordinary result.
        let index = try Fixtures.animalsIndex()
        let hits = try index.search("sea")
        #expect(hits.count == 2)
        #expect(hits.allSatisfy { $0.data("title") == nil })
    }
}
