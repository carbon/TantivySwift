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
    public func addDocument(_ fields: [String: Any]) throws(TantivyError) {
        guard Self.allFinite(fields) else {
            throw TantivyError.encoding("document contains a non-finite number (NaN/±∞)")
        }
        let data: Data
        do {
            data = try JSONSerialization.data(withJSONObject: fields)
        } catch {
            throw TantivyError.encoding("could not serialize document: \(error)")
        }
        try addDocument(json: String(decoding: data, as: UTF8.self))
    }

    /// True if no `Double`/`Float` anywhere in `value` is non-finite. Guards the
    /// `[String: Any]` add path: a NaN/±∞ would otherwise raise an *uncatchable*
    /// `NSException` from `JSONSerialization`, crashing the process.
    private static func allFinite(_ value: Any) -> Bool {
        switch value {
        case let d as Double: return d.isFinite
        case let f as Float: return f.isFinite
        case let array as [Any]: return array.allSatisfy(allFinite)
        case let dict as [String: Any]: return dict.values.allSatisfy(allFinite)
        default: return true
        }
    }

    /// Add a document from an `Encodable` value. `Date` properties are encoded as
    /// RFC3339 strings so they land in `date` fields.
    public func addDocument<T: Encodable>(_ value: T) throws(TantivyError) {
        let data: Data
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            data = try encoder.encode(value)
        } catch {
            throw TantivyError.encoding("could not encode document: \(error)")
        }
        try addDocument(json: String(decoding: data, as: UTF8.self))
    }

    /// Add a document from a raw JSON object string.
    public func addDocument(json: String) throws(TantivyError) {
        var err: UnsafeMutablePointer<CChar>?
        let rc = json.withCString { tantivy_writer_add_json(handle, $0, &err) }
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
        try deleteTerm(field: field, valueJSON: Self.jsonString(value))
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
        let qjson = try query.jsonString()
        let rc = qjson.withCString {
            tantivy_writer_delete_query(handle, $0, &err)
        }
        if rc != 0 { throw TantivyError.take(&err, fallback: "delete query failed") }
    }

    private func deleteTerm(field: String, valueJSON: String) throws(TantivyError) {
        var err: UnsafeMutablePointer<CChar>?
        let rc = field.withCString { fC in
            valueJSON.withCString { vC in
                tantivy_writer_delete_term(handle, fC, vC, &err)
            }
        }
        if rc != 0 { throw TantivyError.take(&err, fallback: "delete term failed") }
    }

    /// Encode a Swift string as a JSON string literal (quoted + escaped).
    private static func jsonString(_ s: String) -> String {
        var out = "\""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if scalar.value < 0x20 {
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        out += "\""
        return out
    }
}
