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

    // MARK: - Cross-API (count / delete / collection)

    @Test func wildcardAndExistsViaCount() throws {
        let wild = try wildcardCorpus()
        #expect(try wild.count(.wildcard("title", "re*")) == 2)
        #expect(try wild.count(.wildcard("code", "AB-*")) == 2)

        let ex = try existsCorpus()
        #expect(try ex.count(.exists("score")) == 2)
    }

    /// MoreLikeThis needs scoring enabled, which `count` and `delete` do not
    /// provide — tantivy rejects it. Pin that limitation so a regression (or a
    /// future tantivy that lifts it) is noticed; MLT is a `search`-only query.
    @Test func moreLikeThisRequiresScoringSoCountAndDeleteThrow() throws {
        let index = try articlesIndex()
        let q = Query.moreLikeThis("body", "quick brown fox", options: looseMLT)
        #expect(throws: TantivyError.self) { _ = try index.count(q) }
        #expect(throws: TantivyError.self) { try index.delete(matching: q) }
        #expect(try !index.search(q).isEmpty)   // but search works
    }

    @Test func deleteByWildcard() throws {
        let index = try wildcardCorpus()
        try index.delete(matching: .wildcard("code", "AB-*"))   // removes the two AB- codes
        #expect(index.documentCount == 1)
        #expect(try index.search(.matchAll).first?.string("code") == "XY-300")
    }

    @Test func deleteByExists() throws {
        let index = try existsCorpus()
        try index.delete(matching: .exists("score"))   // remove docs that have a score
        #expect(index.documentCount == 1)
        #expect(try index.search(.matchAll).first?.string("id") == "b")
    }

    @Test func newQueriesThroughSearchCollection() throws {
        struct Doc: Codable { let title: String; let n: Int64 }
        let c = try SearchCollection<Doc> { s in
            s.addTextField("title", stored: true)
            s.addI64Field("n", stored: true, indexed: true, fast: true)
        }
        try c.add(contentsOf: [Doc(title: "north star", n: 1),
                               Doc(title: "northern lights", n: 2),
                               Doc(title: "south pole", n: 3)])
        #expect(try c.search(.wildcard("title", "north*")).count == 2)
        #expect(try c.count(matching: .exists("n")) == 3)
        #expect(try !c.search(.moreLikeThis("title", "northern lights", options: looseMLT)).isEmpty)
    }

    // MARK: - Error paths

    @Test func unknownFieldThrows() throws {
        let wild = try wildcardCorpus()
        #expect(throws: TantivyError.self) { _ = try wild.search(.wildcard("nope", "a*")) }

        let ex = try existsCorpus()
        #expect(throws: TantivyError.self) { _ = try ex.search(.exists("nope")) }

        let arts = try articlesIndex()
        #expect(throws: TantivyError.self) {
            _ = try arts.search(.moreLikeThis("nope", "fox", options: looseMLT))
        }
    }

    @Test func moreLikeThisWithNoFieldsThrows() throws {
        let index = try articlesIndex()
        #expect(throws: TantivyError.self) {
            _ = try index.search(.moreLikeThis([:], options: looseMLT))
        }
    }

    // MARK: - More-like-this tuning knobs

    @Test func maxQueryTermsNarrowsResults() throws {
        let index = try articlesIndex()
        let source = "quick brown fox lazy dog"
        let wide = try index.search(.moreLikeThis("body", source, options: looseMLT), limit: 10)
        var narrowOpts = looseMLT
        narrowOpts.maxQueryTerms = 1
        let narrow = try index.search(.moreLikeThis("body", source, options: narrowOpts), limit: 10)
        #expect(narrow.count <= wide.count)
    }

    @Test func stopWordsExcludeTerms() throws {
        let index = try articlesIndex()
        // Stop the only shared distinctive terms → no fox/dog neighbours surface.
        let opts = MoreLikeThisOptions(minDocFrequency: 1, minTermFrequency: 1,
                                       stopWords: ["quick", "brown", "fox"])
        let hits = try index.search(.moreLikeThis("body", "quick brown fox", options: opts))
        #expect(!titles(hits).contains("Fox Racing"))
    }

    /// `minWordLength` drops short source words, so raising it past every
    /// distinctive term leaves nothing to match on.
    @Test func minWordLengthFiltersShortTerms() throws {
        let index = try articlesIndex()
        var opts = looseMLT
        opts.minWordLength = 4                              // "fox" and "dog" are 3
        let hits = try index.search(.moreLikeThis("body", "fox dog", options: opts))
        #expect(hits.isEmpty)
        opts.minWordLength = 3                              // now both qualify
        #expect(!(try index.search(.moreLikeThis("body", "fox dog", options: opts))).isEmpty)
    }

    /// `maxWordLength` is the mirror image: it drops long source words.
    @Test func maxWordLengthFiltersLongTerms() throws {
        let index = try articlesIndex()
        var opts = looseMLT
        opts.maxWordLength = 2                              // shorter than every term
        #expect(try index.search(.moreLikeThis("body", "rockets orbits", options: opts)).isEmpty)
        opts.maxWordLength = 20
        #expect(try index.search(.moreLikeThis("body", "rockets orbits", options: opts))
                    .contains { $0.string("title") == "Rocketry" })
    }

    /// `maxDocFrequency` ignores source terms that are too common to be
    /// characteristic — at 1, a term appearing in two documents is skipped.
    @Test func maxDocFrequencyIgnoresCommonTerms() throws {
        let index = try articlesIndex()
        var opts = looseMLT
        opts.maxDocFrequency = 1                            // "fox" is in two docs
        #expect(try index.search(.moreLikeThis("body", "fox", options: opts)).isEmpty)
        opts.maxDocFrequency = 10
        #expect(!(try index.search(.moreLikeThis("body", "fox", options: opts))).isEmpty)
    }
}
