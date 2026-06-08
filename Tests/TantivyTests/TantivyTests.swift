import Foundation
import Testing
@testable import Tantivy

/// End-to-end smoke coverage over a small corpus.
struct TantivyTests {

    private func bookSchema() -> Schema {
        SchemaBuilder()
            .addTextField("title", stored: true)
            .addTextField("body", stored: false)
            .addU64Field("year", stored: true, indexed: true, fast: true)
            .build()
    }

    private func makeIndex() throws -> Index {
        let index = try Index.inMemory(schema: bookSchema())
        let writer = try index.writer()
        try writer.addDocument([
            "title": "The Old Man and the Sea",
            "body": "He was an old man who fished alone in a skiff in the Gulf Stream.",
            "year": 1952,
        ])
        try writer.addDocument([
            "title": "Of Mice and Men",
            "body": "A few miles south of Soledad, the Salinas River drops in close to the hillside bank.",
            "year": 1937,
        ])
        try writer.addDocument([
            "title": "Moby Dick",
            "body": "Call me Ishmael. There she blows! a hump like a snow-hill. It was Moby Dick.",
            "year": 1851,
        ])
        try writer.commitAndReload()
        return index
    }

    @Test func version() {
        #expect(Tantivy.version.contains("0.26.1"))
    }

    @Test func documentCount() throws {
        #expect(try makeIndex().documentCount == 3)
    }

    @Test func basicSearch() throws {
        let hits = try makeIndex().search("sea", limit: 10)
        #expect(hits.count == 1)
        #expect(hits.first?.string("title") == "The Old Man and the Sea")
    }

    @Test func searchAcrossDefaultFields() throws {
        // "Ishmael" only appears in the body, which is not stored but is indexed.
        let hits = try makeIndex().search("Ishmael")
        #expect(hits.count == 1)
        #expect(hits.first?.string("title") == "Moby Dick")
    }

    @Test func fieldScopedQuery() throws {
        let hits = try makeIndex().search("title:men")
        #expect(hits.count == 1)
        #expect(hits.first?.string("title") == "Of Mice and Men")
    }

    @Test func storedNumericRoundTrips() throws {
        let hits = try makeIndex().search("title:moby")
        #expect(hits.first?.int("year") == 1851)
    }

    @Test func rangeQueryOnNumeric() throws {
        let hits = try makeIndex().search("year:[1900 TO 2000]")
        #expect(Set(hits.compactMap { $0.string("title") }) ==
                ["The Old Man and the Sea", "Of Mice and Men"])
    }

    @Test func noMatch() throws {
        #expect(try makeIndex().search("zebra").isEmpty)
    }

    @Test func scoresDescending() throws {
        // "and" is a title term in both "The Old Man and the Sea" and
        // "Of Mice and Men" (the default tokenizer lowercases but does not stem).
        let hits = try makeIndex().search("and")
        #expect(hits.count >= 2)
        for i in 1..<hits.count {
            #expect(hits[i - 1].score >= hits[i].score)
        }
    }

    @Test func multiValuedField() throws {
        let schema = SchemaBuilder()
            .addTextField("title", stored: true)
            .addStringField("tag", stored: true)
            .build()
        let index = try Index.inMemory(schema: schema)
        let writer = try index.writer()
        try writer.addDocument(["title": "Polyglot", "tag": ["rust", "swift"]])
        try writer.commitAndReload()

        let hits = try index.search("tag:swift")
        #expect(hits.count == 1)
        #expect(Set(hits[0]["tag"].map(\.description)) == ["rust", "swift"])
    }

    @Test func encodableDocument() throws {
        struct Book: Encodable { let title: String; let body: String; let year: UInt64 }
        let index = try Index.inMemory(schema: bookSchema())
        let writer = try index.writer()
        try writer.addDocument(Book(title: "Dune", body: "Spice must flow on Arrakis.", year: 1965))
        try writer.commitAndReload()

        let hits = try index.search("Arrakis")
        #expect(hits.first?.string("title") == "Dune")
        #expect(hits.first?.int("year") == 1965)
    }

    @Test func deleteAll() throws {
        let index = try makeIndex()
        let writer = try index.writer()
        try writer.deleteAllDocuments()
        try writer.commitAndReload()
        #expect(index.documentCount == 0)
        #expect(try index.search("sea").isEmpty)
    }

    @Test func persistenceRoundTrip() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("tantivy-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }

        do {
            let index = try Index(path: dir, schema: bookSchema())
            let writer = try index.writer()
            try writer.addDocument(["title": "Persisted Title", "body": "durable", "year": 2020])
            try writer.commitAndReload()
            #expect(index.documentCount == 1)
        }
        // Reopen from disk; data should still be there.
        let reopened = try Index(path: dir, schema: bookSchema())
        #expect(reopened.documentCount == 1)
        #expect(try reopened.search("durable").first?.string("title") == "Persisted Title")
    }

    @Test func invalidQueryThrows() throws {
        let index = try makeIndex()
        #expect(throws: (any Error).self) {
            try index.search("year:notanumber")
        }
    }
}
