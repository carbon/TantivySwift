import Foundation
import Testing
@testable import Tantivy

/// Coverage for snippets/highlighting, the typed `Document` builder, and the
/// `TantivyError` helpers.
struct FeatureExtrasTests {

    // MARK: - Snippets / highlighting

    private func proseIndex() throws -> Index {
        let schema = SchemaBuilder()
            .addTextField("title", stored: true)
            .addTextField("body", stored: true)   // must be stored to snippet
            .build()
        let index = try Index.inMemory(schema: schema)
        try index.add(["title": "Doc", "body": "the quick brown fox jumps over the lazy dog"])
        return index
    }

    @Test func snippetsHighlightMatchesStringQuery() throws {
        let index = try proseIndex()
        let hit = try #require(try index.search("fox", highlight: ["body"]).first)
        let snippet = try #require(hit.snippet("body"))
        #expect(snippet.contains("<b>fox</b>"))
    }

    @Test func snippetsHighlightMatchesStructuredQuery() throws {
        let index = try proseIndex()
        let hit = try #require(try index.search(.term("body", "fox"), highlight: ["body"]).first)
        #expect(hit.snippet("body")?.contains("<b>fox</b>") == true)
    }

    @Test func noSnippetsUnlessRequested() throws {
        let index = try proseIndex()
        let hit = try #require(try index.search("fox").first)
        #expect(hit.snippets.isEmpty)
        #expect(hit.snippet("body") == nil)
    }

    // MARK: - Document builder

    @Test func documentBuilderRoundTripsDatesAndArrays() throws {
        struct Row: Codable, Equatable {
            let title: String
            let year: UInt64
            let tags: [String]
            let at: Date
        }
        let schema = SchemaBuilder()
            .addTextField("title", stored: true)
            .addU64Field("year", stored: true)
            .addStringField("tags", stored: true)
            .addDateField("at", stored: true)
            .build()
        let index = try Index.inMemory(schema: schema)

        var doc = Document()
        doc["title"] = "Dune"
        doc["year"] = 1965
        doc["tags"] = ["sci-fi", "classic"]
        let when = Date(timeIntervalSince1970: 1_600_000_000)
        doc.set("at", when)
        try index.add(doc)

        let got = try #require(try index.search("title:Dune", as: Row.self).first)
        #expect(got.title == "Dune")
        #expect(got.year == 1965)
        #expect(Set(got.tags) == ["sci-fi", "classic"])
        #expect(got.at == when)
    }

    @Test func documentBuilderBatch() throws {
        let schema = SchemaBuilder().addTextField("t", stored: true).build()
        let index = try Index.inMemory(schema: schema)
        try index.add(contentsOf: [Document(["t": "a"]), Document(["t": "b"])])
        #expect(index.documentCount == 2)
    }

    // MARK: - TantivyError helpers

    @Test func errorHelpers() {
        let ffi = TantivyError.ffi("boom")
        #expect(ffi.message == "boom")
        #expect(ffi.isEncoding == false)
        #expect(ffi.errorDescription == "tantivy: boom")

        let enc = TantivyError.encoding("bad json")
        #expect(enc.message == "bad json")
        #expect(enc.isEncoding == true)
        #expect(enc.errorDescription == "tantivy encoding: bad json")
    }
}
