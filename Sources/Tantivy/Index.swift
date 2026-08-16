import Foundation
import CTantivy

/// A full-text search index backed by tantivy 0.26.1.
///
/// ```swift
/// let schema = SchemaBuilder()
///     .addTextField("title", stored: true)
///     .addTextField("body")
///     .build()
///
/// let index = try Index(path: URL(fileURLWithPath: "/tmp/myindex"), schema: schema)
/// let writer = try index.writer()
/// try writer.addDocument(["title": "The Old Man and the Sea",
///                         "body": "He was an old man who fished alone..."])
/// try writer.commit()
/// try index.reload()
///
/// for hit in try index.search("sea", limit: 5) {
///     print(hit.score, hit.string("title") ?? "")
/// }
/// ```
///
/// An `Index` is safe to share for concurrent reads: `search`, `reload`, and
/// `documentCount` may be called from multiple threads. Writing (`IndexWriter`)
/// is single-threaded — use one writer at a time.
public final class Index: @unchecked Sendable {
    /// `CIndex *`
    let handle: OpaquePointer
    /// The schema this index was created/opened with.
    public let schema: Schema

    /// How to order search hits: by a fast field instead of relevance.
    ///
    /// The field must be a numeric (`u64`/`i64`/`f64`) or `date` field declared
    /// `fast: true` in the schema. Field-ordered hits carry a `score` of 0
    /// (tantivy returns the sort key in place of computing BM25).
    public struct OrderBy: Sendable {
        public let field: String
        public let ascending: Bool
        /// Largest value first (newest date, highest number).
        public static func descending(_ field: String) -> OrderBy {
            .init(field: field, ascending: false)
        }
        /// Smallest value first (oldest date, lowest number).
        public static func ascending(_ field: String) -> OrderBy {
            .init(field: field, ascending: true)
        }
    }

    /// When searches start observing new commits.
    public enum ReloadPolicy: Sendable {
        /// Only after an explicit `reload()` (or `commitAndReload()` / the
        /// `write` helpers, which reload for you). The default.
        case manual
        /// A background watcher reloads the reader shortly after every commit —
        /// near-real-time with no `reload()` calls needed, but not strict
        /// read-your-writes: a search immediately after `commit()` may briefly
        /// observe the previous generation.
        case onCommit
    }

    /// Open the index at `path`, creating it (with `schema`) if absent.
    /// Pass `path: nil` for an in-memory index that is never persisted.
    public init(
        path: URL?, schema: Schema, reloadPolicy: ReloadPolicy = .manual
    ) throws(TantivyError) {
        var err: UnsafeMutablePointer<CChar>?
        let pathStr = path?.path
        let onCommit: Int32 = reloadPolicy == .onCommit ? 1 : 0
        let h: OpaquePointer? = schema.json.withCString { schemaC in
            if let p = pathStr {
                return p.withCString { pathC in
                    tantivy_index_open_or_create(pathC, schemaC, onCommit, &err)
                }
            } else {
                return tantivy_index_open_or_create(nil, schemaC, onCommit, &err)
            }
        }
        guard let h else { throw TantivyError.take(&err, fallback: "could not open index") }
        self.handle = h
        self.schema = schema
    }

    /// Create an in-memory index (not persisted to disk).
    public static func inMemory(
        schema: Schema, reloadPolicy: ReloadPolicy = .manual
    ) throws(TantivyError) -> Index {
        try Index(path: nil, schema: schema, reloadPolicy: reloadPolicy)
    }

    deinit { tantivy_index_free(handle) }

    /// Create a writer. There must be at most one writer per index at a time.
    /// - Parameter heapSize: indexing memory budget in bytes (0 → 50 MB).
    public func writer(heapSize: Int = 0) throws(TantivyError) -> IndexWriter {
        // A negative size wraps to a huge `usize` at the FFI boundary, which the
        // engine then rejects for exceeding its per-thread arena cap — an error
        // that says nothing about the value actually passed.
        try Self.validateNonNegative(heapSize, "heapSize")
        var err: UnsafeMutablePointer<CChar>?
        guard let w = tantivy_index_writer(handle, heapSize, &err) else {
            throw TantivyError.take(&err, fallback: "could not create writer")
        }
        return IndexWriter(handle: w, index: self)
    }

    /// Reload the reader so subsequent searches observe the latest commit.
    /// Call this after `IndexWriter.commit()` (or use `commitAndReload`).
    public func reload() throws(TantivyError) {
        var err: UnsafeMutablePointer<CChar>?
        if tantivy_index_reload(handle, &err) != 0 {
            throw TantivyError.take(&err, fallback: "reload failed")
        }
    }

    /// Number of searchable documents as of the last reload.
    public var documentCount: Int {
        var err: UnsafeMutablePointer<CChar>?
        let n = tantivy_index_num_docs(handle, &err)
        if n < 0 { tantivy_string_free(err); return 0 }
        return Int(n)
    }

