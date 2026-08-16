import Foundation

/// An immutable index schema, produced by `SchemaBuilder`.
///
/// Internally this is the small JSON spec understood by the Rust layer; you
/// normally never touch `json` directly.
public struct Schema: Sendable {
    /// The JSON specification passed to the FFI layer.
    public let json: String
}

/// How an indexed text field records postings. Mirrors tantivy's
/// `IndexRecordOption`.
public enum TextIndexing: String, Sendable {
    /// Doc ids only — enough for boolean matching.
    case basic
    /// Doc ids + term frequencies (better scoring).
    case freq
    /// Doc ids + frequencies + positions (required for phrase queries).
    case position
}

/// A text tokenizer/analyzer, mirroring exactly the set registered by the native
/// (tantivy + this library's) layer. The `rawValue` is the on-the-wire name. The
/// `AnalyzerRegistrationTests` drift-guard verifies every case is actually
/// registered natively.
public enum Analyzer: String, Sendable, CaseIterable {
    /// Lowercased, split on non-alphanumeric, unstemmed (tantivy `default`).
    case `default` = "default"
    /// The whole value as one token, **case-sensitive** (tantivy `raw`).
    case raw = "raw"
    /// Split on whitespace only (tantivy `whitespace`).
    case whitespace = "whitespace"
    /// Lowercased + English stemming (tantivy `en_stem`).
    case english = "en_stem"
    /// The whole value as one **lowercased** token — case-insensitive exact
    /// match for tags, authors, enums, ids. (Formerly named `tag`; the `tag`
    /// tokenizer remains registered natively so older indexes still open.)
    case lowercase = "lowercase"
}

/// Fluent builder for an index `Schema`.
///
/// ```swift
/// let schema = SchemaBuilder()
///     .addTextField("title", stored: true)
///     .addTextField("body")
///     .addU64Field("id", stored: true, fast: true)
///     .build()
/// ```
public final class SchemaBuilder {
    /// One field's specification.
    ///
    /// Typed rather than a `[String: Any]` so `build()` cannot fail: there is no
    /// value here that a serializer could reject, which is what let the previous
    /// implementation fall back to an *empty* schema on error. That fallback was
    /// unreachable in practice, but it turned a serialization problem into
    /// "unknown field" errors at every later `addDocument`, arbitrarily far from
    /// the cause.
    private struct FieldSpec {
        let name: String
        let type: String
        let stored: Bool
        let indexed: Bool
        let fast: Bool
        /// Text fields only; nil elsewhere.
        var tokenizer: String?
        var record: String?

