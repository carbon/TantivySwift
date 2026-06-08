import Foundation
import Testing
@testable import Tantivy

/// Coverage for indexing, commit, reload and deletion semantics.
struct WriteAndCommitTests {

    private func textIndex() throws -> Index {
        try Index.inMemory(schema: SchemaBuilder().addTextField("t", stored: true).build())
    }

    @Test func commitNotVisibleUntilReload() throws {
        let index = try textIndex()
        let w = try index.writer()
        try w.addDocument(["t": "hello"])
        try w.commit()                       // committed, but reader not reloaded
        #expect(index.documentCount == 0)
        #expect(try index.search("hello").isEmpty)

        try index.reload()                   // now observe it
        #expect(index.documentCount == 1)
        #expect(try index.search("hello").count == 1)
    }

    @Test func incrementalCommits() throws {
        let index = try textIndex()
        let w = try index.writer()

        try w.addDocument(["t": "alpha"])
        try w.commitAndReload()
        #expect(index.documentCount == 1)

        try w.addDocument(["t": "beta"])
        try w.commitAndReload()
        #expect(index.documentCount == 2)
        #expect(try index.search("alpha").count == 1)
        #expect(try index.search("beta").count == 1)
    }

    @Test func opstampIncreasesAcrossCommits() throws {
        let index = try textIndex()
        let w = try index.writer()
        try w.addDocument(["t": "a"])
        let first = try w.commit()
        try w.addDocument(["t": "b"])
        let second = try w.commit()
        #expect(second > first)
    }

    @Test func deleteAllThenReAdd() throws {
        let index = try textIndex()
        let w = try index.writer()
        try w.addDocument(["t": "one"])
        try w.addDocument(["t": "two"])
        try w.commitAndReload()
        #expect(index.documentCount == 2)

        try w.deleteAllDocuments()
        try w.commitAndReload()
        #expect(index.documentCount == 0)

        try w.addDocument(["t": "three"])
        try w.commitAndReload()
        #expect(index.documentCount == 1)
        #expect(try index.search("three").count == 1)
        #expect(try index.search("one").isEmpty)
    }

    @Test func rawJSONDocument() throws {
        let index = try textIndex()
        let w = try index.writer()
        try w.addDocument(json: #"{"t": "from raw json"}"#)
        try w.commitAndReload()
        #expect(try index.search("raw").count == 1)
    }

    @Test func largeBatchIndexing() throws {
        let schema = SchemaBuilder()
            .addTextField("title", stored: true)
            .addTextField("body")
            .addU64Field("n", stored: true, fast: true)
            .build()
        let index = try Index.inMemory(schema: schema)
        let w = try index.writer()
        let count = 500
        for i in 0..<count {
            try w.addDocument(["title": "Item \(i)", "body": "filler text token\(i % 10)", "n": i])
        }
        try w.commitAndReload()
        #expect(index.documentCount == count)
        // Every doc has "filler"; limit still caps the page.
        #expect(try index.search("filler", limit: 25).count == 25)
        // token3 appears in 1/10 of docs.
        #expect(try index.search("body:token3", limit: 1000).count == count / 10)
    }

    @Test func secondWriterIsRejected() throws {
        // tantivy permits only one writer (one directory lock) at a time.
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("tantivy-lock-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }

        let schema = SchemaBuilder().addTextField("t", stored: true).build()
        let index = try Index(path: dir, schema: schema)
        let first = try index.writer()
        #expect(throws: TantivyError.self) {
            try index.writer()
        }
        withExtendedLifetime(first) {}
    }
}
