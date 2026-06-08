import Testing
@testable import Tantivy

/// Coverage for the query-parser syntax exposed through `Index.search`.
struct QueryTests {

    private func titles(_ hits: [SearchHit]) -> Set<String> {
        Set(hits.compactMap { $0.string("title") })
    }

    @Test func booleanAnd() throws {
        let index = try Fixtures.animalsIndex()
        #expect(titles(try index.search("red AND sea")) == ["red crab"])  // both terms
    }

    @Test func booleanOr() throws {
        let index = try Fixtures.animalsIndex()
        #expect(titles(try index.search("whale OR crab")) == ["blue whale", "red crab"])
    }

    @Test func booleanNot() throws {
        let index = try Fixtures.animalsIndex()
        // "sea" matches blue whale (body) and red crab (body); exclude whale.
        #expect(titles(try index.search("sea -whale")) == ["red crab"])
    }

    @Test func fieldScopedTerm() throws {
        let index = try Fixtures.animalsIndex()
        #expect(titles(try index.search("title:red")) == ["red fox", "red crab"])
    }

    @Test func grouping() throws {
        let index = try Fixtures.animalsIndex()
        #expect(titles(try index.search("(red OR blue) AND fox")) == ["red fox"])
    }

    @Test func phraseQueryRequiresAdjacency() throws {
        let index = try Fixtures.animalsIndex()
        #expect(titles(try index.search("body:\"red crab\"")) == ["red crab"])
        #expect(try index.search("body:\"crab red\"").isEmpty)  // wrong order
    }

    @Test func limitCapsResults() throws {
        let index = try Fixtures.animalsIndex()
        // "the" appears in every doc's body.
        #expect(try index.search("the").count == 3)
        #expect(try index.search("the", limit: 2).count == 2)
        #expect(try index.search("the", limit: 0).count == 3)  // 0 -> default 10
    }

    @Test func defaultFieldsRestriction() throws {
        let index = try Fixtures.animalsIndex()
        // "red" is in two titles but only one body.
        #expect(try index.search("red", fields: ["title"]).count == 2)
        #expect(try index.search("red", fields: ["body"]).count == 1)
        #expect(try index.search("red").count == 2)  // union of indexed text fields
    }

    @Test func boostChangesRanking() throws {
        let index = try Fixtures.animalsIndex()
        // Both terms match a different doc; boost whale so it ranks first.
        let hits = try index.search("title:fox OR title:whale^10")
        #expect(hits.count == 2)
        #expect(hits.first?.string("title") == "blue whale")
    }

    @Test func numericExactMatch() throws {
        let index = try Fixtures.animalsIndex()
        #expect(titles(try index.search("year:2002")) == ["blue whale"])
    }

    @Test func numericRange() throws {
        let index = try Fixtures.animalsIndex()
        #expect(titles(try index.search("year:[2002 TO 2003]")) == ["blue whale", "red crab"])
        #expect(titles(try index.search("year:[2001 TO 2001]")) == ["red fox"])
    }

    @Test func emptyIndexReturnsNoHits() throws {
        let index = try Index.inMemory(schema: SchemaBuilder().addTextField("t", stored: true).build())
        #expect(index.documentCount == 0)
        #expect(try index.search("anything").isEmpty)
    }
}
