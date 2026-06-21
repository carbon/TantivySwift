import Foundation
import Testing
@testable import Tantivy

/// Coverage for the wildcard, exists, and more-like-this structured queries.
struct WildcardExistsMLTTests {

    private func titles(_ hits: [SearchHit]) -> Set<String> {
        Set(hits.compactMap { $0.string("title") })
    }

    // MARK: - Wildcard

    /// title (default-tokenized, stored), code (raw string, stored).
    private func wildcardCorpus() throws -> Index {
        let schema = SchemaBuilder()
            .addTextField("title", stored: true)
            .addStringField("code", stored: true)
            .build()
        let index = try Index.inMemory(schema: schema)
        try index.add(contentsOf: [
            ["title": "red fox", "code": "AB-100"],
            ["title": "blue whale", "code": "AB-200"],
            ["title": "red crab", "code": "XY-300"],
        ])
        return index
    }

    @Test func wildcardStarMatchesTokenPrefix() throws {
        let index = try wildcardCorpus()
        // "re*" matches the lowercased token "red" in two titles.
        #expect(try titles(index.search(.wildcard("title", "re*"))) == ["red fox", "red crab"])
    }

    @Test func wildcardStarMatchesTokenSuffixAndMiddle() throws {
        let index = try wildcardCorpus()
        #expect(try titles(index.search(.wildcard("title", "*ale"))) == ["blue whale"])
        #expect(try titles(index.search(.wildcard("title", "w*le"))) == ["blue whale"])
    }

    @Test func wildcardOnRawFieldMatchesWholeValue() throws {
        let index = try wildcardCorpus()
        // A raw `string` field is one token, so the pattern spans the whole value.
        #expect(try index.search(.wildcard("code", "AB-*")).count == 2)
        #expect(try index.search(.wildcard("code", "*-300")).count == 1)
    }

    @Test func wildcardLiteralCharsAreEscaped() throws {
        let index = try wildcardCorpus()
        // The '-' is literal, not a regex metacharacter.
        #expect(try index.search(.wildcard("code", "XY-300")).count == 1)
        #expect(try index.search(.wildcard("code", "XY-3*")).count == 1)
    }

    // MARK: - Exists

    /// id (raw, stored), score (i64, stored + fast, optional per-doc).
    private func existsCorpus() throws -> Index {
        let schema = SchemaBuilder()
            .addStringField("id", stored: true)
            .addI64Field("score", stored: true, indexed: true, fast: true)
            .build()
        let index = try Index.inMemory(schema: schema)
        try index.add(contentsOf: [
            ["id": "a", "score": 10],
            ["id": "b"],                 // no score
            ["id": "c", "score": 30],
        ])
        return index
    }

    @Test func existsMatchesDocsWithAValue() throws {
        let index = try existsCorpus()
        #expect(try index.count(.exists("score")) == 2)
    }

    @Test func existsNegationFindsMissing() throws {
        let index = try existsCorpus()
        // Documents missing `score`: all-docs excluding those where it exists.
        let missing = try index.search(Query.matchAll.excluding(.exists("score")))
        #expect(missing.count == 1)
        #expect(missing.first?.string("id") == "b")
    }

    @Test func existsOnNonFastFieldThrows() throws {
        let index = try existsCorpus()   // `id` is a string field, not fast
        #expect(throws: TantivyError.self) {
            _ = try index.search(.exists("id"))
        }
    }

    // MARK: - More-like-this

    /// title (stored), body (default-tokenized, stored), slug (raw, stored).
    private func articlesIndex() throws -> Index {
        let schema = SchemaBuilder()
            .addTextField("title", stored: true)
            .addTextField("body", stored: true)
            .addStringField("slug", stored: true)
            .build()
        let index = try Index.inMemory(schema: schema)
        try index.add(contentsOf: [
            ["title": "Foxes", "slug": "foxes",
             "body": "the quick brown fox jumps over the lazy dog"],
            ["title": "Fox Racing", "slug": "fox-racing",
             "body": "a quick brown fox runs very fast"],
            ["title": "Sleepy Dogs", "slug": "dogs",
             "body": "the lazy dog sleeps all day long"],
            ["title": "Rocketry", "slug": "rockets",
             "body": "completely unrelated text about space rockets and orbits"],
        ])
        return index
    }

    // Small corpus: relax the frequency floors so single occurrences count.
    private let looseMLT = MoreLikeThisOptions(minDocFrequency: 1, minTermFrequency: 1)

    @Test func moreLikeThisFindsSimilarText() throws {
        let index = try articlesIndex()
        let hits = try index.search(
            .moreLikeThis("body", "quick brown fox", options: looseMLT), limit: 10)
        let found = titles(hits)
        #expect(found.contains("Foxes"))
        #expect(found.contains("Fox Racing"))
        #expect(!found.contains("Rocketry"))   // shares no characteristic terms
    }

    @Test func moreLikeThisDefaultsCanMatchNothingOnTinyCorpus() throws {
        let index = try articlesIndex()
        // Defaults (minDocFrequency 5) filter out every term on a 4-doc index.
        #expect(try index.search(.moreLikeThis("body", "quick brown fox")).isEmpty)
    }

    @Test func moreLikeThisByDocumentIdExcludesSource() throws {
        let index = try articlesIndex()
        let related = try index.moreLikeThis(
            idField: "slug", id: "foxes", fields: ["body"], options: looseMLT, limit: 10)
        let found = titles(related)
        #expect(!found.contains("Foxes"))       // source excluded
        #expect(found.contains("Fox Racing"))   // shares "quick brown fox"
    }

    @Test func moreLikeThisByMissingIdReturnsEmpty() throws {
        let index = try articlesIndex()
        let related = try index.moreLikeThis(
            idField: "slug", id: "does-not-exist", fields: ["body"], options: looseMLT)
        #expect(related.isEmpty)
    }

    @Test func moreLikeThisMultipleFields() throws {
        let index = try articlesIndex()
        let q = Query.moreLikeThis(["title": ["Fox"], "body": ["quick brown fox"]],
                                   options: looseMLT)
        #expect(try !index.search(q).isEmpty)
    }

    @Test func nonFiniteMoreLikeThisBoostThrows() throws {
        let index = try articlesIndex()
        var opts = looseMLT
        opts.boostFactor = .infinity
        #expect(throws: TantivyError.self) {
            _ = try index.search(.moreLikeThis("body", "fox", options: opts))
        }
    }
}
