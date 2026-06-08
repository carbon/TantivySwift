import Testing
@testable import Tantivy

/// Coverage for the document-encoding paths: dictionaries, `Encodable`, raw
/// JSON, and the JSON marshalling round-trip (escaping, large numbers).
struct EncodingRoundTripTests {

    @Test func encodableWithArraysOptionalsAndCodingKeys() throws {
        struct Article: Encodable {
            let title: String
            let tags: [String]      // multi-valued
            let views: Int
            let subtitle: String?   // nil -> omitted by synthesized Codable
            enum CodingKeys: String, CodingKey { case title, tags, views, subtitle }
        }

        let schema = SchemaBuilder()
            .addTextField("title", stored: true)
            .addStringField("tags", stored: true)
            .addI64Field("views", stored: true)
            .addTextField("subtitle", stored: true)
            .build()
        let index = try Index.inMemory(schema: schema)
        let w = try index.writer()
        try w.addDocument(Article(title: "Hello", tags: ["swift", "rust"], views: 5, subtitle: nil))
        try w.addDocument(Article(title: "World", tags: ["search"], views: 9, subtitle: "a sub"))
        try w.commitAndReload()

        let hello = try #require(try index.search("title:Hello").first)
        #expect(Set(hello["tags"].map(\.description)) == ["swift", "rust"])
        #expect(hello.int("views") == 5)
        #expect(hello.string("subtitle") == nil)  // omitted optional

        let world = try #require(try index.search("title:World").first)
        #expect(world.string("subtitle") == "a sub")
        #expect(try index.search("tags:search").count == 1)
    }

    @Test func specialCharactersRoundTrip() throws {
        let schema = SchemaBuilder()
            .addTextField("body", stored: true)
            .addStringField("raw", stored: true)
            .build()
        let index = try Index.inMemory(schema: schema)
        let w = try index.writer()
        let value = "Quote \" backslash \\ slash / newline \n tab \t café 日本語 emoji 🚀"
        try w.addDocument(["body": value, "raw": value])
        try w.commitAndReload()

        // A tokenized term still matches…
        let hit = try #require(try index.search("café").first)
        // …and both stored fields survive JSON escaping intact.
        #expect(hit.string("body") == value)
        #expect(hit.string("raw") == value)
    }

    @Test func largeIntegersRoundTripExactly() throws {
        let schema = SchemaBuilder()
            .addTextField("t", stored: true)
            .addI64Field("big", stored: true)
            .addI64Field("neg", stored: true)
            .addU64Field("ubig", stored: true)
            .build()
        let index = try Index.inMemory(schema: schema)
        let w = try index.writer()
        let big: Int64 = 9_000_000_000_000_000_000     // > 2^53, < Int64.max
        let neg: Int64 = -9_000_000_000_000_000_000
        let ubig: UInt64 = 9_000_000_000_000_000_000
        try w.addDocument(["t": "x", "big": big, "neg": neg, "ubig": ubig])
        try w.commitAndReload()

        let hit = try #require(try index.search("x").first)
        #expect(hit.int("big") == big)   // no float-precision loss
        #expect(hit.int("neg") == neg)
        #expect(hit.int("ubig") == Int64(ubig))
    }

    @Test func floatFieldReadsBackThroughDoubleAccessor() throws {
        // A whole-valued f64 (4.0) categorizes as .int(4) after JSON decoding,
        // but the documented way to read numerics — the accessor — coerces it
        // back to the expected Double. A fractional value stays .double.
        let schema = SchemaBuilder()
            .addTextField("t", stored: true)
            .addF64Field("whole", stored: true)
            .addF64Field("frac", stored: true)
            .build()
        let index = try Index.inMemory(schema: schema)
        let w = try index.writer()
        try w.addDocument(["t": "x", "whole": 4.0, "frac": 3.5])
        try w.commitAndReload()

        let hit = try #require(try index.search("x").first)
        #expect(hit.double("whole") == 4.0)
        #expect(hit.double("frac") == 3.5)
        #expect(hit["frac"].first == .double(3.5))
    }

    @Test func u64AboveInt64MaxIsExact() throws {
        // The whole point of the .unsigned case: values past Int64.max survive.
        let schema = SchemaBuilder()
            .addTextField("t", stored: true)
            .addU64Field("max", stored: true)
            .addU64Field("over", stored: true)
            .build()
        let index = try Index.inMemory(schema: schema)
        let w = try index.writer()
        let over = UInt64(Int64.max) + 1            // 9223372036854775808
        try w.addDocument(["t": "x", "max": UInt64.max, "over": over])
        try w.commitAndReload()

        let hit = try #require(try index.search("x").first)
        #expect(hit["max"].first == .unsigned(UInt64.max))
        #expect(hit.uint("max") == UInt64.max)
        #expect(hit.int("max") == nil)   // does not fit in Int64
        #expect(hit.uint("over") == over)
    }

    @Test func emptyDocumentIsIndexed() throws {
        let schema = SchemaBuilder().addTextField("t", stored: true).build()
        let index = try Index.inMemory(schema: schema)
        let w = try index.writer()
        try w.addDocument([:])  // no fields set
        try w.commitAndReload()
        #expect(index.documentCount == 1)
    }

    @Test func addInvalidJSONStringThrows() throws {
        let schema = SchemaBuilder().addTextField("t", stored: true).build()
        let index = try Index.inMemory(schema: schema)
        let w = try index.writer()
        #expect(throws: TantivyError.self) {
            try w.addDocument(json: "{ not valid json")
        }
    }

    @Test func rawJSONAndDictionaryAgree() throws {
        let schema = SchemaBuilder()
            .addTextField("title", stored: true)
            .addU64Field("year", stored: true)
            .build()
        let index = try Index.inMemory(schema: schema)
        let w = try index.writer()
        try w.addDocument(["title": "Dune", "year": 1965])
        try w.addDocument(json: #"{"title": "Dune", "year": 1965}"#)
        try w.commitAndReload()

        let hits = try index.search("title:Dune")
        #expect(hits.count == 2)
        #expect(Set(hits.compactMap { $0.int("year") }) == [1965])
    }
}
