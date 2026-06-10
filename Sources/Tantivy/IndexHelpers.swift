// Convenience helpers layered on top of the core Index/IndexWriter API.

extension Index {

    /// Run `body` with a fresh writer, then commit and reload so the changes are
    /// immediately searchable. If `body` throws, nothing is committed (the writer
    /// is discarded with its queued operations), giving all-or-nothing semantics.
    ///
    /// ```swift
    /// try index.write { w in
    ///     try w.addDocument(["title": "Dune", "year": 1965])
    /// }
    /// ```
    ///
    /// Use one `write` block per batch — do not nest (a second writer would be
    /// rejected by the single-writer lock).
    @discardableResult
    public func write<R>(heapSize: Int = 0, _ body: (IndexWriter) throws -> R) throws -> R {
        let writer = try self.writer(heapSize: heapSize)
        let result = try body(writer)   // a throw here skips commit -> changes dropped
        try writer.commit()
        try reload()
        return result
    }

    /// Add a single document (field name → value) and make it searchable.
    public func add(_ document: [String: Any]) throws {
        try write { try $0.addDocument(document) }
    }

    /// Add many documents in one commit.
    public func add(contentsOf documents: [[String: Any]]) throws {
        try write { writer in for doc in documents { try writer.addDocument(doc) } }
    }

    /// Add a single `Encodable` document and make it searchable.
    public func add<T: Encodable>(_ value: T) throws {
        try write { try $0.addDocument(value) }
    }

    /// Add many `Encodable` documents in one commit.
    public func add<T: Encodable>(contentsOf values: [T]) throws {
        try write { writer in for value in values { try writer.addDocument(value) } }
    }

    /// Search and decode each hit's stored fields into `T`.
    ///
    /// ```swift
    /// let books = try index.search("dune", as: Book.self)   // [Book]
    /// ```
    ///
    /// Only `stored` fields are available to decode. Scalar properties read a
    /// field's first value; array properties read all of them.
    public func search<T: Decodable>(
        _ query: String, as type: T.Type, limit: Int = 10,
        fields: [String] = [], boosts: [String: Double] = [:]
    ) throws -> [T] {
        try search(query, limit: limit, fields: fields, boosts: boosts).map { try $0.decode(T.self) }
    }

    /// Replace any documents whose `idField` equals `id`, then add `document` —
    /// in a single commit. tantivy has no in-place update, so this is the
    /// delete-by-term + add pattern. The id field should be a single-token field
    /// (a `string`/raw or numeric/bool field).
    public func upsert(_ document: [String: Any], idField: String, id: String) throws {
        try write { w in
            try w.deleteDocuments(field: idField, equals: id)
            try w.addDocument(document)
        }
    }

    /// Replace any documents whose `idField` equals `id`, then add the
    /// `Encodable` value, in a single commit.
    public func upsert<T: Encodable>(_ value: T, idField: String, id: String) throws {
        try write { w in
            try w.deleteDocuments(field: idField, equals: id)
            try w.addDocument(value)
        }
    }

    /// Delete all documents matching `query`, then commit + reload so the change
    /// is immediately searchable. See `IndexWriter.deleteDocuments(matching:)`.
    public func delete(matching query: Query) throws {
        try write { try $0.deleteDocuments(matching: query) }
    }

    /// The first document whose `field` equals `value` — a scoreless fetch by
    /// id, complementing `upsert`. Use a single-token field (a `string`/raw or
    /// numeric id); on a tokenized text field this matches a single token.
    public func get(_ field: String, equals value: String) throws(TantivyError) -> SearchHit? {
        try search(.term(field, value), limit: 1).first
    }
    public func get(_ field: String, equals value: Int64) throws(TantivyError) -> SearchHit? {
        try search(.term(field, value), limit: 1).first
    }
    public func get(_ field: String, equals value: UInt64) throws(TantivyError) -> SearchHit? {
        try search(.term(field, value), limit: 1).first
    }
}
