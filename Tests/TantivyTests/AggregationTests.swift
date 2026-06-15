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

    /// A multi-valued fast string field — the "an object can have several
    /// authors" case. Each value of a document contributes to its own bucket, so
    /// a co-authored document is counted once under each author.
    @Test func termCountsOverMultiValuedField() throws {
        let schema = SchemaBuilder()
            .addTextField("title", stored: true)
            .addStringField("author", stored: true, fast: true)
            .build()
        let index = try Index.inMemory(schema: schema)
        try index.add(contentsOf: [
            Document(["title": "Solo", "author": .array(["Ernest Hemingway"])]),
            Document(["title": "Co-authored",
                      "author": .array(["Ernest Hemingway", "John Steinbeck"])]),
            Document(["title": "Other", "author": .array(["Herman Melville"])]),
        ])

        let counts = try index.termCounts("author")
        let byAuthor = Dictionary(
            uniqueKeysWithValues: counts.compactMap { c -> (String, Int)? in
                if case .string(let s) = c.value { return (s, c.count) } else { return nil }
            })
        // A `string` field keeps each multi-word name as ONE bucket — no
        // tokenization into "John"/"Steinbeck". Hemingway appears in two docs.
        #expect(byAuthor == [
            "Ernest Hemingway": 2, "John Steinbeck": 1, "Herman Melville": 1,
        ])
    }

    /// Multi-valued counts also honour the matching query: only documents the
    /// query selects contribute their authors.
    @Test func termCountsOverMultiValuedFieldRespectsQuery() throws {
        let schema = SchemaBuilder()
            .addTextField("title", stored: true)
            .addStringField("author", stored: true, fast: true)
            .build()
        let index = try Index.inMemory(schema: schema)
        try index.add(contentsOf: [
            Document(["title": "Solo", "author": .array(["Hemingway"])]),
            Document(["title": "Co-authored", "author": .array(["Hemingway", "Steinbeck"])]),
        ])

        let counts = try index.termCounts("author", matching: .parsed("co-authored"))
        let byAuthor = Dictionary(
            uniqueKeysWithValues: counts.compactMap { c -> (String, Int)? in
                if case .string(let s) = c.value { return (s, c.count) } else { return nil }
            })
        #expect(byAuthor == ["Hemingway": 1, "Steinbeck": 1])
    }

    /// The type-ahead path: a `.prefix` query scopes which documents are
    /// counted, so `termCounts` returns just the authors whose names start with
    /// what the user has typed, each with its document count. The prefix is
    /// matched against the raw (un-analyzed) `string` token, so it is
    /// case-sensitive — lowercase the input and use a `.tag`-analyzed field for
    /// case-insensitive type-ahead.
    @Test func prefixScopedTermCountsForTypeAhead() throws {
        let schema = SchemaBuilder()
            .addTextField("title", stored: true)
            .addStringField("author", stored: true, fast: true)
            .build()
        let index = try Index.inMemory(schema: schema)
        try index.add(contentsOf: [
            Document(["title": "East of Eden", "author": "John Steinbeck"]),
            Document(["title": "The Grapes of Wrath", "author": "John Steinbeck"]),
            Document(["title": "Pride and Prejudice", "author": "Jane Austen"]),
            Document(["title": "The Old Man and the Sea", "author": "Ernest Hemingway"]),
        ])

        let counts = try index.termCounts("author", matching: .prefix("author", "J"))
        let byAuthor = Dictionary(
            uniqueKeysWithValues: counts.compactMap { c -> (String, Int)? in
                if case .string(let s) = c.value { return (s, c.count) } else { return nil }
            })
        // Only "J…" authors surface; Hemingway (starts with E) is excluded.
        #expect(byAuthor == ["John Steinbeck": 2, "Jane Austen": 1])
    }

    @Test func collectionTermCounts() throws {
        struct Book: Codable { let title: String; let tag: String }
        let books = SearchCollection<Book>(index: try corpus())
        let counts = try books.termCounts("tag")
        #expect(counts.first == FacetCount(value: .string("book"), count: 2))
    }
}
