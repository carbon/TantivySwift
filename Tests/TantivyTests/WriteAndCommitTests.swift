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

    // MARK: - `write` block semantics

    private struct Boom: Error {}

    /// `write` documents all-or-nothing semantics: a throw from the body skips
    /// the commit, so the queued documents are dropped rather than half-applied.
    @Test func writeBlockDiscardsQueuedDocumentsOnThrow() throws {
        let index = try textIndex()
        try index.write { try $0.addDocument(["t": "committed"]) }
        #expect(index.documentCount == 1)

        #expect(throws: Boom.self) {
            try index.write { w in
                try w.addDocument(["t": "doomed one"])
                try w.addDocument(["t": "doomed two"])
                throw Boom()
            }
        }
        try index.reload()
        #expect(index.documentCount == 1)                       // neither landed
        #expect(try index.search("doomed").isEmpty)
        #expect(try index.search("committed").count == 1)        // the earlier commit survives
    }

    /// The discarded writer must also release the directory lock, or every
    /// later write would fail with `LockBusy` after a single failed block.
    @Test func writeBlockReleasesTheWriterLockOnThrow() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("tantivy-write-throw-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let index = try Index(path: dir, schema: SchemaBuilder()
            .addTextField("t", stored: true).build())

        #expect(throws: Boom.self) {
            try index.write { w in
                try w.addDocument(["t": "doomed"])
                throw Boom()
            }
        }
        // A second write must still succeed.
        try index.write { try $0.addDocument(["t": "after"]) }
        #expect(index.documentCount == 1)
        #expect(try index.search("after").count == 1)
        #expect(try index.search("doomed").isEmpty)
    }

    /// The return value is forwarded when the body succeeds.
    @Test func writeBlockReturnsBodyResult() throws {
        let index = try textIndex()
        let count = try index.write { w -> Int in
            for i in 0..<3 { try w.addDocument(["t": "doc \(i)"]) }
            return 3
        }
        #expect(count == 3)
        #expect(index.documentCount == 3)
    }
}
