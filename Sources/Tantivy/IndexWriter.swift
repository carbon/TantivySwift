import Foundation
import CTantivy

/// Adds and removes documents in an `Index`. Create one with `Index.writer()`.
///
/// There must be at most one writer per index at a time. Documents become
/// searchable only after `commit()` followed by `Index.reload()` (or a single
/// call to `commitAndReload()`).
public final class IndexWriter {
    /// `CWriter *`
    private let handle: OpaquePointer
    /// Keep the owning index alive for as long as the writer exists, and reachable
    /// for `commitAndReload()`.
    private let index: Index

    init(handle: OpaquePointer, index: Index) {
        self.handle = handle
        self.index = index
    }

    deinit { tantivy_writer_free(handle) }

    /// Add a document from a dictionary of `field name → value`.
    /// Values may be scalars or arrays (for multi-valued fields):
    /// `["title": "Hi", "tags": ["a", "b"], "id": 7]`.
    ///
    /// `Data` values target a `bytes` field and are sent as raw bytes.
    public func addDocument(_ fields: [String: Any]) throws(TantivyError) {
        try addDocument(messagePack: MessagePackWriter.document(fields))
    }

    /// Add a document whose fields are *all* byte values.
    ///
    /// This exists to disambiguate: a dictionary literal of nothing but `Data`
    /// infers as `[String: Data]`, which is `Encodable`, so without this overload
    /// it would bind to ``addDocument(_:)-(T)`` and route the document through
    /// JSON instead.
    public func addDocument(_ fields: [String: Data]) throws(TantivyError) {
        try addDocument(fields as [String: Any])
    }

