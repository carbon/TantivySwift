import Foundation
import Testing
@testable import Tantivy

/// Coverage for the typed `SearchCollection<Model>` façade.
struct CollectionTests {

    struct Book: Codable, Hashable {
        let title: String
        let year: UInt64
    }

    private func bookCollection() throws -> SearchCollection<Book> {
        try SearchCollection<Book> { s in
            s.addTextField("title", stored: true)
            s.addU64Field("year", stored: true, fast: true)
        }
    }

    @Test func addAndTypedSearch() throws {
        let books = try bookCollection()
        try books.add(Book(title: "Dune", year: 1965))
        try books.add(contentsOf: [
            Book(title: "Foundation", year: 1951),
            Book(title: "Neuromancer", year: 1984),
        ])
        #expect(books.count == 3)
        #expect(try books.search("title:dune") == [Book(title: "Dune", year: 1965)])
        #expect(try books.search("year:[1980 TO 2000]") == [Book(title: "Neuromancer", year: 1984)])
    }

    @Test func searchScoredIsOrderedByScore() throws {
        let books = try bookCollection()
        try books.add(contentsOf: [
            Book(title: "sea sea sea", year: 1),
            Book(title: "sea", year: 2),
        ])
        let scored = try books.searchScored("title:sea")
        #expect(scored.count == 2)
        #expect(scored[0].score >= scored[1].score)  // TopDocs orders by score
    }

    @Test func removeAllClearsTheCollection() throws {
        let books = try bookCollection()
        try books.add(Book(title: "x", year: 1))
        #expect(books.count == 1)
        try books.removeAll()
        #expect(books.count == 0)
        #expect(try books.search("title:x").isEmpty)
    }

    // MARK: - Long-lived writer

    @Test func writerBatchesUntilCommit() throws {
        let books = try bookCollection()
        let writer = try books.writer()
        try writer.add(Book(title: "Dune", year: 1965))
        try writer.add(contentsOf: [Book(title: "Foundation", year: 1951), Book(title: "Ubik", year: 1969)])
        #expect(books.count == 0)                       // nothing visible before commit
        try writer.commit()
        #expect(books.count == 3)                       // commit reloads: read-your-writes
        #expect(try books.search("title:ubik") == [Book(title: "Ubik", year: 1969)])
    }

    @Test func writerRollbackDiscardsQueuedOperations() throws {
        let books = try bookCollection()
        try books.add(Book(title: "Keep", year: 1))
        let writer = try books.writer()
        try writer.add(Book(title: "Drop", year: 2))
        try writer.removeAll()
        try writer.rollback()
        try writer.commit()
        #expect(try books.search("title:keep").count == 1)
        #expect(try books.search("title:drop").isEmpty)
    }

    @Test func writerUpsertAndRemoveById() throws {
        struct Card: Codable, Equatable { let id: String; let text: String }
        let cards = try SearchCollection<Card> { s in
            s.addStringField("id", stored: true)
            s.addTextField("text", stored: true)
        }
        try cards.add(contentsOf: [Card(id: "a", text: "one"), Card(id: "b", text: "two")])

        let writer = try cards.writer()
        try writer.upsert(Card(id: "a", text: "uno"), idField: "id", id: "a")
        try writer.remove(idField: "id", id: "b")
        try writer.add(Card(id: "c", text: "three"))
        try writer.commit()

        #expect(cards.count == 2)
        #expect(try cards.get(idField: "id", id: "a") == Card(id: "a", text: "uno"))
        #expect(try cards.get(idField: "id", id: "b") == nil)
        #expect(try cards.get(idField: "id", id: "c") == Card(id: "c", text: "three"))
    }

    @Test func writerRemoveMatchingAndLockRelease() throws {
        let books = try bookCollection()
        do {
            let writer = try books.writer()
            try writer.add(contentsOf: [Book(title: "Old", year: 1900), Book(title: "New", year: 2000)])
            try writer.commit()
            try writer.remove(matching: .range("year", 1800...1950))
            try writer.commit()
            #expect(try books.search("title:old").isEmpty)
            #expect(books.count == 1)
            #expect(throws: TantivyError.self) { _ = try books.writer() }   // single-writer lock
        }
        try books.add(Book(title: "After", year: 2001))     // lock released with the writer
        #expect(books.count == 2)
    }

    @Test func writerExposesUnderlyingIndexWriter() throws {
        let books = try bookCollection()
        let writer = try books.writer()
        try writer.indexWriter.addDocument(["title": "Raw", "year": 7])
        try writer.commit()
        #expect(try books.search("title:raw") == [Book(title: "Raw", year: 7)])
    }

