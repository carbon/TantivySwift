import Foundation
import Testing
@testable import Tantivy

/// Coverage for the typed `SearchCollection<Model>` façade.
struct CollectionTests {

    struct Book: Codable, Equatable {
        let title: String
        let year: UInt64
    }

    private func bookCollection() throws -> SearchCollection<Book> {
        try SearchCollection<Book> { s in
            s.addTextField("title", stored: true)
            s.addU64Field("year", stored: true, fast: true)
        }
    }

    @Test func addAndTypedSearch() throws {
        let books = try bookCollection()
        try books.add(Book(title: "Dune", year: 1965))
        try books.add(contentsOf: [
            Book(title: "Foundation", year: 1951),
            Book(title: "Neuromancer", year: 1984),
        ])
        #expect(books.count == 3)
        #expect(try books.search("title:dune") == [Book(title: "Dune", year: 1965)])
        #expect(try books.search("year:[1980 TO 2000]") == [Book(title: "Neuromancer", year: 1984)])
    }

    @Test func searchScoredIsOrderedByScore() throws {
        let books = try bookCollection()
        try books.add(contentsOf: [
            Book(title: "sea sea sea", year: 1),
            Book(title: "sea", year: 2),
        ])
        let scored = try books.searchScored("title:sea")
        #expect(scored.count == 2)
        #expect(scored[0].score >= scored[1].score)  // TopDocs orders by score
    }

    @Test func removeAllClearsTheCollection() throws {
        let books = try bookCollection()
        try books.add(Book(title: "x", year: 1))
        #expect(books.count == 1)
        try books.removeAll()
        #expect(books.count == 0)
        #expect(try books.search("title:x").isEmpty)
    }

    @Test func persistsAndReopens() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("tantivy-coll-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }

        let schema = SchemaBuilder()
            .addTextField("title", stored: true)
            .addU64Field("year", stored: true)
            .build()
        do {
            let books = try SearchCollection<Book>(path: dir, schema: schema)
            try books.add(Book(title: "Persisted", year: 2020))
            #expect(books.count == 1)
        }
        let reopened = try SearchCollection<Book>(path: dir, schema: schema)
        #expect(reopened.count == 1)
        #expect(try reopened.search("title:persisted").first == Book(title: "Persisted", year: 2020))
    }

    @Test func wrapsExistingIndex() throws {
        let schema = SchemaBuilder().addTextField("title", stored: true).addU64Field("year", stored: true).build()
        let index = try Index.inMemory(schema: schema)
        let books = SearchCollection<Book>(index: index)
        try books.add(Book(title: "Wrapped", year: 1))
        #expect(try index.search("title:wrapped").count == 1)   // same underlying index
        #expect(try books.search("title:wrapped").first == Book(title: "Wrapped", year: 1))
    }

    // MARK: - IndexableDocument

    struct Movie: IndexableDocument, Equatable {
        let title: String
        let year: UInt64
        static let searchSchema = SchemaBuilder()
            .addTextField("title", stored: true)
            .addU64Field("year", stored: true, fast: true)
            .build()
    }

    @Test func indexableDocumentInMemory() throws {
        let movies = try SearchCollection<Movie>.inMemory()
        try movies.add(Movie(title: "Alien", year: 1979))
        #expect(try movies.search("title:alien") == [Movie(title: "Alien", year: 1979)])
    }

    @Test func indexableDocumentNoArgInitIsInMemory() throws {
        let movies = try SearchCollection<Movie>()        // schema inferred from Movie
        try movies.add(Movie(title: "Aliens", year: 1986))
        #expect(movies.count == 1)
    }

    @Test func indexableDocumentPersistsToDisk() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("tantivy-indexable-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }

        do {
            let movies = try SearchCollection<Movie>(path: dir)   // no schema at call site
            try movies.add(Movie(title: "Blade Runner", year: 1982))
            #expect(movies.count == 1)
        }
        let reopened = try SearchCollection<Movie>(path: dir)
        #expect(try reopened.search("title:blade").first == Movie(title: "Blade Runner", year: 1982))
    }
}