    /// Add a document from an `Encodable` value. `Date` properties are encoded as
    /// RFC3339 strings so they land in `date` fields.
    ///
    /// > This is the one add path that still goes through JSON, since that is
    /// > what `JSONEncoder` produces. `Data` properties are base64-encoded and
    /// > decoded back by the engine — correct, but it costs an encode and a
    /// > decode. Use ``Document`` or the `[String: Any]` overload to avoid both.
    public func addDocument<T: Encodable>(_ value: T) throws(TantivyError) {
        let data: Data
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.dataEncodingStrategy = .base64
            data = try encoder.encode(value)
        } catch {
            throw TantivyError.encoding("could not encode document: \(error)")
        }
        try addDocument(json: String(decoding: data, as: UTF8.self))
    }

    /// Add a document from a raw JSON object string — the escape hatch for JSON
    /// you already have. Everything else takes the MessagePack path.
    public func addDocument(json: String) throws(TantivyError) {
        var err: UnsafeMutablePointer<CChar>?
        let rc = json.withCString { tantivy_writer_add_json(handle, $0, &err) }
        if rc != 0 { throw TantivyError.take(&err, fallback: "add document failed") }
    }

    /// Add a document from an encoded MessagePack payload.
    func addDocument(messagePack payload: [UInt8]) throws(TantivyError) {
        var err: UnsafeMutablePointer<CChar>?
        let rc = payload.withUnsafeBufferPointer {
            tantivy_writer_add_msgpack(handle, $0.baseAddress, $0.count, &err)
        }
        if rc != 0 { throw TantivyError.take(&err, fallback: "add document failed") }
    }

    /// Commit queued operations, making them durable. Returns the opstamp.
    /// Documents are searchable after the index reader reloads.
    @discardableResult
    public func commit() throws(TantivyError) -> Int64 {
        var err: UnsafeMutablePointer<CChar>?
        let opstamp = tantivy_writer_commit(handle, &err)
        if opstamp < 0 { throw TantivyError.take(&err, fallback: "commit failed") }
        return opstamp
    }

    /// Commit and reload the owning index's reader in one step, so the new
    /// documents are immediately visible to `Index.search`.
    @discardableResult
    public func commitAndReload() throws(TantivyError) -> Int64 {
        let opstamp = try commit()
        try index.reload()
        return opstamp
    }

    /// Discard every operation (add/delete) queued since the last commit, rolling
    /// the writer back to the last committed state. Returns the opstamp rolled
    /// back to. Already-committed documents are unaffected.
    @discardableResult
    public func rollback() throws(TantivyError) -> Int64 {
        var err: UnsafeMutablePointer<CChar>?
        let opstamp = tantivy_writer_rollback(handle, &err)
        if opstamp < 0 { throw TantivyError.take(&err, fallback: "rollback failed") }
        return opstamp
    }

    /// Queue deletion of every document in the index (effective on next commit).
    public func deleteAllDocuments() throws(TantivyError) {
        var err: UnsafeMutablePointer<CChar>?
        if tantivy_writer_delete_all(handle, &err) != 0 {
            throw TantivyError.take(&err, fallback: "delete all failed")
        }
    }

    // MARK: - Delete by term (for replace / upsert)

    /// Delete documents whose `field` equals `value`. Intended for a single-token
    /// field — a `string` (raw) or numeric/bool id — so the term is the whole
    /// value. On a tokenized text field it matches a single token. Effective on
    /// the next commit.
    public func deleteDocuments(field: String, equals value: String) throws(TantivyError) {
        try deleteTerm(field: field, valueJSON: Self.jsonScalar(value))
    }
    public func deleteDocuments(field: String, equals value: Int64) throws(TantivyError) {
        try deleteTerm(field: field, valueJSON: String(value))
    }
    public func deleteDocuments(field: String, equals value: UInt64) throws(TantivyError) {
        try deleteTerm(field: field, valueJSON: String(value))
    }
    public func deleteDocuments(field: String, equals value: Bool) throws(TantivyError) {
        try deleteTerm(field: field, valueJSON: value ? "true" : "false")
    }

    /// Delete documents whose `bytes` field `field` holds exactly `value` — the
    /// upsert primitive for a binary key. The bytes are compared exactly, and
    /// are sent as raw memory rather than base64-encoded.
    public func deleteDocuments(field: String, equals value: Data) throws(TantivyError) {
        try Index.validateNoInteriorNUL(field, "delete field name '\(field)'")
        var err: UnsafeMutablePointer<CChar>?
        let rc = field.withCString { fieldC in
            value.withUnsafeBytes { buffer in
                tantivy_writer_delete_term_bytes(
                    handle, fieldC,
                    buffer.baseAddress?.assumingMemoryBound(to: UInt8.self),
                    buffer.count, &err)
            }
        }
        if rc != 0 { throw TantivyError.take(&err, fallback: "delete term failed") }
    }

    /// Delete documents whose `field` equals any of `values` — a multi-term
    /// delete, run as a single boolean query. Like `deleteDocuments(field:equals:)`
    /// it targets a single-token field. No-op on an empty array. Effective on the
    /// next commit.
    public func deleteDocuments(field: String, equalsAnyOf values: [String]) throws(TantivyError) {
        guard !values.isEmpty else { return }
        try deleteDocuments(matching: .anyOf(values.map { .term(field, $0) }))
    }
    public func deleteDocuments(field: String, equalsAnyOf values: [Int64]) throws(TantivyError) {
        guard !values.isEmpty else { return }
        try deleteDocuments(matching: .anyOf(values.map { .term(field, $0) }))
    }
    public func deleteDocuments(field: String, equalsAnyOf values: [UInt64]) throws(TantivyError) {
        guard !values.isEmpty else { return }
        try deleteDocuments(matching: .anyOf(values.map { .term(field, $0) }))
    }
    public func deleteDocuments(field: String, equalsAnyOf values: [Data]) throws(TantivyError) {
        guard !values.isEmpty else { return }
        try deleteDocuments(matching: .anyOf(values.map { .term(field, $0) }))
    }

    // MARK: - Delete by query

    /// Delete all documents matching a structured ``Query`` — the query-based
    /// counterpart to `deleteDocuments(field:equals:)`. Use it to delete by range,
    /// by several terms, or any composed query. Only affects documents from
    /// previous commits (or added earlier in this commit). Effective on the next
    /// commit.
    ///
    /// > As with the structured search API, `term`/`phrase` clauses match indexed
    /// > tokens exactly; on a tokenized text field pass already-analyzed tokens.
    public func deleteDocuments(matching query: Query) throws(TantivyError) {
        var err: UnsafeMutablePointer<CChar>?
        let rc = try query.jsonString().withCString {
            tantivy_writer_delete_query(handle, $0, &err)
        }
        if rc != 0 { throw TantivyError.take(&err, fallback: "delete query failed") }
    }

    // MARK: - Maintenance

    /// Merge all searchable segments into a single segment — "optimize" /
    /// compaction. This reclaims the space still held by deleted documents and
    /// speeds up searches on an index that has accumulated many small segments
    /// (e.g. after lots of small commits). Blocks until the merge finishes, and
    /// is a no-op when there are fewer than two segments.
    ///
    /// Merging is I/O- and CPU-heavy on a large index; run it off the hot path
    /// (e.g. during idle time), not after every commit. Inspect ``Index/stats()``
    /// to decide when it's worth it — a high `deletedCount` or `segmentCount` is
    /// the signal.
    public func merge() throws(TantivyError) {
        var err: UnsafeMutablePointer<CChar>?
        if tantivy_writer_merge(handle, &err) != 0 {
            throw TantivyError.take(&err, fallback: "merge failed")
        }
    }

    /// Delete segment files the index no longer references (left behind by merges
    /// or deletes). ``merge()`` and commits trigger this automatically; call it
    /// explicitly to reclaim disk eagerly. Blocks until done.
    public func garbageCollect() throws(TantivyError) {
        var err: UnsafeMutablePointer<CChar>?
        if tantivy_writer_garbage_collect(handle, &err) != 0 {
            throw TantivyError.take(&err, fallback: "garbage collect failed")
        }
    }

    /// A Swift string as a JSON string literal, quoted and escaped.
    private static func jsonScalar(_ value: String) -> String {
        var out = JSONWriter(reservingCapacity: value.utf8.count + 2)
        out.write(value)
        return out.text
    }

    private func deleteTerm(field: String, valueJSON: String) throws(TantivyError) {
        // The field name crosses as a C string: an interior NUL would truncate
        // it, and whenever the prefix is itself a valid field name the delete
        // silently lands on that field instead — removing documents the
        // requested field never matched.
        try Index.validateNoInteriorNUL(field, "delete field name '\(field)'")
        var err: UnsafeMutablePointer<CChar>?
        let rc = field.withCString { fC in
            valueJSON.withCString { vC in
                tantivy_writer_delete_term(handle, fC, vC, &err)
            }
        }
        if rc != 0 { throw TantivyError.take(&err, fallback: "delete term failed") }
    }
}