        func write(into out: inout JSONWriter) {
            out.raw(#"{"name":"#)
            out.write(name)
            out.raw(#","type":"#)
            out.write(type)
            out.raw(#","stored":"#)
            out.write(stored)
            out.raw(#","indexed":"#)
            out.write(indexed)
            out.raw(#","fast":"#)
            out.write(fast)
            if let tokenizer {
                out.raw(#","tokenizer":"#)
                out.write(tokenizer)
            }
            if let record {
                out.raw(#","record":"#)
                out.write(record)
            }
            out.raw("}")
        }
    }

    private var fields: [FieldSpec] = []

    public init() {}

    /// Add a tokenized, full-text field.
    /// - Parameters:
    ///   - name: field name (used as the JSON key when adding documents).
    ///   - stored: keep the original value so it can be returned in search hits.
    ///   - indexed: make the field searchable.
    ///   - tokenizer: the `Analyzer` to apply (default `.default`).
    ///   - indexing: what to record in the postings (positions enable phrase queries).
    ///   - fast: also store as a columnar fast field.
    @discardableResult
    public func addTextField(
        _ name: String,
        stored: Bool = false,
        indexed: Bool = true,
        tokenizer: Analyzer = .default,
        indexing: TextIndexing = .position,
        fast: Bool = false
    ) -> SchemaBuilder {
        fields.append(FieldSpec(
            name: name, type: "text", stored: stored, indexed: indexed, fast: fast,
            tokenizer: tokenizer.rawValue, record: indexing.rawValue))
        return self
    }

    /// Add a non-tokenized string field (single raw token) for exact matching,
    /// e.g. ids, tags, enum values.
    @discardableResult
    public func addStringField(
        _ name: String,
        stored: Bool = false,
        indexed: Bool = true,
        fast: Bool = false
    ) -> SchemaBuilder {
        fields.append(FieldSpec(
            name: name, type: "string", stored: stored, indexed: indexed, fast: fast))
        return self
    }

    @discardableResult
    public func addU64Field(
        _ name: String, stored: Bool = false, indexed: Bool = true, fast: Bool = false
    ) -> SchemaBuilder {
        addNumeric(name, "u64", stored, indexed, fast)
    }

    @discardableResult
    public func addI64Field(
        _ name: String, stored: Bool = false, indexed: Bool = true, fast: Bool = false
    ) -> SchemaBuilder {
        addNumeric(name, "i64", stored, indexed, fast)
    }

    @discardableResult
    public func addF64Field(
        _ name: String, stored: Bool = false, indexed: Bool = true, fast: Bool = false
    ) -> SchemaBuilder {
        addNumeric(name, "f64", stored, indexed, fast)
    }

    @discardableResult
    public func addBoolField(
        _ name: String, stored: Bool = false, indexed: Bool = true, fast: Bool = false
    ) -> SchemaBuilder {
        addNumeric(name, "bool", stored, indexed, fast)
    }

    /// Add a date/time field. Values are exchanged as RFC3339 strings; through
    /// the `Encodable` / typed-decode paths a Swift `Date` round-trips at second
    /// precision. Query with RFC3339 ranges, e.g. `created:[2020-01-01T00:00:00Z
    /// TO 2020-12-31T23:59:59Z]`.
    @discardableResult
    public func addDateField(
        _ name: String, stored: Bool = false, indexed: Bool = true, fast: Bool = false
    ) -> SchemaBuilder {
        fields.append(FieldSpec(
            name: name, type: "date", stored: stored, indexed: indexed, fast: fast))
        return self
    }

    /// Add an opaque byte-string field — the byte-array analogue of
    /// ``addStringField(_:stored:indexed:fast:)``, and the type to use for a
    /// binary id or key (a UUID, a hash, a packed struct).
    ///
    /// Indexed, the whole value is a single term matched byte-for-byte, so
    /// ``Query/term(_:_:)-(_,Data)`` and
    /// ``IndexWriter/deleteDocuments(field:equals:)-(_,Data)`` do exact lookups
    /// and upserts on it. Values carry any bytes at all — NULs, invalid UTF-8 —
    /// and cross to the engine as raw memory rather than being base64-encoded.
    ///
    /// ```swift
    /// let schema = SchemaBuilder()
    ///     .addBytesField("key", stored: true, indexed: true)
    ///     .addTextField("body")
    ///     .build()
    /// ```
    ///
    /// > Byte fields are not reachable from the query-string API (there is no
    /// > way to write arbitrary bytes in a query string) — use the structured
    /// > ``Query`` API.
    @discardableResult
    public func addBytesField(
        _ name: String,
        stored: Bool = false,
        indexed: Bool = true,
        fast: Bool = false
    ) -> SchemaBuilder {
        fields.append(FieldSpec(
            name: name, type: "bytes", stored: stored, indexed: indexed, fast: fast))
        return self
    }

    @discardableResult
    private func addNumeric(
        _ name: String, _ type: String, _ stored: Bool, _ indexed: Bool, _ fast: Bool
    ) -> SchemaBuilder {
        fields.append(FieldSpec(
            name: name, type: type, stored: stored, indexed: indexed, fast: fast))
        return self
    }

    /// Finalize the schema. Cannot fail — see ``FieldSpec``.
    public func build() -> Schema {
        var out = JSONWriter(reservingCapacity: 64 * max(fields.count, 1))
        out.raw(#"{"fields":["#)
        for (index, field) in fields.enumerated() {
            if index > 0 { out.raw(",") }
            field.write(into: &out)
        }
        out.raw("]}")
        return Schema(json: out.text)
    }
}
