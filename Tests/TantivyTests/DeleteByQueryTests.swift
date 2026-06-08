import Foundation
import Testing
@testable import Tantivy

/// Coverage for the query-based / multi-term deletion API:
/// `IndexWriter.deleteDocuments(matching:)`, `deleteDocuments(field:equalsAnyOf:)`,
/// `Index.delete(matching:)`, and `SearchCollection.remove(matching:)`.
struct DeleteByQueryTests {

    /// id (raw string, single-token), year (u64), title (text) — three docs:
    /// (a, 2001, "red fox"), (b, 2002, "blue whale"), (c, 2003, "red crab").
    private func corpus() throws -> Index {
        let schema = SchemaBuilder()
            .addStringField("id", stored: true)
            .addU64Field("year", stored: true, fast: true)
            .addTextField("title", stored: true)
            .build()
        let index = try Index.inMemory(schema: schema)
        let w = try index.writer()
        try w.addDocument(["id": "a", "year": 2001, "title": "red fox"])
        try w.addDocument(["id": "b", "year": 2002, "title": "blue whale"])
        try w.addDocument(["id": "c", "year": 2003, "title": "red crab"])
        try w.commitAndReload()
        return index
    }

    private func ids(_ index: Index) throws -> [String] {
        try index.search(.matchAll).compactMap { $0.string("id") }.sorted()
    }

    @Test func deleteByTermQuery() throws {
        let index = try corpus()
        try index.delete(matching: .term("id", "b"))
        #expect(index.documentCount == 2)
        #expect(try ids(index) == ["a", "c"])
    }

    @Test func deleteByRangeQuery() throws {
        let index = try corpus()
        try index.delete(matching: .range("year", 2002...2003))   // removes b, c
        #expect(index.documentCount == 1)
        #expect(try ids(index) == ["a"])
    }

    @Test func deleteByComposedQuery() throws {
        let index = try corpus()
        // Delete docs that are "red" in title AND year >= 2003 → only c.
        try index.delete(matching: .phrase("title", ["red"]) && .range("year", 2003...2003))
        #expect(try ids(index) == ["a", "b"])
    }

    @Test func multiTermDeleteStrings() throws {
        let index = try corpus()
        try index.write { try $0.deleteDocuments(field: "id", equalsAnyOf: ["a", "c"]) }
        #expect(try ids(index) == ["b"])
    }

    @Test func multiTermDeleteUInt() throws {
        let index = try corpus()
        try index.write {
            try $0.deleteDocuments(field: "year", equalsAnyOf: [UInt64(2001), UInt64(2003)])
        }
        #expect(try ids(index) == ["b"])
    }

    @Test func emptyMultiTermDeleteIsNoop() throws {
        let index = try corpus()
        try index.write { try $0.deleteDocuments(field: "id", equalsAnyOf: [String]()) }
        #expect(index.documentCount == 3)
    }

    @Test func deleteIsNotVisibleUntilCommit() throws {
        let index = try corpus()
        let w = try index.writer()
        try w.deleteDocuments(matching: .matchAll)   // queued, not committed
        #expect(index.documentCount == 3)            // still visible
        try w.commitAndReload()
        #expect(index.documentCount == 0)            // now gone
    }

    @Test func collectionRemoveMatching() throws {
        struct Book: Codable, Equatable { let id: String; let year: UInt64 }
        let books = try SearchCollection<Book> { s in
            s.addStringField("id", stored: true)
            s.addU64Field("year", stored: true, fast: true)
        }
        try books.add(contentsOf: [
            Book(id: "x", year: 1990), Book(id: "y", year: 2000), Book(id: "z", year: 2010),
        ])
        try books.remove(matching: .range("year", 2000...2010))   // removes y, z
        #expect(books.count == 1)
        #expect(try books.search(.matchAll).map(\.id) == ["x"])
    }
}
