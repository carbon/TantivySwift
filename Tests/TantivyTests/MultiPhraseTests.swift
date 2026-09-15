import Testing
@testable import Tantivy

/// `Query.multiPhrase` — phrases with alternatives at a position.
struct MultiPhraseTests {

    private let index: Index

    init() throws {
        let schema = SchemaBuilder()
            .addTextField("f", stored: true)
            .addU64Field("n")
            .build()
        index = try Index.inMemory(schema: schema)
        let w = try index.writer()
        for title in ["graphic designer wanted",
                      "graphic illustrator",
                      "graphic novel",
                      "designer graphic"] {
            try w.addDocument(["f": title])
        }
        try w.commitAndReload()
    }

    private func matches(_ query: Query, in index: Index? = nil) throws -> Set<String> {
        Set(try (index ?? self.index).search(query, limit: 10).compactMap { $0.string("f") })
    }

    private func score(_ query: Query, of title: String) throws -> Float {
        try #require(index.search(query, limit: 10).first { $0.string("f") == title }).score
    }

    // MARK: - Matching

    /// Any one alternative satisfies a position — the difference from a phrase
    /// with several terms at one offset, which requires all of them.
    @Test func anyAlternativeSatisfiesAPosition() throws {
        #expect(try matches(.multiPhrase("f", [["graphic"], ["designer", "illustrator"]]))
                == ["graphic designer wanted", "graphic illustrator"])
    }

    @Test func alternativesAtEveryPosition() throws {
        #expect(try matches(.multiPhrase("f", [["graphic", "comic"], ["novel", "illustrator"]]))
                == ["graphic illustrator", "graphic novel"])
    }

    @Test func orderAndAdjacencyStillApply() throws {
        #expect(try matches(.multiPhrase("f", [["designer", "illustrator"], ["graphic"]]))
                == ["designer graphic"])
        #expect(try matches(.multiPhrase("f", [["graphic"], ["wanted", "novel"]]))
                == ["graphic novel"])
    }

    @Test func slop() throws {
        #expect(try matches(.multiPhrase("f", [["graphic"], ["wanted", "novel"]], slop: 1))
                == ["graphic designer wanted", "graphic novel"])
    }

    @Test func offsetGapsAreKept() throws {
        let q = Query.multiPhrase(field: "f", positions: [
            PhrasePosition(offset: 0, terms: ["graphic"]),
            PhrasePosition(offset: 2, terms: ["wanted"]),
        ], slop: 0)
        #expect(try matches(q) == ["graphic designer wanted"])
    }

    /// Entries at one offset are merged into alternatives, not required together.
    @Test func positionsSharingAnOffsetMerge() throws {
        let q = Query.multiPhrase(field: "f", positions: [
            PhrasePosition(offset: 0, terms: ["graphic"]),
            PhrasePosition(offset: 1, terms: ["designer"]),
            PhrasePosition(offset: 1, terms: ["illustrator"]),
        ], slop: 0)
        #expect(try matches(q) == ["graphic designer wanted", "graphic illustrator"])
    }

    @Test func absentAlternativesAreHarmless() throws {
        #expect(try matches(.multiPhrase("f", [["graphic"], ["designer", "zzz"]]))
                == ["graphic designer wanted"])
        #expect(try matches(.multiPhrase("f", [["graphic"], ["zzz", "yyy"]])).isEmpty)
    }

    @Test func singlePositionIsATermDisjunction() throws {
        #expect(try matches(.multiPhrase("f", [["illustrator", "novel"]]))
                == ["graphic illustrator", "graphic novel"])
    }

    @Test func countMatchesSearch() throws {
        #expect(try index.count(.multiPhrase("f", [["graphic"], ["designer", "illustrator"]])) == 2)
    }

    /// Alternatives become literal alternations of a regex internally; regex
    /// syntax in a term must not leak through.
    @Test func regexMetacharactersInTermsAreLiteral() throws {
        let schema = SchemaBuilder().addTextField("f", stored: true, tokenizer: .whitespace).build()
        let index = try Index.inMemory(schema: schema)
        let w = try index.writer()
        for title in ["love c++ code", "love cxx code", "a well-known fact"] {
            try w.addDocument(["f": title])
        }
        try w.commitAndReload()

        #expect(try matches(.multiPhrase("f", [["love"], ["c++"]]), in: index) == ["love c++ code"])
        #expect(try matches(.multiPhrase("f", [["love"], ["c.."]]), in: index).isEmpty)
        #expect(try matches(.multiPhrase("f", [["love"], ["c++", "cxx"]]), in: index)
                == ["love c++ code", "love cxx code"])
        #expect(try matches(.multiPhrase("f", [["a"], ["well-known"]]), in: index) == ["a well-known fact"])
        #expect(try matches(.multiPhrase("f", [["love"], ["c|cxx"]]), in: index).isEmpty)
    }

    // MARK: - Tokens

    @Test func tokensSharingAPositionBecomeAlternatives() throws {
        let tokens = [
            Token(text: "graphic", position: 0, offsetFrom: 0, offsetTo: 7),
            Token(text: "designer", position: 1, offsetFrom: 8, offsetTo: 16),
            Token(text: "illustrator", position: 1, offsetFrom: 8, offsetTo: 16),
        ]
        #expect(try matches(.multiPhrase("f", tokens: tokens))
                == ["graphic designer wanted", "graphic illustrator"])
    }

    /// The public path: analyze, then add a synonym at an existing position.
    @Test func handBuiltSynonymTokenJoinsAnalyzedStream() throws {
        var tokens = try index.analyze("graphic designer", with: .default)
        tokens.append(Token(text: "illustrator", position: 1))
        #expect(try matches(.multiPhrase("f", tokens: tokens))
                == ["graphic designer wanted", "graphic illustrator"])
    }

    @Test func tokenPositionGapsAreKept() throws {
        let tokens = [
            Token(text: "graphic", position: 0, offsetFrom: 0, offsetTo: 7),
            Token(text: "wanted", position: 2, offsetFrom: 17, offsetTo: 23),
        ]
        #expect(try matches(.multiPhrase("f", tokens: tokens)) == ["graphic designer wanted"])
    }

    // MARK: - Scoring

    /// One alternative per position is exactly a phrase, and scores as one.
    @Test func singleAlternativesScoreLikePhrase() throws {
        let phrase = try score(.phrase("f", ["graphic", "designer"]), of: "graphic designer wanted")
        let multi = try score(.multiPhrase("f", [["graphic"], ["designer"]]), of: "graphic designer wanted")
        #expect(abs(phrase - multi) < 1e-4)
    }

    /// A position weighs as its most frequent alternative: `designer` (2 docs)
    /// over `illustrator` (1), so the score equals the `designer` phrase's.
    @Test func positionWeighsAsItsMostFrequentAlternative() throws {
        let phrase = try score(.phrase("f", ["graphic", "designer"]), of: "graphic designer wanted")
        let multi = try score(.multiPhrase("f", [["graphic"], ["designer", "illustrator"]]),
                              of: "graphic designer wanted")
        #expect(abs(phrase - multi) < 1e-4)
    }

    @Test func addingAnAbsentSynonymDoesNotChangeTheScore() throws {
        let without = try score(.multiPhrase("f", [["graphic"], ["designer"]]), of: "graphic designer wanted")
        let with = try score(.multiPhrase("f", [["graphic"], ["designer", "zzz"]]), of: "graphic designer wanted")
        #expect(abs(without - with) < 1e-4)
    }

    /// Single position: the best alternative's term score, not their sum.
    @Test func singlePositionScoresAsBestTerm() throws {
        let term = try score(.term("f", "illustrator"), of: "graphic illustrator")
        let multi = try score(.multiPhrase("f", [["illustrator", "designer"]]), of: "graphic illustrator")
        #expect(abs(term - multi) < 1e-4)
    }

    // MARK: - Boosting

    /// Surface and stem at one position (`en_stem_keep`), where a document can
    /// hold several alternatives at once.
    private func keepStemIndex() throws -> Index {
        let schema = SchemaBuilder()
            .addTextField("f", stored: true, tokenizer: .englishKeepingSurface)
            .build()
        let index = try Index.inMemory(schema: schema)
        let w = try index.writer()
        for title in ["graphic designers", "graphic designer", "designers"] {
            try w.addDocument(["f": title])
        }
        try w.commitAndReload()
        return index
    }

    private func scores(_ query: Query, in index: Index) throws -> [String: Float] {
        var out: [String: Float] = [:]
        for hit in try index.search(query, limit: 10) {
            if let title = hit.string("f") { out[title] = hit.score }
        }
        return out
    }

    /// Regression: tantivy's top-docs path for a top-level term disjunction
    /// summed the alternatives. A document holding both `designers` and
    /// `design` must score as `designers` alone, the better of the two.
    @Test func singlePositionTakesTheBestAlternativeWhenADocumentHasSeveral() throws {
        let index = try keepStemIndex()
        let term = try scores(.term("f", "designers"), in: index)
        let multi = try scores(.multiPhrase("f", [["designers", "design"]]), in: index)
        for title in ["graphic designers", "designers"] {
            let expected = try #require(term[title])
            let actual = try #require(multi[title])
            #expect(abs(expected - actual) < 1e-4, "\(title): \(actual) ≠ best term \(expected)")
        }
    }

    @Test func boostScalesEveryScore() throws {
        let index = try keepStemIndex()
        for query in [Query.multiPhrase("f", [["graphic"], ["designers", "design"]]),
                      Query.multiPhrase("f", [["designers", "design"]])] {
            let plain = try scores(query, in: index)
            let boosted = try scores(query.boosted(by: 3), in: index)
            #expect(Set(plain.keys) == Set(boosted.keys))
            for (title, score) in plain {
                let b = try #require(boosted[title])
                #expect(abs(b - 3 * score) < 1e-4, "\(title): \(b) ≠ 3 × \(score)")
            }
        }
    }

    /// Alternatives inside one position all score alike; to prefer the exact
    /// surface form, add the exact phrase as a boosted optional clause.
    @Test func preferTheExactFormByCombiningWithABoostedPhrase() throws {
        let index = try keepStemIndex()
        let any = Query.multiPhrase("f", [["graphic"], ["designers", "design"]])
        #expect(try scores(any, in: index)["graphic designers"] == scores(any, in: index)["graphic designer"])

        let preferExact: Query = any || Query.phrase("f", ["graphic", "designers"]).boosted(by: 2)
        let hits = try index.search(preferExact).compactMap { $0.string("f") }
        #expect(hits == ["graphic designers", "graphic designer"])
    }

    // MARK: - Highlighting

    @Test func snippetsHighlightTheMatchedAlternative() throws {
        let hits = try index.search(.multiPhrase("f", [["graphic"], ["designer", "illustrator"]]),
                                    highlight: ["f"])
        let hit = try #require(hits.first { $0.string("f") == "graphic illustrator" })
        #expect(hit.snippet("f")?.contains("<b>illustrator</b>") == true)
    }

    // MARK: - Errors

    @Test func rejectsEmptyPositionsAndNonTextFields() throws {
        #expect(throws: TantivyError.self) {
            try index.search(.multiPhrase(field: "f", positions: [], slop: 0))
        }
        #expect(throws: TantivyError.self) { try index.search(.multiPhrase("f", [["graphic"], []])) }
        #expect(throws: TantivyError.self) {
            try index.search(.multiPhrase(field: "f", positions: [PhrasePosition(offset: -1, terms: ["a"])], slop: 0))
        }
        #expect(throws: TantivyError.self) { try index.search(.multiPhrase("n", [["1"], ["2"]])) }
    }
}
