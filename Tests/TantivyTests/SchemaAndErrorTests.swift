import Foundation
import Testing
@testable import Tantivy

/// Coverage for schema construction and error propagation across the FFI.
struct SchemaAndErrorTests {

    @Test func invalidSchemaJSONThrows() {
        // No "fields" array.
        #expect(throws: TantivyError.self) {
            try Index(path: nil, schema: Schema(json: "{}"))
        }
    }

    @Test func unsupportedFieldTypeThrows() throws {
        let bad = Schema(json: #"{"fields":[{"name":"x","type":"blob"}]}"#)
        let error = try #require(throws: TantivyError.self) {
            try Index(path: nil, schema: bad)
        }
        #expect("\(error)".contains("blob"))
    }

    @Test func unknownFieldInDocumentIsIgnored() throws {
        // tantivy's JSON document parser silently drops fields not in the schema.
        let schema = SchemaBuilder().addTextField("title", stored: true).build()
        let index = try Index.inMemory(schema: schema)
        let w = try index.writer()
        try w.addDocument(["title": "kept", "nope": "dropped"])
        try w.commitAndReload()

        let hit = try #require(try index.search("kept").first)
        #expect(hit.string("title") == "kept")
        #expect(hit["nope"].isEmpty)  // unknown field not stored
    }

    @Test func unknownDefaultFieldThrows() throws {
        let index = try Fixtures.animalsIndex()
        #expect(throws: TantivyError.self) {
            try index.search("x", fields: ["ghost"])
        }
    }

    @Test func malformedQueryThrows() throws {
        let index = try Fixtures.animalsIndex()
        #expect(throws: TantivyError.self) {
            try index.search("title:[unterminated")
        }
    }

    @Test func wrongTypeForNumericFieldThrows() throws {
        let index = try Fixtures.animalsIndex()
        #expect(throws: TantivyError.self) {
            try index.search("year:notanumber")
        }
    }

    @Test func emptyFieldsSchemaIsUsable() throws {
        // A schema with zero fields is valid; the index just holds nothing.
        let index = try Index(path: nil, schema: Schema(json: #"{"fields":[]}"#))
        #expect(index.documentCount == 0)
    }

    @Test func reopenWithMismatchedSchemaThrows() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("tantivy-mismatch-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }

        let a = SchemaBuilder().addTextField("title", stored: true).build()
        _ = try Index(path: dir, schema: a)   // creates on disk with schema A

        // Opening the same directory with a different schema must fail.
        let b = SchemaBuilder().addU64Field("id", stored: true).build()
        #expect(throws: TantivyError.self) {
            try Index(path: dir, schema: b)
        }
    }

    @Test func schemaBuilderProducesValidJSON() throws {
        let schema = SchemaBuilder()
            .addTextField("a", stored: true, indexed: true, tokenizer: .english, indexing: .freq)
            .addStringField("b")
            .addU64Field("c", fast: true)
            .build()
        // The produced spec must be parseable and round-trip through an index.
        let index = try Index.inMemory(schema: schema)
        #expect(index.documentCount == 0)
        #expect(schema.json.contains("\"en_stem\""))
    }
}
