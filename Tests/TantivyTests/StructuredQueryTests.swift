import Foundation
import Testing
@testable import Tantivy

/// Coverage for the structured query API (`Query`) that mirrors tantivy's own
/// query types.
struct StructuredQueryTests {

    private func date(_ s: String) -> Date { ISO8601DateFormatter().date(from: s)! }

    /// title (default-tokenized), body (positions), tag (raw), year (u64), created (date).
    private func corpus() throws -> Index {
        let schema = SchemaBuilder()
            .addTextField("title", stored: true)
            .addTextField("body", stored: true)
            .addStringField("tag", stored: true)
            .addU64Field("year", stored: true, indexed: true)
            .addDateField("created", stored: true, indexed: true)
            .build()
        let index = try Index.inMemory(schema: schema)
        try index.add(contentsOf: [
            ["title": "The Old Man", "body": "he fished the sea", "tag": "book",
             "year": 1952, "created": "1952-09-01T00:00:00Z"],
            ["title": "Of Mice and Men", "body": "the salinas river", "tag": "book",
             "year": 1937, "created": "1937-01-01T00:00:00Z"],
            ["title": "Moby Dick", "body": "call me ishmael", "tag": "classic",
             "year": 1851, "created": "1851-01-01T00:00:00Z"],
        ])
        return index
    }

    private func titles(_ hits: [SearchHit]) -> Set<String> {
        Set(hits.compactMap { $0.string("title") })
    }

    @Test func matchAll() throws {
        #expect(try corpus().search(.matchAll).count == 3)
    }

    @Test func termOnTextMatchesIndexedToken() throws {
        // default tokenizer lowercases; "The Old Man" -> [the, old, man]
        #expect(titles(try corpus().search(.term("title", "old"))) == ["The Old Man"])
    }

    @Test func termOnRawStringIsExactAndCaseSensitive() throws {
        let index = try corpus()
        #expect(try index.search(.term("tag", "book")).count == 2)
        #expect(try index.search(.term("tag", "Book")).isEmpty)   // raw is case-sensitive
    }

    @Test func termOnNumeric() throws {
        #expect(titles(try corpus().search(.term("year", 1851))) == ["Moby Dick"])
    }

    @Test func numericRange() throws {
        #expect(titles(try corpus().search(.range("year", 1900...2000))) ==
                ["The Old Man", "Of Mice and Men"])
    }

    @Test func booleanMust() throws {
        let q: Query = .term("tag", "book") && .term("title", "old")
        #expect(titles(try corpus().search(q)) == ["The Old Man"])
    }

    @Test func booleanShould() throws {
        let q: Query = .term("title", "moby") || .term("title", "mice")
        #expect(titles(try corpus().search(q)) == ["Moby Dick", "Of Mice and Men"])
    }

    @Test func excludingIsMustNot() throws {
        let q = Query.term("tag", "book").excluding(.term("title", "mice"))
        #expect(titles(try corpus().search(q)) == ["The Old Man"])
    }

    @Test func boostChangesRanking() throws {
        let q: Query = Query.term("title", "moby").boosted(by: 5) || .term("title", "old")
        let hits = try corpus().search(q)
        #expect(hits.count == 2)
        #expect(hits.first?.string("title") == "Moby Dick")
    }

    @Test func phraseRequiresAdjacency() throws {
        let index = try corpus()
        #expect(titles(try index.search(.phrase("body", ["the", "sea"]))) == ["The Old Man"])
        #expect(try index.search(.phrase("body", ["sea", "the"])).isEmpty)
    }

    @Test func fuzzyTerm() throws {
        // "dik" is edit-distance 1 from the indexed token "dick".
        let hits = try corpus().search(.fuzzy("title", "dik", distance: 1))
        #expect(titles(hits) == ["Moby Dick"])
    }

    @Test func prefixMatchesIndexedToken() throws {
        // default tokenizer lowercases; "mob" is the prefix of "moby".
        #expect(titles(try corpus().search(.prefix("title", "mob"))) == ["Moby Dick"])
    }

    @Test func prefixIsExactNotTypoTolerant() throws {
        // "mob" -> "moby" but "moc" should not (edit-distance 1, zero allowed).
        #expect(try corpus().search(.prefix("title", "moc")).isEmpty)
    }

    @Test func autocompleteToleratesTypos() throws {
        // "mopy" is one edit (p->b) from the "moby" prefix of "Moby Dick".
        #expect(titles(try corpus().search(.autocomplete("title", "mopy"))) == ["Moby Dick"])
        // typoTolerance: 0 collapses to an exact prefix, so the typo no longer matches.
        #expect(try corpus().search(.autocomplete("title", "mopy", typoTolerance: 0)).isEmpty)
    }

    @Test func regexMatchesIndexedToken() throws {
        // pattern is anchored to the whole token: "m.*" matches "moby"/"man"/"mice"/"me".
        #expect(titles(try corpus().search(.regex("title", "mob.*"))) == ["Moby Dick"])
    }

    @Test func invalidRegexThrows() throws {
        #expect(throws: TantivyError.self) {
            try corpus().search(.regex("title", "[unterminated"))
        }
    }

    @Test func dateRange() throws {
        let q = Query.dateRange("created",
                                from: date("1900-01-01T00:00:00Z"),
                                to: date("2000-01-01T00:00:00Z"))
        #expect(titles(try corpus().search(q)) == ["The Old Man", "Of Mice and Men"])
    }

    @Test func exclusiveRangeBound() throws {
        // [1851, 1952) excludes 1952.
        let hits = try corpus().search(.range("year", 1851..<1952))
        #expect(titles(hits) == ["Of Mice and Men", "Moby Dick"])
    }

    @Test func typedStructuredSearch() throws {
        struct Doc: Codable, Equatable { let title: String; let year: UInt64 }
        let got = try corpus().search(.term("tag", "classic"), as: Doc.self)
        #expect(got == [Doc(title: "Moby Dick", year: 1851)])
    }

    @Test func unknownFieldThrows() throws {
        #expect(throws: TantivyError.self) {
            try corpus().search(.term("ghost", "x"))
        }
    }
}
