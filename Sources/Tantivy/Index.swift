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

    /// Open the index at `path`, creating it (with `schema`) if absent.
    /// Pass `path: nil` for an in-memory index that is never persisted.
    public init(path: URL?, schema: Schema) throws(TantivyError) {
        var err: UnsafeMutablePointer<CChar>?
        let pathStr = path?.path
        let h: OpaquePointer? = schema.json.withCString { schemaC in
            if let p = pathStr {
                return p.withCString { pathC in
                    tantivy_index_open_or_create(pathC, schemaC, &err)
                }
            } else {
                return tantivy_index_open_or_create(nil, schemaC, &err)
            }
        }
        guard let h else { throw TantivyError.take(&err, fallback: "could not open index") }
        self.handle = h
        self.schema = schema
    }

    /// Create an in-memory index (not persisted to disk).
    public static func inMemory(schema: Schema) throws(TantivyError) -> Index {
        try Index(path: nil, schema: schema)
    }

    deinit { tantivy_index_free(handle) }

    /// Create a writer. There must be at most one writer per index at a time.
    /// - Parameter heapSize: indexing memory budget in bytes (0 → 50 MB).
    public func writer(heapSize: Int = 0) throws(TantivyError) -> IndexWriter {
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
    public func search(
        _ query: String, limit: Int = 10, fields: [String] = [], boosts: [String: Double] = [:],
        highlight: [String] = [], snippetMaxChars: Int = 0
    ) throws(TantivyError) -> [SearchHit] {
        var err: UnsafeMutablePointer<CChar>?
        let csv = fields.joined(separator: ",")
        let boostsJSON = Self.boostsJSON(boosts)
        let snipCSV = highlight.joined(separator: ",")
        let raw: UnsafeMutablePointer<CChar>? =
            query.withCString { qC in
                withOptionalCString(csv) { fC in
                    withOptionalCString(boostsJSON) { bC in
                        withOptionalCString(snipCSV) { sC in
                            tantivy_index_search(handle, qC, fC, bC, sC, snippetMaxChars, limit, &err)
                        }
                    }
                }
            }
        guard let raw else { throw TantivyError.take(&err, fallback: "search failed") }
        defer { tantivy_string_free(raw) }
        return try Self.decodeHits(Data(bytes: raw, count: strlen(raw)))
    }

    /// Run a structured ``Query`` (the typed builder that mirrors tantivy's own
    /// query types) and return up to `limit` hits.
    /// - Parameters:
    ///   - highlight: stored text fields to produce highlighted snippets for.
    ///   - snippetMaxChars: max snippet length (0 → tantivy default).
    public func search(
        _ query: Query, limit: Int = 10, highlight: [String] = [], snippetMaxChars: Int = 0
    ) throws(TantivyError) -> [SearchHit] {
        var err: UnsafeMutablePointer<CChar>?
        let qjson = query.jsonString()
        let snipCSV = highlight.joined(separator: ",")
        let raw: UnsafeMutablePointer<CChar>? =
            qjson.withCString { qC in
                withOptionalCString(snipCSV) { sC in
                    tantivy_index_search_query(handle, qC, sC, snippetMaxChars, limit, &err)
                }
            }
        guard let raw else { throw TantivyError.take(&err, fallback: "search failed") }
        defer { tantivy_string_free(raw) }
        return try Self.decodeHits(Data(bytes: raw, count: strlen(raw)))
    }

    // MARK: - Result decoding

    private static func boostsJSON(_ boosts: [String: Double]) -> String {
        guard !boosts.isEmpty else { return "" }
        let data = (try? JSONSerialization.data(withJSONObject: boosts)) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    /// Wire shape of the search JSON envelope. Decoded with `JSONDecoder` (not
    /// `JSONSerialization`) so integers keep exact precision across the full
    /// i64/u64 range — see `FieldValue.init(from:)`.
    private struct SearchResponse: Decodable {
        struct Hit: Decodable {
            let score: Float
            let doc: [String: [FieldValue]]
            let snippets: [String: String]?
        }
        let hits: [Hit]
    }

    private static func decodeHits(_ data: Data) throws(TantivyError) -> [SearchHit] {
        do {
            let resp = try JSONDecoder().decode(SearchResponse.self, from: data)
            return resp.hits.map {
                SearchHit(score: $0.score, fields: $0.doc, snippets: $0.snippets ?? [:])
            }
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