    @Test func writerRemoveAllCommits() throws {
        let books = try bookCollection()
        try books.add(contentsOf: [Book(title: "A", year: 1), Book(title: "B", year: 2)])
        let writer = try books.writer()
        try writer.removeAll()
        try writer.add(Book(title: "C", year: 3))
        try writer.commit()
        #expect(try books.search("title:a OR title:b").isEmpty)
        #expect(try books.search("title:c") == [Book(title: "C", year: 3)])
        #expect(books.count == 1)
    }

    @Test func writerCommitReturnsIncreasingOpstamps() throws {
        let books = try bookCollection()
        let writer = try books.writer()
        let empty = try writer.commit()                 // nothing queued is fine
        try writer.add(Book(title: "A", year: 1))
        let first = try writer.commit()
        try writer.add(Book(title: "B", year: 2))
        let second = try writer.commit()
        #expect(empty < first && first < second)
        #expect(books.count == 2)
    }

    /// The writer's `add` throws the encoding error and leaves the writer
    /// usable — no partial state from the failed model, later adds still land.
    @Test func writerEncodingFailureLeavesWriterUsable() throws {
        struct Reading: Codable { let title: String; let year: Double }   // JSONEncoder rejects ±inf
        let readings = try SearchCollection<Reading> { s in
            s.addTextField("title", stored: true)
            s.addF64Field("year", stored: true)
        }
        let writer = try readings.writer()
        let error = #expect(throws: TantivyError.self) {
            try writer.add(Reading(title: "bad", year: .infinity))
        }
        #expect(error?.isEncoding == true)
        try writer.add(Reading(title: "good", year: 1.5))
        try writer.commit()
        #expect(readings.count == 1)
        #expect(try readings.search("title:bad").isEmpty)
    }

    /// Operations apply in queue order within one commit: the second upsert's
    /// delete removes the first's add, so one document survives.
    @Test func writerUpsertSameIdTwiceInOneBatchKeepsLast() throws {
        struct Card: Codable, Equatable { let id: String; let text: String }
        let cards = try SearchCollection<Card> { s in
            s.addStringField("id", stored: true)
            s.addTextField("text", stored: true)
        }
        let writer = try cards.writer()
        try writer.upsert(Card(id: "a", text: "first"), idField: "id", id: "a")
        try writer.upsert(Card(id: "a", text: "second"), idField: "id", id: "a")
        try writer.commit()
        #expect(cards.count == 1)
        #expect(try cards.get(idField: "id", id: "a") == Card(id: "a", text: "second"))
    }

    /// A delete only affects documents queued before it in the batch (and
    /// earlier commits); a matching document added afterwards survives.
    @Test func writerRemoveMatchingOnlyAffectsEarlierDocuments() throws {
        let books = try bookCollection()
        let writer = try books.writer()
        try writer.add(Book(title: "before", year: 1900))
        try writer.remove(matching: .range("year", 1800...1950))
        try writer.add(Book(title: "after", year: 1900))
        try writer.commit()
        #expect(try books.search("title:before").isEmpty)
        #expect(try books.search("title:after").count == 1)
    }

    /// While a long-lived writer is alive it holds the single-writer lock, so
    /// every collection helper that opens its own writer fails — and reads keep
    /// working. Releasing the writer hands the lock back.
    @Test func writerBlocksCollectionHelpersWhileAlive() throws {
        let books = try bookCollection()
        try books.add(Book(title: "seed", year: 1))
        do {
            let writer = try books.writer()
            #expect(throws: TantivyError.self) { try books.add(Book(title: "x", year: 2)) }
            #expect(throws: TantivyError.self) { try books.add(contentsOf: [Book(title: "x", year: 2)]) }
            #expect(throws: TantivyError.self) { try books.upsert(Book(title: "x", year: 2), idField: "title", id: "seed") }
            #expect(throws: TantivyError.self) { try books.remove(matching: .term("title", "seed")) }
            #expect(throws: TantivyError.self) { try books.removeAll() }
            #expect(throws: TantivyError.self) { try books.write { _ in } }
            #expect(throws: TantivyError.self) { try books.index.optimize() }
            #expect(try books.search("title:seed").count == 1)       // reads unaffected
            #expect(books.count == 1)
            try writer.add(Book(title: "via writer", year: 3))
            try writer.commit()
        }
        try books.add(Book(title: "later", year: 4))
        #expect(books.count == 3)
    }

    @Test func writerRejectsNegativeHeapSize() throws {
        let books = try bookCollection()
        let error = #expect(throws: TantivyError.self) { try books.writer(heapSize: -1) }
        #expect(error?.isEncoding == true)
    }

    @Test func writerHonoursCustomHeapSize() throws {
        let books = try bookCollection()
        let writer = try books.writer(heapSize: 15_000_000)    // tantivy's per-thread minimum
        try writer.add(contentsOf: (0..<50).map { Book(title: "book \($0)", year: UInt64($0)) })
        try writer.commit()
        #expect(books.count == 50)
    }

    @Test func writerAddContentsOfAcceptsAnySequenceIncludingEmpty() throws {
        let books = try bookCollection()
        let writer = try books.writer()
        try writer.add(contentsOf: [Book]())
        try writer.add(contentsOf: (1...3).lazy.map { Book(title: "lazy \($0)", year: UInt64($0)) })
        try writer.add(contentsOf: Set([Book(title: "set", year: 9)]))
        try writer.commit()
        #expect(books.count == 4)
    }

    /// The writer keeps the index alive: dropping the collection mid-batch
    /// must not invalidate the writer or the commit's reload.
    @Test func writerOutlivesCollectionReference() throws {
        var books: SearchCollection<Book>? = try bookCollection()
        let index = books!.index
        let writer = try books!.writer()
        try writer.add(Book(title: "orphan", year: 1))
        books = nil
        try writer.commit()
        #expect(try index.search("title:orphan", as: Book.self) == [Book(title: "orphan", year: 1)])
    }

    /// `commit()` reloads explicitly, so read-your-writes holds even under the
    /// background `.onCommit` policy that otherwise makes visibility eventual.
    @Test func writerCommitIsReadYourWritesUnderOnCommitPolicy() throws {
        let books = try SearchCollection<Book>(reloadPolicy: .onCommit) { s in
            s.addTextField("title", stored: true)
            s.addU64Field("year", stored: true, fast: true)
        }
        let writer = try books.writer()
        for i in 0..<20 {
            try writer.add(Book(title: "book \(i)", year: UInt64(i)))
            try writer.commit()
            #expect(books.count == i + 1)
        }
    }

    @Test func writerWritesPersistAcrossReopen() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("tantivy-coll-writer-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let schema = SchemaBuilder()
            .addTextField("title", stored: true)
            .addU64Field("year", stored: true)
            .build()
        do {
            let books = try SearchCollection<Book>(path: dir, schema: schema)
            let writer = try books.writer()
            try writer.add(Book(title: "kept", year: 1))
            try writer.commit()
            try writer.add(Book(title: "lost", year: 2))    // released without commit
        }
        let reopened = try SearchCollection<Book>(path: dir, schema: schema)
        #expect(reopened.count == 1)
        #expect(try reopened.search("title:kept").count == 1)
        #expect(try reopened.search("title:lost").isEmpty)
    }

    @Test func persistsAndReopens() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("tantivy-coll-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }

        let schema = SchemaBuilder()
            .addTextField("title", stored: true)
            .addU64Field("year", stored: true)
            .build()
        do {
            let books = try SearchCollection<Book>(path: dir, schema: schema)
            try books.add(Book(title: "Persisted", year: 2020))
            #expect(books.count == 1)
        }
        let reopened = try SearchCollection<Book>(path: dir, schema: schema)
        #expect(reopened.count == 1)
        #expect(try reopened.search("title:persisted").first == Book(title: "Persisted", year: 2020))
    }

    @Test func wrapsExistingIndex() throws {
        let schema = SchemaBuilder().addTextField("title", stored: true).addU64Field("year", stored: true).build()
        let index = try Index.inMemory(schema: schema)
        let books = SearchCollection<Book>(index: index)
        try books.add(Book(title: "Wrapped", year: 1))
        #expect(try index.search("title:wrapped").count == 1)   // same underlying index
        #expect(try books.search("title:wrapped").first == Book(title: "Wrapped", year: 1))
    }

    // MARK: - IndexableDocument

    struct Movie: IndexableDocument, Equatable {
        let title: String
        let year: UInt64
        static let searchSchema = SchemaBuilder()
            .addTextField("title", stored: true)
            .addU64Field("year", stored: true, fast: true)
            .build()
    }

    @Test func indexableDocumentInMemory() throws {
        let movies = try SearchCollection<Movie>.inMemory()
        try movies.add(Movie(title: "Alien", year: 1979))
        #expect(try movies.search("title:alien") == [Movie(title: "Alien", year: 1979)])
    }

    @Test func indexableDocumentNoArgInitIsInMemory() throws {
        let movies = try SearchCollection<Movie>()        // schema inferred from Movie
        try movies.add(Movie(title: "Aliens", year: 1986))
        #expect(movies.count == 1)
    }

    @Test func indexableDocumentPersistsToDisk() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("tantivy-indexable-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }

        do {
            let movies = try SearchCollection<Movie>(path: dir)   // no schema at call site
            try movies.add(Movie(title: "Blade Runner", year: 1982))
            #expect(movies.count == 1)
        }
        let reopened = try SearchCollection<Movie>(path: dir)
        #expect(try reopened.search("title:blade").first == Movie(title: "Blade Runner", year: 1982))
    }
}
