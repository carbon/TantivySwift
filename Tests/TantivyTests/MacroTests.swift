import Foundation
import Testing
@testable import Tantivy

/// A model whose schema is derived by the `@Indexable` macro.
@Indexable
struct MacroMovie: Codable, Equatable {
    @Field(stored: true, analyzer: .english) var title: String
    @Field(stored: true, fast: true) var year: UInt64
    @Field(stored: true) var tags: [String]
    @Field(stored: true) var rating: Double
}

struct MacroTests {

    @Test func macroDerivesSchemaFromProperties() {
        let json = MacroMovie.searchSchema.json
        // Field names come from property names; analyzer + types are applied.
        #expect(json.contains("\"title\""))
        #expect(json.contains("\"en_stem\""))   // analyzer: .english
        #expect(json.contains("\"year\""))
        #expect(json.contains("\"tags\""))
        #expect(json.contains("\"rating\""))
    }

    @Test func macroModelIndexesAndSearchesViaCollection() throws {
        let movies = try SearchCollection<MacroMovie>()   // schema from the macro
        try movies.add(MacroMovie(title: "Blade Runner", year: 1982,
                                  tags: ["sci-fi", "noir"], rating: 8.1))
        try movies.add(MacroMovie(title: "Dune", year: 2021,
                                  tags: ["sci-fi"], rating: 8.0))

        // English analyzer: "running" stems to match "Runner"? No — verify exact.
        let hit = try #require(try movies.search("title:blade").first)
        #expect(hit.title == "Blade Runner")
        #expect(hit.year == 1982)
        #expect(Set(hit.tags) == ["sci-fi", "noir"])
        #expect(hit.rating == 8.1)

        // Derived numeric field is queryable.
        #expect(try movies.search(.range("year", 1900...2025)).map(\.title).sorted()
                == ["Blade Runner", "Dune"])
        #expect(try movies.search(.range("year", 2000...2025)).map(\.title) == ["Dune"])
    }
}
