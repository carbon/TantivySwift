import Foundation
import Testing
@testable import Tantivy

/// Coverage for index maintenance: `stats()`, segment `merge()`/`optimize()`,
/// and `garbageCollect()`.
///
/// Note: the default writer indexes on several threads, so a single commit can
/// produce more than one segment, and a small segment whose only document is
/// deleted is dropped entirely on commit. Tests that need a deterministic
/// segment layout call `optimize()` first to collapse to one segment.
struct MaintenanceTests {

    private func stringIdIndex() throws -> Index {
        try Index.inMemory(schema: SchemaBuilder().addStringField("id", stored: true).build())
    }

    // MARK: - Stats

    @Test func statsReportTotals() throws {
        let index = try Fixtures.animalsIndex()        // 3 docs
        let s = try index.stats()
        #expect(s.documentCount == 3)
        #expect(s.deletedCount == 0)
        #expect(s.maxDoc == 3)
        #expect(s.segmentCount >= 1)
        #expect(s.segments.count == s.segmentCount)
        #expect(s.segments.reduce(0) { $0 + $1.documentCount } == 3)
        #expect(s.segments.allSatisfy { !$0.id.isEmpty })
    }

    @Test func separateCommitsProduceSeparateSegments() throws {
        let index = try stringIdIndex()
        try index.add(["id": "one"])     // each add() is its own commit -> own segment
        try index.add(["id": "two"])
        try index.add(["id": "three"])

        let s = try index.stats()
        #expect(s.documentCount == 3)
        #expect(s.segmentCount == 3)
    }

    /// Releasing a writer must wait for the merges its commit scheduled.
    /// tantivy kills merge threads when a writer is dropped, so without the wait
    /// the scoped helpers (writer, commit, release) abandon every merge and the
    /// index grows one segment per call.
    @Test func releasingWriterCompletesScheduledMerges() throws {
        let index = try stringIdIndex()
        let n = 40
        for i in 0..<n { try index.add(["id": "doc-\(i)"]) }   // one writer + commit each
        #expect(index.documentCount == n)
        #expect(try index.stats().segmentCount < n / 2)
    }

    /// Same on a persistent (mmap) index, where an abandoned merge would also
    /// leave its file set behind: after reopening, the documents are all there
    /// and the segment count is small.
    @Test func releasingWriterCompletesScheduledMergesOnDisk() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("tantivy-merge-wait-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let schema = SchemaBuilder().addStringField("id", stored: true).build()
        let n = 40
        do {
            let index = try Index(path: dir, schema: schema)
            for i in 0..<n { try index.add(["id": "doc-\(i)"]) }
        }
        let reopened = try Index(path: dir, schema: schema)
        #expect(reopened.documentCount == n)
        #expect(try reopened.stats().segmentCount < n / 2)
        for i in stride(from: 0, to: n, by: 7) {
            #expect(try reopened.get("id", equals: "doc-\(i)") != nil)
        }
    }

    /// An upsert loop through the helper (delete + add + commit per call) used
    /// to accumulate a tombstoned segment per call; with merges completing, the
    /// index converges to the one live document.
    @Test func helperUpsertLoopStaysCompact() throws {
        let index = try stringIdIndex()
        let n = 40
        for i in 0..<n {
            try index.upsert(["id": "same"], idField: "id", id: "same")
            try index.add(["id": "filler-\(i)"])          // keeps segments non-empty
        }
        let s = try index.stats()
        #expect(s.documentCount == n + 1)
        #expect(s.segmentCount < n / 2)
        #expect(s.deletedCount < n)                        // merges expunged most tombstones
        #expect(try index.get("id", equals: "same") != nil)
    }

    /// A writer released with uncommitted operations must neither hang on the
    /// merge wait nor publish anything.
    @Test func releasingUncommittedWriterIsCleanAndFast() throws {
        let index = try stringIdIndex()
        try index.add(["id": "committed"])
        do {
            let writer = try index.writer()
            for i in 0..<200 { try writer.addDocument(["id": "pending-\(i)"]) }
        }
        try index.reload()
        #expect(index.documentCount == 1)
        try index.add(["id": "after"])                     // lock was released
        #expect(index.documentCount == 2)
    }

