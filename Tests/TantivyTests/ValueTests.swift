import Testing
@testable import Tantivy

/// Coverage for field-value round-tripping and decoding in search hits.
struct ValueTests {

    @Test func unstoredFieldsAreNotReturned() throws {
        let schema = SchemaBuilder()
            .addTextField("title", stored: true)
            .addTextField("body", stored: false)   // searchable, not returned
            .build()
        let index = try Index.inMemory(schema: schema)
        let w = try index.writer()
        try w.addDocument(["title": "Visible", "body": "hidden secret text"])
        try w.commitAndReload()

        let hit = try #require(try index.search("secret").first)
        #expect(hit.string("title") == "Visible")
        #expect(hit.string("body") == nil)
        #expect(hit["body"].isEmpty)
    }

    @Test func allNumericTypesRoundTrip() throws {
        let schema = SchemaBuilder()
            .addTextField("t", stored: true)
            .addU64Field("u", stored: true)
            .addI64Field("i", stored: true)
            .addF64Field("f", stored: true)
            .addBoolField("b", stored: true)
            .build()
        let index = try Index.inMemory(schema: schema)
        let w = try index.writer()
        try w.addDocument(["t": "row", "u": 42, "i": -7, "f": 3.5, "b": true])
        try w.commitAndReload()

        let hit = try #require(try index.search("row").first)
        #expect(hit.int("u") == 42)
        #expect(hit.int("i") == -7)
        #expect(hit.double("f") == 3.5)
        #expect(hit.bool("b") == true)
    }

    @Test func integerZeroAndOneDecodeAsInts() throws {
        // Regression: JSON 0/1 must not be misclassified as Bool.
        let schema = SchemaBuilder()
            .addTextField("t", stored: true)
            .addU64Field("zero", stored: true)
            .addU64Field("one", stored: true)
            .addBoolField("flag", stored: true)
            .build()
        let index = try Index.inMemory(schema: schema)
        let w = try index.writer()
        try w.addDocument(["t": "row", "zero": 0, "one": 1, "flag": true])
        try w.commitAndReload()

        let hit = try #require(try index.search("row").first)
        #expect(hit.int("zero") == 0)
        #expect(hit.int("one") == 1)
        #expect(hit["zero"].first == .int(0))     // not .bool(false)
        #expect(hit["one"].first == .int(1))      // not .bool(true)
        #expect(hit["flag"].first == .bool(true)) // real bool stays bool
    }

    @Test func boolFieldQuery() throws {
        let schema = SchemaBuilder()
            .addTextField("t", stored: true)
            .addBoolField("active", stored: true, indexed: true)
            .build()
        let index = try Index.inMemory(schema: schema)
        let w = try index.writer()
        try w.addDocument(["t": "on", "active": true])
        try w.addDocument(["t": "off", "active": false])
        try w.commitAndReload()

        #expect(try index.search("active:true").first?.string("t") == "on")
        #expect(try index.search("active:false").first?.string("t") == "off")
    }

    @Test func negativeI64Range() throws {
        let schema = SchemaBuilder()
            .addTextField("t", stored: true)
            .addI64Field("temp", stored: true, indexed: true)
            .build()
        let index = try Index.inMemory(schema: schema)
        let w = try index.writer()
        try w.addDocument(["t": "cold", "temp": -5])
        try w.addDocument(["t": "zero", "temp": 0])
        try w.addDocument(["t": "warm", "temp": 5])
        try w.commitAndReload()

        let hits = try index.search("temp:[-10 TO -1]")
        #expect(hits.compactMap { $0.string("t") } == ["cold"])
    }

    @Test func f64Range() throws {
        let schema = SchemaBuilder()
            .addTextField("t", stored: true)
            .addF64Field("rating", stored: true, indexed: true)
            .build()
        let index = try Index.inMemory(schema: schema)
        let w = try index.writer()
        try w.addDocument(["t": "a", "rating": 4.2])
        try w.addDocument(["t": "b", "rating": 4.8])
        try w.addDocument(["t": "c", "rating": 3.5])
        try w.commitAndReload()

        #expect(Set(try index.search("rating:[4.0 TO 5.0]").compactMap { $0.string("t") }) == ["a", "b"])
    }

    @Test func multiValuedNumericField() throws {
        let schema = SchemaBuilder()
            .addTextField("t", stored: true)
            .addU64Field("n", stored: true, indexed: true)
            .build()
        let index = try Index.inMemory(schema: schema)
        let w = try index.writer()
        try w.addDocument(["t": "multi", "n": [1, 2, 3]])
        try w.commitAndReload()

        let hit = try #require(try index.search("multi").first)
        let values = Set(hit["n"].compactMap { v -> Int64? in
            if case .int(let i) = v { return i }; return nil
        })
        #expect(values == [1, 2, 3])
        // A range still matches a doc via any of its values.
        #expect(try index.search("n:[3 TO 9]").count == 1)
    }
}
