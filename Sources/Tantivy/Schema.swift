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
    private var fields: [[String: Any]] = []

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
        fields.append([
            "name": name, "type": "text", "stored": stored, "indexed": indexed,
            "tokenizer": tokenizer.rawValue, "record": indexing.rawValue, "fast": fast,
        ])
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
        fields.append([
            "name": name, "type": "string", "stored": stored, "indexed": indexed, "fast": fast,
        ])
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
        fields.append([
            "name": name, "type": "date", "stored": stored, "indexed": indexed, "fast": fast,
        ])
        return self
    }

    @discardableResult
    private func addNumeric(
        _ name: String, _ type: String, _ stored: Bool, _ indexed: Bool, _ fast: Bool
    ) -> SchemaBuilder {
        fields.append([
            "name": name, "type": type, "stored": stored, "indexed": indexed, "fast": fast,
        ])
        return self
    }

    /// Finalize the schema.
    public func build() -> Schema {
        let spec: [String: Any] = ["fields": fields]
        let data = (try? JSONSerialization.data(withJSONObject: spec)) ?? Data("{\"fields\":[]}".utf8)
        return Schema(json: String(decoding: data, as: UTF8.self))
    }
}
