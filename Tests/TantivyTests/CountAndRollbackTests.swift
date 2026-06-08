import Foundation
import Testing
@testable import Tantivy

/// Coverage for count-only search (`Index.count`), writer `rollback()`, and the
/// finiteness guard that stops a malformed `Query` degrading to match-all.
struct CountAndRollbackTests {

    // MARK: - Count

    @Test func countStringQuery() throws {
        let index = try Fixtures.animalsIndex()    // titles: red fox / blue whale / red crab
        #expect(try index.count("red") == 2)
        #expect(try index.count("whale") == 1)
        #expect(try index.count("dragon") == 0)
    }

    @Test func countIsTotalNotLimited() throws {
        let index = try Fixtures.animalsIndex()     // all 3 bodies contain "the"
        #expect(try index.search("the", limit: 1, fields: ["body"]).count == 1)  // capped
        #expect(try index.count("the", fields: ["body"]) == 3)                    // true total
    }

    @Test func countStructuredQuery() throws {
        let index = try Fixtures.animalsIndex()     // years 2001, 2002, 2003
        #expect(try index.count(.matchAll) == 3)
        #expect(try index.count(.range("year", 2002...2003)) == 2)
        #expect(try index.count(.term("year", UInt64(2001))) == 1)
    }

    @Test func collectionCount() throws {
        struct Row: Codable { let n: UInt64 }
        let c = try SearchCollection<Row> { s in s.addU64Field("n", stored: true, fast: true) }
        try c.add(contentsOf: [Row(n: 1), Row(n: 2), Row(n: 3)])
        #expect(c.count == 3)                                   // property: all docs
        #expect(try c.count(matching: .range("n", 2...3)) == 2) // query count
        #expect(try c.count("n:1") == 1)                        // string count
    }

    // MARK: - Rollback

    @Test func rollbackDiscardsUncommittedOps() throws {
        let index = try Index.inMemory(
            schema: SchemaBuilder().addTextField("t", stored: true).build())
        let w = try index.writer()
        try w.addDocument(["t": "keep"])
        try w.commitAndReload()
        #expect(index.documentCount == 1)

        try w.addDocument(["t": "discard"])    // queued but not committed
        try w.rollback()                       // drop it
        try w.commitAndReload()
        #expect(index.documentCount == 1)
        #expect(try index.search("discard").isEmpty)
        #expect(try index.search("keep").count == 1)

        // Writer is still usable after a rollback.
        try w.addDocument(["t": "after"])
        try w.commitAndReload()
        #expect(index.documentCount == 2)
    }

    @Test func rollbackDoesNotUndoCommittedDocs() throws {
        let index = try Index.inMemory(
            schema: SchemaBuilder().addTextField("t", stored: true).build())
        let w = try index.writer()
        try w.addDocument(["t": "committed"])
        try w.commit()
        try w.rollback()                       // nothing pending; committed doc stays
        try index.reload()
        #expect(index.documentCount == 1)
    }

    // MARK: - Finiteness guard (the match-all fix)

    @Test func nonFiniteBoostThrowsNotMatchAll() throws {
        let index = try Fixtures.animalsIndex()
        #expect(throws: TantivyError.self) {
            _ = try index.search(Query.matchAll.boosted(by: .infinity))
        }
    }

    @Test func nonFiniteDeleteQueryThrowsAndDeletesNothing() throws {
        let index = try Fixtures.animalsIndex()
        let w = try index.writer()
        // A NaN term must NOT fall back to deleting every document.
        #expect(throws: TantivyError.self) {
            try w.deleteDocuments(matching: .term("year", Double.nan))
        }
        try w.commitAndReload()
        #expect(index.documentCount == 3)
    }

    @Test func nonFiniteCountThrows() throws {
        let index = try Fixtures.animalsIndex()
        #expect(throws: TantivyError.self) {
            _ = try index.count(.range("year", from: .included(.double(.nan))))
        }
    }

    @Test func nonFiniteDictionaryDocumentThrows() throws {
        let index = try Index.inMemory(
            schema: SchemaBuilder().addF64Field("score", stored: true).build())
        let w = try index.writer()
        #expect(throws: TantivyError.self) { try w.addDocument(["score": Double.infinity]) }
        #expect(throws: TantivyError.self) { try w.addDocument(["score": [1.0, Double.nan]]) }
    }

    @Test func nonFiniteTypedDocumentThrows() throws {
        let index = try Index.inMemory(
            schema: SchemaBuilder().addF64Field("score", stored: true).build())
        var doc = Document()
        doc["score"] = .double(.nan)
        #expect(throws: TantivyError.self) { try index.add(doc) }
    }

    @Test func nonFiniteBoostInSearchThrows() throws {
        let index = try Fixtures.animalsIndex()
        #expect(throws: TantivyError.self) {
            _ = try index.search("red", boosts: ["title": .infinity])
        }
    }
}
