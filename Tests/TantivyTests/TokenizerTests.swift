import Testing
@testable import Tantivy

/// Coverage for the built-in tokenizers selectable per field.
struct TokenizerTests {

    private func singleDoc(fieldType: (SchemaBuilder, String) -> SchemaBuilder,
                           value: Any, field: String = "f") throws -> Index {
        var b = SchemaBuilder()
        b = fieldType(b, field)
        let index = try Index.inMemory(schema: b.build())
        let w = try index.writer()
        try w.addDocument([field: value])
        try w.commitAndReload()
        return index
    }

    @Test func defaultTokenizerLowercasesAndSplits() throws {
        let index = try singleDoc(
            fieldType: { $0.addTextField($1, stored: true, tokenizer: .default) },
            value: "Hello, WORLD-Wide Web")
        // Case-insensitive: query is lowercased with the same tokenizer.
        #expect(try index.search("hello").count == 1)
        #expect(try index.search("WORLD").count == 1)  // query also lowercased
        #expect(try index.search("world").count == 1)
        #expect(try index.search("web").count == 1)
        #expect(try index.search("missing").count == 0)
    }

    @Test func englishStemmer() throws {
        let index = try singleDoc(
            fieldType: { $0.addTextField($1, stored: true, tokenizer: .english) },
            value: "the cats were jumping over running dogs")
        // Stemmed at index AND query time, so inflections all collapse.
        #expect(try index.search("cat").count == 1)   // cats -> cat
        #expect(try index.search("jump").count == 1)  // jumping -> jump
        #expect(try index.search("jumps").count == 1) // jumps -> jump
        #expect(try index.search("run").count == 1)   // running -> run
        #expect(try index.search("dog").count == 1)   // dogs -> dog
    }

    @Test func stemmerDistinctFromDefault() throws {
        // The same text under the default tokenizer does NOT stem.
        let index = try singleDoc(
            fieldType: { $0.addTextField($1, stored: true, tokenizer: .default) },
            value: "running dogs")
        #expect(try index.search("running").count == 1)
        #expect(try index.search("run").count == 0)  // no stemming
    }

    @Test func rawStringFieldIsExactAndCaseSensitive() throws {
        let index = try singleDoc(
            fieldType: { $0.addStringField($1, stored: true) },
            value: "Swift")
        #expect(try index.search("f:Swift").count == 1)  // exact
        #expect(try index.search("f:swift").count == 0)  // case-sensitive
        #expect(try index.search("f:Swif").count == 0)   // no prefix match
    }

    @Test func rawStringFieldKeepsWholeValueAsOneToken() throws {
        let index = try singleDoc(
            fieldType: { $0.addStringField($1, stored: true) },
            value: "New York")
        #expect(try index.search("f:\"New York\"").count == 1)  // whole token
        #expect(try index.search("f:York").count == 0)          // not split on space
    }
}
