import Foundation
import Testing
@testable import Tantivy

/// Coverage for facet counts (`termCounts`) and the raw `aggregate` API.
struct AggregationTests {

    /// tag (raw string, fast) and year (u64, fast) are aggregatable.
    private func corpus() throws -> Index {
        let schema = SchemaBuilder()
            .addTextField("title", stored: true)
            .addTextField("body")
            .addStringField("tag", stored: true, fast: true)
            .addU64Field("year", stored: true, fast: true)
            .build()
        let index = try Index.inMemory(schema: schema)
        try index.add(contentsOf: [
            ["title": "The Old Man", "body": "he fished the sea", "tag": "book", "year": 1952],
            ["title": "Of Mice and Men", "body": "the salinas river", "tag": "book", "year": 1937],
            ["title": "Moby Dick", "body": "call me ishmael", "tag": "classic", "year": 1851],
        ])
        return index
    }

    @Test func termCountsOverAllDocuments() throws {
        let counts = try corpus().termCounts("tag")
        #expect(counts == [
            FacetCount(value: .string("book"), count: 2),
            FacetCount(value: .string("classic"), count: 1),
        ])
    }

    @Test func termCountsRespectsMatchingQuery() throws {
        let counts = try corpus().termCounts("tag", matching: .parsed("river"))
        #expect(counts == [FacetCount(value: .string("book"), count: 1)])
    }

    @Test func termCountsRespectsLimit() throws {
        let counts = try corpus().termCounts("tag", limit: 1)
        #expect(counts == [FacetCount(value: .string("book"), count: 2)])
    }

    @Test func termCountsOnNumericField() throws {
        let counts = try corpus().termCounts("year")
        #expect(counts.count == 3)
        #expect(counts.allSatisfy { $0.count == 1 })
        #expect(Set(counts.compactMap { c -> Int64? in
            if case .int(let i) = c.value { return i } else { return nil }
        }) == [1851, 1937, 1952])
    }

    @Test func termCountsOnNonFastFieldThrows() throws {
        #expect(throws: TantivyError.self) {
            try corpus().termCounts("title")   // not declared fast
        }
    }

    @Test func rawAggregateRunsArbitraryRequests() throws {
        let result = try corpus().aggregate(#"{"avg_year": {"avg": {"field": "year"}}}"#)
        #expect(result.contains("avg_year"))
        // (1952 + 1937 + 1851) / 3 = 1913.33…
        #expect(result.contains("1913.33"))
    }

    @Test func rawAggregateInvalidRequestThrows() throws {
        #expect(throws: TantivyError.self) {
            try corpus().aggregate(#"{"x": {"no_such_agg": {}}}"#)
        }
    }

    @Test func collectionTermCounts() throws {
        struct Book: Codable { let title: String; let tag: String }
        let books = SearchCollection<Book>(index: try corpus())
        let counts = try books.termCounts("tag")
        #expect(counts.first == FacetCount(value: .string("book"), count: 2))
    }
}
