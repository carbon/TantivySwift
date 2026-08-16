import Foundation
import CTantivy

/// A bucket key from tantivy's aggregation result.
///
/// Aggregation results are the one part of the FFI still carried as tantivy's
/// own JSON (it is the Elasticsearch-compatible format the engine defines), so
/// this is the only place a ``FieldValue`` is built by `Codable`. Hits take the
/// MessagePack path instead. A facet key is always a string or a number —
/// grouping by a `bytes` field is not something tantivy's terms aggregation
/// produces — so there is no byte case here.
private struct AggregationKey: Decodable {
    let value: FieldValue

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let b = try? c.decode(Bool.self) { value = .bool(b); return }
        if let i = try? c.decode(Int64.self) { value = .int(i); return }
        if let u = try? c.decode(UInt64.self) { value = .unsigned(u); return }
        if let d = try? c.decode(Double.self) { value = .double(d); return }
        if let s = try? c.decode(String.self) { value = .string(s); return }
        throw DecodingError.dataCorruptedError(
            in: c, debugDescription: "unsupported aggregation bucket key")
    }
}

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
        var request = JSONWriter()
        request.raw(#"{"counts":{"terms":{"field":"#)
        request.write(field)
        request.raw(#","size":"#)
        request.write(limit)
        request.raw("}}}")
        let result = try aggregate(request.text, matching: query)

        struct TermsResult: Decodable {
            struct Buckets: Decodable {
                let buckets: [Bucket]
            }
            struct Bucket: Decodable {
                let key: AggregationKey
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
            return decoded.counts.buckets.map { FacetCount(value: $0.key.value, count: $0.docCount) }
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
        let raw: UnsafeMutablePointer<CChar>? =
            try query.jsonString().withCString { qC in
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
