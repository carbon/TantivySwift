public import Foundation

/// A typed, store-like façade over an `Index` for a single `Codable` model.
///
/// You supply the schema (its field names must line up with the model's coding
/// keys); the collection gives you typed `add` and `search` without touching
/// `SearchHit` directly.
///
/// ```swift
/// struct Book: Codable { let title: String; let year: UInt64 }
///
/// let books = try SearchCollection<Book>(path: url) { s in
///     s.addTextField("title", stored: true)
///     s.addU64Field("year", stored: true, fast: true)
/// }
/// try books.add(Book(title: "Dune", year: 1965))
/// let hits = try books.search("dune")          // [Book]
/// ```
///
/// `add`, `upsert` and `remove` each open a writer, commit and reload, which
/// is fine for a batch and very slow in a loop. To write many models, pass
/// them to `add(contentsOf:)`, group operations in one `write` block, or keep
/// a long-lived ``writer(heapSize:)`` and commit when it suits you.
///
/// Safe to share for concurrent reads (it forwards to the underlying `Index`).
public final class SearchCollection<Model: Codable>: Sendable {

    /// The underlying index, exposed for advanced use (custom queries, etc.).
    public let index: Index

    /// Wrap an existing index.
    public init(index: Index) {
        self.index = index
    }

    /// Open or create the collection's index at `path` (nil → in-memory).
    public convenience init(
        path: URL?, schema: Schema, reloadPolicy: Index.ReloadPolicy = .manual
    ) throws {
        self.init(index: try Index(path: path, schema: schema, reloadPolicy: reloadPolicy))
    }

    /// Open or create the collection's index, building the schema inline.
    public convenience init(
        path: URL? = nil, reloadPolicy: Index.ReloadPolicy = .manual,
        _ buildSchema: (SchemaBuilder) -> Void
    ) throws {
        let builder = SchemaBuilder()
        buildSchema(builder)
        self.init(index: try Index(path: path, schema: builder.build(), reloadPolicy: reloadPolicy))
    }

    /// An in-memory collection (not persisted).
    public static func inMemory(schema: Schema) throws -> SearchCollection {
        SearchCollection(index: try Index.inMemory(schema: schema))
    }

    // MARK: - Writing

    /// Add one model and make it searchable.
    ///
    /// One writer, commit and reload per call. Do not call it in a loop; use
    /// ``add(contentsOf:)`` or a long-lived ``writer(heapSize:)`` instead.
    public func add(_ value: Model) throws { try index.add(value) }

    /// Add many models in a single commit.
    public func add(contentsOf values: [Model]) throws { try index.add(contentsOf: values) }

    /// Replace any documents whose `idField` equals `id`, then add `value`
    /// (delete-by-term + add) in a single commit. Use a single-token id field.
    ///
    /// One writer, commit and reload per call. To upsert many models, use a
    /// long-lived ``writer(heapSize:)`` and commit once.
    public func upsert(_ value: Model, idField: String, id: String) throws {
        try index.upsert(value, idField: idField, id: id)
    }

    /// A long-lived typed writer. Hold it across many operations and call
    /// ``Writer/commit()`` when a batch is complete: the writer keeps its
    /// indexing threads, and one commit covers the whole batch.
    /// This is the fast path when models arrive one at a time (a stream, a UI
    /// edit loop) rather than as a ready-made array.
    ///
    /// ```swift
    /// let writer = try books.writer()
    /// for book in incoming { try writer.add(book) }
    /// try writer.commit()               // durable + searchable
    /// ```
    ///
    /// There is at most one writer per index at a time, so release it before
    /// using `add`, `upsert`, `remove` or `write` again (they open their own).
    public func writer(heapSize: Int = 0) throws(TantivyError) -> Writer {
        Writer(indexWriter: try index.writer(heapSize: heapSize))
    }

    /// The model whose `idField` equals `id`, if any — a scoreless fetch by id,
    /// complementing `upsert`. Use a single-token id field.
    public func get(idField: String, id: String) throws -> Model? {
        try index.get(idField, equals: id)?.decode(Model.self)
    }

    /// Run a batch of writer operations in one commit (see `Index.write`).
    @discardableResult
    public func write<R>(_ body: (IndexWriter) throws -> R) throws -> R {
        try index.write(body)
    }

