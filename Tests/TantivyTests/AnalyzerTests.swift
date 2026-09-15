import Testing
@testable import Tantivy

/// Drift guard: keeps the typed `Analyzer` enum in lock-step with the analyzers
/// the native (tantivy + this library) layer actually registers.
struct AnalyzerRegistrationTests {

    @Test func rawValuesMatchNativeNames() {
        #expect(Analyzer.default.rawValue == "default")
        #expect(Analyzer.raw.rawValue == "raw")
        #expect(Analyzer.whitespace.rawValue == "whitespace")
        #expect(Analyzer.english.rawValue == "en_stem")
        #expect(Analyzer.lowercase.rawValue == "lowercase")
        #expect(Analyzer.englishKeepingSurface.rawValue == "en_stem_keep")
        #expect(Analyzer.allCases.count == 6)
    }

    /// Every enum case must name an analyzer the native layer registers — building
    /// a field with it and indexing a document would throw otherwise.
    @Test func everyAnalyzerIsRegisteredAndUsable() throws {
        for analyzer in Analyzer.allCases {
            let schema = SchemaBuilder()
                .addTextField("f", stored: true, tokenizer: analyzer)
                .build()
            let index = try Index.inMemory(schema: schema)
            try index.add(["f": "hello"])   // throws at commit if not registered
            #expect(index.documentCount == 1, "analyzer '\(analyzer.rawValue)' failed to index")
            #expect(try index.search("f:hello").count == 1,
                    "analyzer '\(analyzer.rawValue)' failed to match a lowercase token")
        }
    }
}

/// `Index.analyze` — running a field's analyzer without opening a query.
struct AnalyzeTests {

    private func index() throws -> Index {
        try Index.inMemory(schema: SchemaBuilder().addTextField("f").build())
    }

    @Test func englishStemsEachWord() throws {
        let tokens = try index().analyze("Designer chairs", with: .english)
        #expect(tokens.map(\.text) == ["design", "chair"])
        #expect(tokens.map(\.position) == [0, 1])
        #expect(tokens.map(\.offsetFrom) == [0, 9])
        #expect(tokens.map(\.offsetTo) == [8, 15])
    }

    /// Pins the split the host's `analyzedTerms` imitates today.
    @Test func defaultSplitsOnPunctuation() throws {
        let tokens = try index().analyze("nytimes.com", with: .default)
        #expect(tokens.map(\.text) == ["nytimes", "com"])
    }

    /// `lowercase` is registered by this library, not tantivy — proves the
    /// index's own tokenizer manager is the one consulted.
    @Test func registeredAnalyzerResolves() throws {
        let tokens = try index().analyze("Ann Handley", with: .lowercase)
        #expect(tokens.map(\.text) == ["ann handley"])
    }

    @Test func unknownTokenizerThrows() throws {
        let index = try index()
        let error = #expect(throws: TantivyError.self) {
            try index.analyze("hello", tokenizer: "nope")
        }
        guard case .ffi(let message) = error else {
            Issue.record("expected an ffi error, got \(String(describing: error))")
            return
        }
        #expect(message == "tokenizer \"nope\" not found")
    }

    @Test func emptyTextHasNoTokens() throws {
        #expect(try index().analyze("", with: .english).isEmpty)
    }

    @Test func interiorNULIsRejected() throws {
        let index = try index()
        #expect(throws: TantivyError.self) { try index.analyze("a\0b", with: .default) }
    }
}
