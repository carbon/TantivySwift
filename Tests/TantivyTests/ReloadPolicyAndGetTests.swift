import Foundation
import Testing
@testable import Tantivy

/// Coverage for `ReloadPolicy.onCommit` and the `get` (fetch-by-id) helpers.
struct ReloadPolicyAndGetTests {

    private static let schema = SchemaBuilder()
        .addStringField("id", stored: true)
        .addTextField("title", stored: true)
        .addU64Field("year", stored: true)
        .build()

    // MARK: - Reload policy

    @Test func onCommitPolicyMakesCommitsVisibleWithoutReload() throws {
        let index = try Index.inMemory(schema: Self.schema, reloadPolicy: .onCommit)
        let writer = try index.writer()
        try writer.addDocument(["id": "a", "title": "dune", "year": 1965])
        try writer.commit()   // note: no reload()

        // OnCommitWithDelay reloads in the background shortly after the commit.
        var visible = false
        for _ in 0..<200 where !visible {   // up to ~10s; normally instant
            visible = index.documentCount == 1
            if !visible { Thread.sleep(forTimeInterval: 0.05) }
        }
        #expect(visible)
        #expect(try index.search("dune").count == 1)
    }

    @Test func manualPolicyStillRequiresReload() throws {
        let index = try Index.inMemory(schema: Self.schema)   // default .manual
        let writer = try index.writer()
        try writer.addDocument(["id": "a", "title": "dune", "year": 1965])
        try writer.commit()
        #expect(index.documentCount == 0)   // not visible yet
        try index.reload()
        #expect(index.documentCount == 1)
    }

    // MARK: - get

    @Test func getByStringId() throws {
        let index = try Index.inMemory(schema: Self.schema)
        try index.add(["id": "a", "title": "dune", "year": 1965])
        try index.add(["id": "b", "title": "hyperion", "year": 1989])

        #expect(try index.get("id", equals: "a")?.string("title") == "dune")
        #expect(try index.get("id", equals: "zz") == nil)
    }

    @Test func getByNumericId() throws {
        let index = try Index.inMemory(schema: Self.schema)
        try index.add(["id": "a", "title": "dune", "year": 1965])

        #expect(try index.get("year", equals: UInt64(1965))?.string("title") == "dune")
        #expect(try index.get("year", equals: Int64(1965))?.string("title") == "dune")
        #expect(try index.get("year", equals: UInt64(1900)) == nil)
    }

    @Test func getReflectsUpsert() throws {
        let index = try Index.inMemory(schema: Self.schema)
        try index.upsert(["id": "a", "title": "dune", "year": 1965], idField: "id", id: "a")
        try index.upsert(["id": "a", "title": "dune (revised)", "year": 1965], idField: "id", id: "a")

        #expect(index.documentCount == 1)
        #expect(try index.get("id", equals: "a")?.string("title") == "dune (revised)")
    }

    @Test func collectionGet() throws {
        struct Book: Codable, Equatable { let id: String; let title: String }
        let books = try SearchCollection<Book> { s in
            s.addStringField("id", stored: true)
            s.addTextField("title", stored: true)
        }
        try books.add(Book(id: "a", title: "dune"))

        #expect(try books.get(idField: "id", id: "a") == Book(id: "a", title: "dune"))
        #expect(try books.get(idField: "id", id: "zz") == nil)
    }
}