    /// Search the index and return up to `limit` hits.
    /// - Parameters:
    ///   - query: query string in tantivy syntax (e.g. `"sea"`, `"title:whale"`,
    ///     `"\"old man\""`, `"body:fish AND title:sea"`).
    ///   - limit: maximum number of hits (0 → 10).
    ///   - fields: default fields to search when the query doesn't name one.
    ///     Empty → all indexed text fields.
    ///   - boosts: optional per-field weights, e.g. `["title": 2.0, "body": 0.5]`.
    ///   - highlight: stored text fields to produce highlighted snippets for
    ///     (`SearchHit.snippet(_:)`). Empty → no snippets.
    ///   - snippetMaxChars: max snippet length (0 → tantivy default).
    ///   - orderBy: sort hits by a numeric/date fast field instead of relevance
    ///     (e.g. `.descending("created")`). `nil` → best match first.
    public func search(
        _ query: String, limit: Int = 10, fields: [String] = [], boosts: [String: Double] = [:],
        highlight: [String] = [], snippetMaxChars: Int = 0, orderBy: OrderBy? = nil
    ) throws(TantivyError) -> [SearchHit] {
        try Self.validateQueryString(query)
        try Self.validateNonNegative(limit, "limit")
        try Self.validateNonNegative(snippetMaxChars, "snippetMaxChars")
        try Self.validateFieldNames(fields, "default")
        try Self.validateFieldNames(highlight, "highlight")
        if let orderBy { try Self.validateFieldName(orderBy.field, "order-by") }
        var err: UnsafeMutablePointer<CChar>?
        let csv = fields.joined(separator: ",")
        let boostsJSON = try Self.boostsJSON(boosts)
        let snipCSV = highlight.joined(separator: ",")
        let result: OpaquePointer? =
            query.withCString { qC in
                withOptionalCString(csv) { fC in
                    withOptionalCString(boostsJSON) { bC in
                        withOptionalCString(snipCSV) { sC in
                            withOptionalCString(orderBy?.field ?? "") { oC in
                                tantivy_index_search(
                                    handle, qC, fC, bC, sC, snippetMaxChars, limit,
                                    oC, orderBy?.ascending == true ? 1 : 0, &err)
                            }
                        }
                    }
                }
            }
        guard let result else { throw TantivyError.take(&err, fallback: "search failed") }
        return try Self.decodeHits(result)
    }

    /// Run a structured ``Query`` (the typed builder that mirrors tantivy's own
    /// query types) and return up to `limit` hits.
    /// - Parameters:
    ///   - highlight: stored text fields to produce highlighted snippets for.
    ///   - snippetMaxChars: max snippet length (0 → tantivy default).
    ///   - orderBy: sort hits by a numeric/date fast field instead of relevance
    ///     (e.g. `.descending("created")`). `nil` → best match first.
    public func search(
        _ query: Query, limit: Int = 10, highlight: [String] = [], snippetMaxChars: Int = 0,
        orderBy: OrderBy? = nil
    ) throws(TantivyError) -> [SearchHit] {
        try Self.validateNonNegative(limit, "limit")
        try Self.validateNonNegative(snippetMaxChars, "snippetMaxChars")
        try Self.validateFieldNames(highlight, "highlight")
        if let orderBy { try Self.validateFieldName(orderBy.field, "order-by") }
        var err: UnsafeMutablePointer<CChar>?
        let qjson = try query.jsonString()
        let snipCSV = highlight.joined(separator: ",")
        let result: OpaquePointer? =
            qjson.withCString { qC in
                withOptionalCString(snipCSV) { sC in
                    withOptionalCString(orderBy?.field ?? "") { oC in
                        tantivy_index_search_query(
                            handle, qC, sC, snippetMaxChars, limit,
                            oC, orderBy?.ascending == true ? 1 : 0, &err)
                    }
                }
            }
        guard let result else { throw TantivyError.take(&err, fallback: "search failed") }
        return try Self.decodeHits(result)
    }

    /// The raw wire payload for a query, without decoding it. For measuring
    /// the encoding; not public API.
    func rawSearchPayload(_ query: Query, limit: Int = 10) throws(TantivyError) -> Data {
        var err: UnsafeMutablePointer<CChar>?
        let result: OpaquePointer? = try query.jsonString().withCString { qC in
            tantivy_index_search_query(handle, qC, nil, 0, limit, nil, 0, &err)
        }
        guard let result else { throw TantivyError.take(&err, fallback: "search failed") }
        defer { tantivy_result_free(result) }

        let length = tantivy_result_len(result)
        guard length > 0, let base = tantivy_result_bytes(result) else { return Data() }
        return Data(bytes: base, count: length)
    }

    // MARK: - Counting

    /// Number of documents matching `query` (tantivy query syntax) without
    /// loading or transferring any documents — cheaper than `search(...).count`
    /// for large result sets, and not capped by a `limit`.
    public func count(
        _ query: String, fields: [String] = [], boosts: [String: Double] = [:]
    ) throws(TantivyError) -> Int {
        try Self.validateQueryString(query)
        try Self.validateFieldNames(fields, "default")
        var err: UnsafeMutablePointer<CChar>?
        let csv = fields.joined(separator: ",")
        let boostsJSON = try Self.boostsJSON(boosts)
        let n = query.withCString { qC in
            withOptionalCString(csv) { fC in
                withOptionalCString(boostsJSON) { bC in
                    tantivy_index_count(handle, qC, fC, bC, &err)
                }
            }
        }
        if n < 0 { throw TantivyError.take(&err, fallback: "count failed") }
        return Int(n)
    }

