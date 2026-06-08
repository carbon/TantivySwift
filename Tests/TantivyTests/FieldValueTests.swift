import Testing
@testable import Tantivy

/// Coverage for the Swift value types and `SearchHit` accessors — the parts of
/// the API that live entirely on the Swift side of the boundary.
struct FieldValueTests {

    @Test func fieldValueEquatable() {
        #expect(FieldValue.string("a") == .string("a"))
        #expect(FieldValue.string("a") != .string("b"))
        #expect(FieldValue.int(3) == .int(3))
        #expect(FieldValue.int(3) != .double(3))    // distinct cases
        #expect(FieldValue.int(3) != .unsigned(3))  // distinct cases
        #expect(FieldValue.unsigned(UInt64.max) == .unsigned(UInt64.max))
        #expect(FieldValue.double(2.5) == .double(2.5))
        #expect(FieldValue.bool(true) == .bool(true))
        #expect(FieldValue.bool(true) != .bool(false))
    }

    @Test func fieldValueDescription() {
        #expect(FieldValue.string("hi").description == "hi")
        #expect(FieldValue.int(-7).description == "-7")
        #expect(FieldValue.unsigned(UInt64.max).description == "18446744073709551615")
        #expect(FieldValue.double(3.5).description == "3.5")
        #expect(FieldValue.bool(false).description == "false")
    }

    // MARK: - SearchHit accessors

    private func oneRowHit() throws -> SearchHit {
        let schema = SchemaBuilder()
            .addTextField("t", stored: true)
            .addU64Field("u", stored: true)
            .addF64Field("f", stored: true)
            .addBoolField("b", stored: true)
            .build()
        let index = try Index.inMemory(schema: schema)
        let w = try index.writer()
        try w.addDocument(["t": "row", "u": 10, "f": 2.5, "b": true])
        try w.commitAndReload()
        return try #require(try index.search("row").first)
    }

    @Test func accessorsReturnTypedValues() throws {
        let hit = try oneRowHit()
        #expect(hit.string("t") == "row")
        #expect(hit.int("u") == 10)
        #expect(hit.double("f") == 2.5)
        #expect(hit.bool("b") == true)
    }

    @Test func accessorsCoerceBetweenIntAndDouble() throws {
        let hit = try oneRowHit()
        #expect(hit.double("u") == 10.0)  // int field read as double
        #expect(hit.int("f") == 2)        // double field read as int (truncates)
        #expect(hit.uint("u") == 10)      // non-negative int read as uint
        #expect(hit.uint("f") == 2)       // non-negative double read as uint
    }

    @Test func accessorsReturnNilForMissingOrWrongType() throws {
        let hit = try oneRowHit()
        #expect(hit.string("absent") == nil)
        #expect(hit.int("absent") == nil)
        #expect(hit.string("u") == nil)        // numeric field has no string value
        #expect(hit.int("t") == nil)           // text field has no int value
        #expect(hit.bool("u") == nil)          // numeric field is not a bool
        #expect(hit["absent"].isEmpty)         // subscript -> empty array
    }

    @Test func subscriptReturnsAllValuesInOrder() throws {
        let schema = SchemaBuilder()
            .addTextField("t", stored: true)
            .addStringField("tag", stored: true)
            .build()
        let index = try Index.inMemory(schema: schema)
        let w = try index.writer()
        try w.addDocument(["t": "x", "tag": ["one", "two", "three"]])
        try w.commitAndReload()
        let hit = try #require(try index.search("x").first)
        #expect(hit["tag"].map(\.description) == ["one", "two", "three"])
        #expect(hit.string("tag") == "one")  // first value
    }

    // MARK: - Error type

    @Test func errorDescriptions() {
        #expect(TantivyError.ffi("boom").description == "tantivy: boom")
        #expect(TantivyError.encoding("bad").description == "tantivy encoding: bad")
    }

    @Test func thrownErrorIsTantivyErrorWithMessage() throws {
        let index = try Fixtures.animalsIndex()
        let error = try #require(throws: TantivyError.self) {
            try index.search("year:not_a_number")
        }
        #expect(error.description.hasPrefix("tantivy:"))
        #expect(!error.description.isEmpty)
    }
}