    @Test func statsTrackDeletedDocs() throws {
        let index = try stringIdIndex()
        try index.add(contentsOf: [["id": "a"], ["id": "b"], ["id": "c"]])
        try index.optimize()                              // collapse to a single segment
        try index.delete(matching: .term("id", "b"))      // leaves a tombstone in it

        let s = try index.stats()
        #expect(s.documentCount == 2)       // live
        #expect(s.deletedCount == 1)        // deleted, not yet merged away
        #expect(s.maxDoc == 3)              // live + deleted
    }

    // MARK: - Merge / optimize

    @Test func optimizeCompactsSegmentsIntoOne() throws {
        let index = try stringIdIndex()
        for id in ["alpha", "beta", "gamma", "delta"] { try index.add(["id": id]) }
        #expect(try index.stats().segmentCount == 4)

        try index.optimize()
        let s = try index.stats()
        #expect(s.segmentCount == 1)
        #expect(s.documentCount == 4)
        #expect(try index.get("id", equals: "gamma") != nil)   // still searchable
    }

    @Test func optimizeReclaimsDeletedDocs() throws {
        let index = try stringIdIndex()
        try index.add(contentsOf: [["id": "a"], ["id": "b"], ["id": "c"]])
        try index.optimize()                              // single segment
        try index.delete(matching: .term("id", "b"))
        #expect(try index.stats().deletedCount == 1)

        try index.optimize()                              // rewrites the segment without "b"
        let s = try index.stats()
        #expect(s.documentCount == 2)
        #expect(s.deletedCount == 0)
        #expect(s.maxDoc == 2)
    }

    @Test func optimizeIsIdempotentAndNoOpWhenClean() throws {
        let index = try stringIdIndex()
        try index.add(contentsOf: [["id": "a"], ["id": "b"], ["id": "c"]])
        try index.optimize()                  // -> 1 clean segment
        let before = try index.stats()
        try index.optimize()                  // nothing to gain: no-op
        let after = try index.stats()
        #expect(before.segmentCount == 1)
        #expect(after.segmentCount == 1)
        #expect(after.documentCount == before.documentCount)
    }

    @Test func optimizeOnEmptyIndexIsHarmless() throws {
        let index = try stringIdIndex()
        try index.optimize()
        #expect(try index.stats().documentCount == 0)
    }

    // MARK: - Garbage collection

    @Test func garbageCollectAfterMergeSucceeds() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("tantivy-gc-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }

        let index = try Index(
            path: dir, schema: SchemaBuilder().addStringField("id", stored: true).build())
        for id in ["x", "y", "z"] { try index.add(["id": id]) }
        try index.optimize()             // leaves the pre-merge segments unreferenced
        try index.garbageCollect()       // reclaim them
        #expect(try index.stats().documentCount == 3)
    }

    // MARK: - Persistence

    @Test func statsReflectReopenedIndex() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("tantivy-stats-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let schema = SchemaBuilder().addStringField("id", stored: true).build()

        do {
            let index = try Index(path: dir, schema: schema)
            try index.add(contentsOf: [["id": "x"], ["id": "y"]])
        }
        let reopened = try Index(path: dir, schema: schema)
        #expect(try reopened.stats().documentCount == 2)
    }

    @Test func optimizePersistsAcrossReopen() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("tantivy-opt-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let schema = SchemaBuilder().addStringField("id", stored: true).build()

        do {
            let index = try Index(path: dir, schema: schema)
            for id in ["a", "b", "c", "d"] { try index.add(["id": id]) }   // 4 commits -> 4 segments
            #expect(try index.stats().segmentCount == 4)
            try index.optimize()
            #expect(try index.stats().segmentCount == 1)
        }
        // The compaction is durable: a fresh handle sees the single merged segment.
        let reopened = try Index(path: dir, schema: schema)
        let s = try reopened.stats()
        #expect(s.segmentCount == 1)
        #expect(s.documentCount == 4)
        #expect(try reopened.get("id", equals: "c") != nil)
    }
}
