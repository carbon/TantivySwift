import Foundation
import Testing
@testable import Tantivy

/// Coverage for field-ordered search (`orderBy:`), which replaces relevance
/// ranking with a fast-field sort.
struct SortTests {

    private func date(_ s: String) -> Date { ISO8601DateFormatter().date(from: s)! }

    /// year (u64, fast), rating (f64, fast), created (date, fast),
    /// position (i64, fast); plus a non-fast u64 and a raw string tag.
    private func corpus() throws -> Index {
        let schema = SchemaBuilder()
            .addTextField("title", stored: true)
            .addU64Field("year", stored: true, fast: true)
            .addF64Field("rating", stored: true, fast: true)
            .addI64Field("position", stored: true, fast: true)
            .addDateField("created", stored: true, fast: true)
            .addU64Field("pages", stored: true)            // not fast
            .addStringField("tag", stored: true, fast: true)
            .build()
        let index = try Index.inMemory(schema: schema)
        try index.add(contentsOf: [
            ["title": "old man", "year": 1952, "rating": 4.1, "position": -2,
             "created": "1952-09-01T00:00:00Z", "pages": 127, "tag": "book"],
            ["title": "mice and men", "year": 1937, "rating": 4.6, "position": 5,
             "created": "1937-01-01T00:00:00Z", "pages": 107, "tag": "book"],
            ["title": "moby dick", "year": 1851, "rating": 3.9, "position": 0,
             "created": "1851-01-01T00:00:00Z", "pages": 635, "tag": "classic"],
        ])
        return index
    }

    private func titles(_ hits: [SearchHit]) -> [String] {
        hits.compactMap { $0.string("title") }
    }

    @Test func orderByU64DescendingAndAscending() throws {
        let index = try corpus()
        #expect(titles(try index.search(.matchAll, orderBy: .descending("year"))) ==
                ["old man", "mice and men", "moby dick"])
        #expect(titles(try index.search(.matchAll, orderBy: .ascending("year"))) ==
                ["moby dick", "mice and men", "old man"])
    }

    @Test func orderByF64() throws {
        let index = try corpus()
        #expect(titles(try index.search(.matchAll, orderBy: .descending("rating"))) ==
                ["mice and men", "old man", "moby dick"])
    }

    @Test func orderByI64HandlesNegatives() throws {
        let index = try corpus()
        #expect(titles(try index.search(.matchAll, orderBy: .ascending("position"))) ==
                ["old man", "moby dick", "mice and men"])
    }

    @Test func orderByDate() throws {
        let index = try corpus()
        #expect(titles(try index.search(.matchAll, orderBy: .descending("created"))) ==
                ["old man", "mice and men", "moby dick"])
    }

    @Test func orderByAppliesToStringSearch() throws {
        let index = try corpus()
        // Matches two docs; ordered by year ascending, not relevance.
        #expect(titles(try index.search("old OR moby", orderBy: .ascending("year"))) ==
                ["moby dick", "old man"])
    }

    @Test func orderByRespectsLimit() throws {
        let index = try corpus()
        #expect(titles(try index.search(.matchAll, limit: 2, orderBy: .descending("year"))) ==
                ["old man", "mice and men"])
    }

    @Test func orderByComposesWithFilters() throws {
        let index = try corpus()
        let q: Query = .term("tag", "book") && .range("year", 1800...2000)
        #expect(titles(try index.search(q, orderBy: .ascending("year"))) ==
                ["mice and men", "old man"])
    }

    @Test func fieldOrderedHitsCarryZeroScore() throws {
        let index = try corpus()
        let hits = try index.search(.matchAll, orderBy: .descending("year"))
        #expect(hits.allSatisfy { $0.score == 0 })
    }

    @Test func orderByNonFastFieldThrows() throws {
        let index = try corpus()
        #expect(throws: TantivyError.self) {
            try index.search(.matchAll, orderBy: .descending("pages"))   // not fast
        }
    }

    @Test func orderByStringFieldThrows() throws {
        let index = try corpus()
        #expect(throws: TantivyError.self) {
            try index.search(.matchAll, orderBy: .ascending("tag"))
        }
    }

    @Test func orderByUnknownFieldThrows() throws {
        let index = try corpus()
        #expect(throws: TantivyError.self) {
            try index.search(.matchAll, orderBy: .descending("nope"))
        }
    }

    @Test func collectionSearchOrdersByField() throws {
        struct Book: Codable, Equatable { let title: String; let year: UInt64 }
        let books = SearchCollection<Book>(index: try corpus())
        let newestFirst = try books.search(.matchAll, orderBy: .descending("year"))
        #expect(newestFirst.map(\.year) == [1952, 1937, 1851])
        let oldestFirst = try books.search("old OR moby", orderBy: .ascending("year"))
        #expect(oldestFirst.map(\.title) == ["moby dick", "old man"])
    }
}
