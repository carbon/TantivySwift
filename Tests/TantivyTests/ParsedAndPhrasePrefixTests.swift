import Foundation
import Testing
@testable import Tantivy

/// Coverage for `.parsed` (a query string embedded in a structured query) and
/// `.phrasePrefix` (multi-word typeahead).
struct ParsedAndPhrasePrefixTests {

    /// title/body (text), tag (raw string), year (u64).
    private func corpus() throws -> Index {
        let schema = SchemaBuilder()
            .addTextField("title", stored: true)
            .addTextField("body", stored: true)
            .addStringField("tag", stored: true)
            .addU64Field("year", stored: true)
            .build()
        let index = try Index.inMemory(schema: schema)
        try index.add(contentsOf: [
            ["title": "The Old Man", "body": "he fished the sea", "tag": "book", "year": 1952],
            ["title": "Of Mice and Men", "body": "the salinas river", "tag": "book", "year": 1937],
            ["title": "Moby Dick", "body": "call me ishmael", "tag": "classic", "year": 1851],
        ])
        return index
    }

    private func titles(_ hits: [SearchHit]) -> Set<String> {
        Set(hits.compactMap { $0.string("title") })
    }

    // MARK: - .parsed

    @Test func parsedRunsTantivyQuerySyntax() throws {
        let index = try corpus()
        #expect(titles(try index.search(.parsed("man OR river"))) ==
                ["The Old Man", "Of Mice and Men"])
    }

    @Test func parsedAnalyzesInput() throws {
        // Unlike .term, the string goes through the field's analyzer, so raw
        // user input (here: uppercase) matches the lowercased indexed tokens.
        let index = try corpus()
        #expect(titles(try index.search(.parsed("MAN"))) == ["The Old Man"])
        #expect(try index.search(.term("title", "MAN")).isEmpty)
    }

    @Test func parsedCombinesWithStructuredFilters() throws {
        // The headline use case: what the user typed && programmatic filters.
        let index = try corpus()
        let q: Query = .parsed("man OR river") && .term("year", 1952)
        #expect(titles(try index.search(q)) == ["The Old Man"])
    }

    @Test func parsedRespectsDefaultFields() throws {
        let index = try corpus()
        #expect(try index.search(.parsed("man", fields: ["body"])).isEmpty)
        #expect(titles(try index.search(.parsed("sea", fields: ["body"]))) == ["The Old Man"])
    }

    @Test func parsedSyntaxErrorThrows() throws {
        let index = try corpus()
        #expect(throws: TantivyError.self) { try index.search(.parsed("AND")) }
    }

    @Test func parsedUnknownFieldThrows() throws {
        let index = try corpus()
        #expect(throws: TantivyError.self) {
            try index.search(.parsed("man", fields: ["nope"]))
        }
    }

    @Test func deleteByParsedQuery() throws {
        let index = try corpus()
        try index.delete(matching: .parsed("river"))
        #expect(index.documentCount == 2)
        #expect(try index.search(.parsed("river")).isEmpty)
    }

    // MARK: - .phrasePrefix

    @Test func phrasePrefixMatchesLastTermAsPrefix() throws {
        let index = try corpus()
        #expect(titles(try index.search(.phrasePrefix("title", ["old", "ma"]))) ==
                ["The Old Man"])
    }

    @Test func phrasePrefixRequiresTermOrder() throws {
        let index = try corpus()
        #expect(try index.search(.phrasePrefix("title", ["man", "ol"])).isEmpty)
    }

    @Test func phrasePrefixSingleTermIsPureTokenPrefix() throws {
        let index = try corpus()
        #expect(titles(try index.search(.phrasePrefix("title", ["ma"]))) == ["The Old Man"])
    }

    @Test func phrasePrefixEmptyTermsThrows() throws {
        let index = try corpus()
        #expect(throws: TantivyError.self) {
            try index.search(.phrasePrefix("title", []))
        }
    }
}
