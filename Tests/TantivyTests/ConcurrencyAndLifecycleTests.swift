import Foundation
import Synchronization
import Testing
@testable import Tantivy

/// Coverage for object lifecycle (ARC/handle ownership), index isolation, and
/// concurrent read access through the FFI.
struct ConcurrencyAndLifecycleTests {

    private func textIndex(_ field: String = "t") throws -> Index {
        try Index.inMemory(schema: SchemaBuilder().addTextField(field, stored: true).build())
    }

    /// Counter safe to share into a concurrent closure. Backed by a
    /// `Synchronization.Mutex` (macOS 15+/iOS 18+), so it's checked `Sendable`.
    private final class Counter: Sendable {
        private let value = Mutex(0)
        func increment() { value.withLock { $0 += 1 } }
        var count: Int { value.withLock { $0 } }
    }

    @Test func concurrentSearchesAreSafeAndCorrect() throws {
        let index = try Fixtures.animalsIndex()   // "red"->2, "whale"->1
        let iterations = 400
        let passes = Counter()

        DispatchQueue.concurrentPerform(iterations: iterations) { i in
            let even = i % 2 == 0
            let expected = even ? 2 : 1
            if let hits = try? index.search(even ? "red" : "whale"), hits.count == expected {
                passes.increment()
            }
        }
        #expect(passes.count == iterations)
    }

    @Test func writerKeepsItsIndexAlive() throws {
        // The Index local goes out of scope, but the returned writer retains it,
        // so commitAndReload (which calls back into the index) stays valid.
        func makeWriter() throws -> IndexWriter {
            let index = try textIndex()
            let w = try index.writer()
            try w.addDocument(["t": "alive"])
            return w
        }
        let w = try makeWriter()
        try w.commitAndReload()              // would crash if the index were freed
        try w.addDocument(["t": "still here"])
        try w.commit()
    }

    @Test func manyIndependentIndexesDoNotLeakOrCrash() throws {
        // Exercises create/use/deinit of many handles in sequence.
        for i in 0..<60 {
            let index = try textIndex()
            let w = try index.writer()
            try w.addDocument(["t": "doc \(i)"])
            try w.commitAndReload()
            #expect(index.documentCount == 1)
        }
    }

    @Test func indexesAreIsolated() throws {
        let a = try textIndex()
        let b = try textIndex()
        let wa = try a.writer(); try wa.addDocument(["t": "apple"]); try wa.commitAndReload()
        let wb = try b.writer(); try wb.addDocument(["t": "banana"]); try wb.commitAndReload()

        #expect(try a.search("apple").count == 1)
        #expect(try a.search("banana").count == 0)
        #expect(try b.search("banana").count == 1)
        #expect(try b.search("apple").count == 0)
    }

    @Test func reloadAndDeleteAllOnEmptyIndexAreNoops() throws {
        let index = try textIndex()
        try index.reload()                   // nothing committed yet
        let w = try index.writer()
        try w.deleteAllDocuments()           // delete from empty
        let op = try w.commit()              // empty commit
        #expect(op >= 0)
        try index.reload()
        #expect(index.documentCount == 0)
    }

    @Test func repeatedSearchesAreStable() throws {
        let index = try Fixtures.animalsIndex()
        let first = try index.search("red").count
        for _ in 0..<20 {
            #expect(try index.search("red").count == first)
        }
    }

    @Test func searchAfterEachIncrementalReload() throws {
        let index = try textIndex()
        let w = try index.writer()
        for i in 1...5 {
            try w.addDocument(["t": "word\(i)"])
            try w.commitAndReload()
            #expect(index.documentCount == i)
            #expect(try index.search("word\(i)").count == 1)
        }
        // All five remain searchable.
        #expect(try index.search("word1").count == 1)
        #expect(try index.search("word5").count == 1)
    }
}