    /// Number of documents matching a structured ``Query`` (no documents loaded).
    public func count(_ query: Query) throws(TantivyError) -> Int {
        var err: UnsafeMutablePointer<CChar>?
        let n = try query.jsonString().withCString {
            tantivy_index_count_query(handle, $0, &err)
        }
        if n < 0 { throw TantivyError.take(&err, fallback: "count failed") }
        return Int(n)
    }

    // MARK: - Argument validation

    /// Every string handed to the engine travels as a C string, so an interior
    /// NUL would silently truncate it there. Depending on the argument that
    /// means searching, highlighting, or sorting on a *different* field than
    /// asked for (whenever the truncated prefix is itself a valid field name),
    /// or — via `IndexWriter.deleteDocuments(field:equals:)` — deleting
    /// documents the requested field never matched.
    static func validateNoInteriorNUL(_ s: String, _ what: String) throws(TantivyError) {
        if s.unicodeScalars.contains("\u{0}") {
            throw .encoding("\(what) contains an interior NUL character")
        }
    }

    private static func validateQueryString(_ query: String) throws(TantivyError) {
        try validateNoInteriorNUL(query, "query string")
    }

    /// Field names reach the engine as comma-separated C strings, so both an
    /// interior NUL and an embedded comma would change which fields are used.
    static func validateFieldName(_ name: String, _ what: String) throws(TantivyError) {
        try validateNoInteriorNUL(name, "\(what) field name '\(name)'")
        if name.contains(",") {
            throw .encoding("\(what) field name '\(name)' contains a comma")
        }
    }

    private static func validateFieldNames(
        _ names: [String], _ what: String
    ) throws(TantivyError) {
        for name in names { try validateFieldName(name, what) }
    }

    /// Negative counts would wrap to huge values at the `usize` FFI boundary.
    private static func validateNonNegative(_ value: Int, _ name: String) throws(TantivyError) {
        if value < 0 {
            throw .encoding("\(name) must be non-negative (got \(value))")
        }
    }

    // MARK: - Result decoding

    // Internal rather than private so the encoding can be tested directly;
    // escaping bugs here are silent, and a search with boosts would still
    // return plausible results.
    static func boostsJSON(_ boosts: [String: Double]) throws(TantivyError) -> String {
        guard !boosts.isEmpty else { return "" }
        for (field, value) in boosts where !value.isFinite {
            throw .encoding("non-finite boost for field '\(field)' (NaN/±∞)")
        }
        // A NUL survives JSON-escaped rather than truncating, but the engine's
        // "unknown field" message then contains it and is lost on the way back
        // out — leaving a bare `tantivy: error`. Reject it here instead.
        for field in boosts.keys {
            try validateNoInteriorNUL(field, "boost field name '\(field)'")
        }
        var out = JSONWriter()
        out.raw("{")
        // Sorted so the payload is stable across runs; dictionaries iterate in
        // hash order, which made identical requests serialize differently.
        for (index, field) in boosts.keys.sorted().enumerated() {
            if index > 0 { out.raw(",") }
            out.write(field)
            out.raw(":")
            out.write(boosts[field]!)
        }
        out.raw("}")
        return out.text
    }

    /// Decode a `CResult` — the MessagePack hit envelope — and release it.
    ///
    /// The payload is read in place, straight off the Rust allocation: values
    /// become `SearchHit`s with no intermediate representation and no `Codable`
    /// in between. Both were the dominant cost of the JSON envelope this
    /// replaced.
    private static func decodeHits(_ result: OpaquePointer) throws(TantivyError) -> [SearchHit] {
        defer { tantivy_result_free(result) }

        let length = tantivy_result_len(result)
        guard length > 0, let base = tantivy_result_bytes(result) else { return [] }
        do {
            return try MessagePackReader.decodeHits(
                UnsafeRawBufferPointer(start: base, count: length))
        } catch {
            throw TantivyError.encoding("could not decode search response: \(error)")
        }
    }
}

/// Call `body` with a C string, or `nil` when `s` is empty.
private func withOptionalCString<R>(_ s: String, _ body: (UnsafePointer<CChar>?) -> R) -> R {
    s.isEmpty ? body(nil) : s.withCString { body($0) }
}

extension TantivyError {
    /// Consume a heap error string from the FFI layer (freeing it) and wrap it.
    static func take(_ err: inout UnsafeMutablePointer<CChar>?, fallback: String) -> TantivyError {
        if let e = err {
            let msg = String(cString: e)
            tantivy_string_free(e)
            err = nil
            return .ffi(msg)
        }
        return .ffi(fallback)
    }
}
