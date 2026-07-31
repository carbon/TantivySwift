import Foundation
import CTantivy

/// One bucket of a term-counts (facet) aggregation: a field value and how many
/// matching documents carry it.
public struct FacetCount: Sendable, Equatable {
    /// The field value (a string for text fields, a number for numeric fields).
    public let value: FieldValue
    /// Number of matching documents with this value.
    public let count: Int
}

extension Index {

    /// Top `limit` values of `field` among the documents matching `query`,
    /// with their document counts — the classic facet sidebar:
    ///
    /// ```swift
    /// let tags = try index.termCounts("tag", matching: .parsed("old man"))
    /// // [FacetCount(value: .string("book"), count: 2), ...]
    /// ```
    ///
    /// The field must be declared `fast: true` in the schema. Buckets are
    /// ordered by descending count.
    public func termCounts(
        _ field: String, matching query: Query = .matchAll, limit: Int = 10
    ) throws(TantivyError) -> [FacetCount] {
        try Self.validateNoInteriorNUL(field, "termCounts field name '\(field)'")
        // A negative size reaches tantivy's aggregation parser as a bad `u32`
        // and surfaces as an opaque serde message; reject it here as `search`
        // does for `limit`.
        if limit < 0 { throw .encoding("limit must be non-negative (got \(limit))") }
        let request: [String: Any] = ["counts": ["terms": ["field": field, "size": limit]]]
        guard let data = try? JSONSerialization.data(withJSONObject: request) else {
            throw .encoding("could not serialize aggregation request")
        }
        let result = try aggregate(String(decoding: data, as: UTF8.self), matching: query)

        struct TermsResult: Decodable {
            struct Buckets: Decodable {
                let buckets: [Bucket]
            }
            struct Bucket: Decodable {
                let key: FieldValue
                let docCount: Int
                enum CodingKeys: String, CodingKey {
                    case key
                    case docCount = "doc_count"
                }
            }
            let counts: Buckets
        }
        do {
            let decoded = try JSONDecoder().decode(TermsResult.self, from: Data(result.utf8))
            return decoded.counts.buckets.map { FacetCount(value: $0.key, count: $0.docCount) }
        } catch {
            throw TantivyError.encoding("could not decode aggregation result: \(error)")
        }
    }

    /// Run a raw tantivy aggregation over the documents matching `query` and
    /// return the result JSON. `aggregationsJSON` is tantivy's
    /// (Elasticsearch-compatible) request format, e.g.
    /// `{"avg_year": {"avg": {"field": "year"}}}` — terms, histogram, stats,
    /// min/max/avg, and nested sub-aggregations are all available. Aggregated
    /// fields must be `fast: true` in the schema.
    ///
    /// Prefer ``termCounts(_:matching:limit:)`` for the common facet case.
    public func aggregate(
        _ aggregationsJSON: String, matching query: Query = .matchAll
    ) throws(TantivyError) -> String {
        // An interior NUL would truncate the request at the C boundary, running
        // whatever prefix happened to parse and silently dropping the rest.
        try Self.validateNoInteriorNUL(aggregationsJSON, "aggregation request")
        var err: UnsafeMutablePointer<CChar>?
        let qjson = try query.jsonString()
        let raw: UnsafeMutablePointer<CChar>? =
            qjson.withCString { qC in
                aggregationsJSON.withCString { aC in
                    tantivy_index_aggregate(handle, qC, aC, &err)
                }
            }
        guard let raw else { throw TantivyError.take(&err, fallback: "aggregation failed") }
        defer { tantivy_string_free(raw) }
        return String(cString: raw)
    }
}

extension SearchCollection {
    /// Top `limit` values of `field` among matching documents (see
    /// `Index.termCounts`). The field must be `fast: true` in the schema.
    public func termCounts(
        _ field: String, matching query: Query = .matchAll, limit: Int = 10
    ) throws -> [FacetCount] {
        try index.termCounts(field, matching: query, limit: limit)
    }
}
