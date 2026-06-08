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
        #expect(Analyzer.tag.rawValue == "tag")
        #expect(Analyzer.allCases.count == 5)
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
