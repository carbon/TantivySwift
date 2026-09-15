import Testing
@testable import Tantivy

/// Phrase queries against a field on `en_stem_keep`, where a word whose stem
/// differs occupies one position with two terms (`designers` + `design`).
struct KeepStemPhraseTests {

    private let index: Index

    init() throws {
        let schema = SchemaBuilder()
            .addTextField("f", stored: true, tokenizer: .englishKeepingSurface)
            .build()
        index = try Index.inMemory(schema: schema)
        let w = try index.writer()
        for title in ["graphic designers wanted",
                      "graphic designer",
                      "running shoes for designers",
                      "poster designers"] {
            try w.addDocument(["f": title])
        }
        try w.commitAndReload()
    }

    private func matches(_ query: Query) throws -> Set<String> {
        Set(try index.search(query, limit: 10).compactMap { $0.string("f") })
    }

    private func phrase(_ terms: String..., slop: UInt32 = 0) throws -> Set<String> {
        try matches(.phrase("f", terms, slop: slop))
    }

    // MARK: - Surface and stem at one position

    /// The surface form is kept, so an exact phrase still tells singular from
    /// plural — what a stem-only field cannot do.
    @Test func surfacePhraseIsExact() throws {
        #expect(try phrase("graphic", "designers") == ["graphic designers wanted"])
        #expect(try phrase("graphic", "designer") == ["graphic designer"])
    }

    @Test func stemPhraseMatchesEveryInflection() throws {
        #expect(try phrase("graphic", "design") == ["graphic designers wanted", "graphic designer"])
    }

    /// Either term at a position satisfies it, independently per position.
    @Test func surfaceAndStemMixFreelyAcrossPositions() throws {
        let doc: Set = ["running shoes for designers"]
        #expect(try phrase("running", "shoes") == doc)
        #expect(try phrase("run", "shoe") == doc)
        #expect(try phrase("running", "shoe") == doc)
        #expect(try phrase("run", "shoes") == doc)
    }

    /// A word that stems to itself has one term, and phrases through it work
    /// with either form of its neighbour.
    @Test func unchangedWordInPhrase() throws {
        #expect(try phrase("poster", "designers") == ["poster designers"])
        #expect(try phrase("poster", "design") == ["poster designers"])
    }

    // MARK: - Positions are not inflated

    /// A phrase across the doubled position reaches the word after it — which
    /// fails if the added stem had pushed later positions along.
    @Test func phraseSpansDoubledPosition() throws {
        let doc: Set = ["graphic designers wanted"]
        #expect(try phrase("graphic", "design", "wanted") == doc)
        #expect(try phrase("graphic", "designers", "want") == doc)
        #expect(try phrase("design", "wanted") == doc)
    }

    /// Surface and stem share a position, so they are not adjacent to each other.
    @Test func sameColumnTermsAreNotAdjacent() throws {
        #expect(try phrase("designers", "design").isEmpty)
        #expect(try phrase("design", "designers").isEmpty)
    }

    @Test func slopCountsWordsNotTerms() throws {
        #expect(try phrase("graphic", "wanted").isEmpty)
        #expect(try phrase("graphic", "wanted", slop: 1) == ["graphic designers wanted"])
    }

    @Test func phraseOrderStillMatters() throws {
        #expect(try phrase("designers", "graphic").isEmpty)
        #expect(try phrase("design", "graphic").isEmpty)
    }

    // MARK: - Phrase prefix

    @Test func phrasePrefixExpandsOverSurfaceAndStem() throws {
        #expect(try matches(.phrasePrefix("f", ["graphic", "desig"]))
                == ["graphic designers wanted", "graphic designer"])
        #expect(try matches(.phrasePrefix("f", ["graphic", "designers"]))
                == ["graphic designers wanted"])
        #expect(try matches(.phrasePrefix("f", ["run", "sh"])) == ["running shoes for designers"])
    }

    // MARK: - Building phrases with `analyze`

    /// The intended query path: analyze the query text with `.english` for a
    /// stemmed phrase, or `.default` for an exact one, and pass the terms on.
    @Test func phrasesBuiltFromAnalyze() throws {
        let stemmed = try index.analyze("Graphic Designers", with: .english).map(\.text)
        #expect(try matches(.phrase("f", stemmed)) == ["graphic designers wanted", "graphic designer"])

        let exact = try index.analyze("Graphic Designers", with: .default).map(\.text)
        #expect(try matches(.phrase("f", exact)) == ["graphic designers wanted"])
    }

    /// The pitfall: `en_stem_keep`'s own tokens are not a phrase. `.phrase`
    /// gives each term its own position, so `designers` and `design` land one
    /// apart and nothing matches.
    @Test func keepingTokensPassedStraightToPhraseMatchNothing() throws {
        let tokens = try index.analyze("graphic designers", with: .englishKeepingSurface)
        #expect(tokens.map(\.text) == ["graphic", "designers", "design"])
        #expect(try matches(.phrase("f", tokens.map(\.text))).isEmpty)
    }

    /// The fix for the pitfall above: group the tokens by position, so
    /// `designers | design` is one position that either term satisfies.
    @Test func keepingTokensAsMultiPhraseMatchEveryInflection() throws {
        let tokens = try index.analyze("graphic designers", with: .englishKeepingSurface)
        #expect(try matches(.multiPhrase("f", tokens: tokens))
                == ["graphic designers wanted", "graphic designer"])
        #expect(try matches(.multiPhrase("f", [["graphic"], ["designers", "design"]]))
                == ["graphic designers wanted", "graphic designer"])
    }

    // MARK: - Through the query parser (not recommended; pinned)

    /// The parser keeps same-position tokens at one offset and requires all of
    /// them, so a parsed query is an exact-surface match: the stemming the
    /// field was chosen for is lost. Pinned so it is not rediscovered.
    @Test func parsedQueriesLoseStemming() throws {
        // `designers` → designers@0 + design@0, both required: "graphic designer" is out.
        #expect(Set(try index.search("f:designers").compactMap { $0.string("f") })
                == ["graphic designers wanted", "running shoes for designers", "poster designers"])
    }

    @Test func parsedPhraseBehaviour() throws {
        #expect(try index.search("f:\"graphic designers\"").compactMap { $0.string("f") }
                == ["graphic designers wanted"])
        #expect(Set(try index.search("f:\"graphic design\"").compactMap { $0.string("f") })
                == ["graphic designers wanted", "graphic designer"])
    }
}