    /// Delete every document.
    public func removeAll() throws {
        try index.write { try $0.deleteAllDocuments() }
    }

    /// Delete all documents matching `query` (commit + reload).
    ///
    /// One writer, commit and reload per call; to remove several queries' worth
    /// at once, use ``write(_:)`` or a long-lived ``writer(heapSize:)``.
    public func remove(matching query: Query) throws {
        try index.delete(matching: query)
    }

    /// Reload so the latest commit is observable (only needed if you wrote via a
    /// raw `IndexWriter` rather than this collection's helpers).
    public func reload() throws { try index.reload() }

    // MARK: - Reading

    /// Number of searchable documents.
    public var count: Int { index.documentCount }

    /// Number of documents matching `query` (without loading documents).
    public func count(
        _ query: String, fields: [String] = [], boosts: [String: Double] = [:]
    ) throws -> Int {
        try index.count(query, fields: fields, boosts: boosts)
    }

    /// Number of documents matching a structured ``Query`` (without loading docs).
    public func count(matching query: Query) throws -> Int {
        try index.count(query)
    }

    /// Search and decode matches into `Model`.
    public func search(
        _ query: String, limit: Int = 10, fields: [String] = [], boosts: [String: Double] = [:],
        orderBy: Index.OrderBy? = nil
    ) throws -> [Model] {
        try index.search(
            query, as: Model.self, limit: limit, fields: fields, boosts: boosts, orderBy: orderBy)
    }

    /// Search and return each match together with its relevance score.
    public func searchScored(
        _ query: String, limit: Int = 10, fields: [String] = [], boosts: [String: Double] = [:]
    ) throws -> [(score: Float, model: Model)] {
        try index.search(query, limit: limit, fields: fields, boosts: boosts)
            .map { (score: $0.score, model: try $0.decode(Model.self)) }
    }
}

extension SearchCollection {

    /// A long-lived typed writer over the collection's index, from
    /// ``SearchCollection/writer(heapSize:)``.
    ///
    /// Operations queue until ``commit()``; ``rollback()`` discards them. The
    /// index reader reloads on commit, so committed models are immediately
    /// searchable through the collection. Not thread-safe: use it from one
    /// thread at a time. ``indexWriter`` exposes the underlying `IndexWriter`
    /// for anything this façade doesn't cover (bytes keys, merges).
    public final class Writer {

        /// The underlying writer, for operations the typed API doesn't cover.
        /// It keeps the index alive for as long as this writer exists.
        public let indexWriter: IndexWriter

        init(indexWriter: IndexWriter) {
            self.indexWriter = indexWriter
        }

        /// Queue `value` for addition.
        public func add(_ value: Model) throws(TantivyError) {
            try indexWriter.addDocument(value)
        }

        /// Queue every model in `values` for addition.
        public func add(contentsOf values: some Sequence<Model>) throws(TantivyError) {
            for value in values { try indexWriter.addDocument(value) }
        }

        /// Queue a replace: delete documents whose `idField` equals `id`, then
        /// add `value`. Use a single-token id field. Both take effect on the
        /// next commit, in order.
        public func upsert(_ value: Model, idField: String, id: String) throws(TantivyError) {
            try indexWriter.deleteDocuments(field: idField, equals: id)
            try indexWriter.addDocument(value)
        }

        /// Queue deletion of documents whose `idField` equals `id`.
        public func remove(idField: String, id: String) throws(TantivyError) {
            try indexWriter.deleteDocuments(field: idField, equals: id)
        }

        /// Queue deletion of every document matching `query`.
        public func remove(matching query: Query) throws(TantivyError) {
            try indexWriter.deleteDocuments(matching: query)
        }

        /// Queue deletion of every document.
        public func removeAll() throws(TantivyError) {
            try indexWriter.deleteAllDocuments()
        }

        /// Commit queued operations and reload the reader, so they are durable
        /// and searchable. Returns the opstamp.
        @discardableResult
        public func commit() throws(TantivyError) -> Int64 {
            try indexWriter.commitAndReload()
        }

        /// Discard every operation queued since the last commit. Returns the
        /// opstamp rolled back to.
        @discardableResult
        public func rollback() throws(TantivyError) -> Int64 {
            try indexWriter.rollback()
        }
    }
}
