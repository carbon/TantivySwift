import Foundation

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
/// Safe to share for concurrent reads (it forwards to the underlying `Index`).
public final class SearchCollection<Model: Codable>: @unchecked Sendable {

    /// The underlying index, exposed for advanced use (custom queries, etc.).
    public let index: Index

    /// Wrap an existing index.
    public init(index: Index) {
        self.index = index
    }

    /// Open or create the collection's index at `path` (nil → in-memory).
    public convenience init(path: URL?, schema: Schema) throws {
        self.init(index: try Index(path: path, schema: schema))
    }

    /// Open or create the collection's index, building the schema inline.
    public convenience init(path: URL? = nil, _ buildSchema: (SchemaBuilder) -> Void) throws {
        let builder = SchemaBuilder()
        buildSchema(builder)
        self.init(index: try Index(path: path, schema: builder.build()))
    }

    /// An in-memory collection (not persisted).
    public static func inMemory(schema: Schema) throws -> SearchCollection {
        SearchCollection(index: try Index.inMemory(schema: schema))
    }

    // MARK: - Writing

    /// Add one model and make it searchable.
    public func add(_ value: Model) throws { try index.add(value) }

    /// Add many models in a single commit.
    public func add(contentsOf values: [Model]) throws { try index.add(contentsOf: values) }

    /// Replace any documents whose `idField` equals `id`, then add `value`
    /// (delete-by-term + add) in a single commit. Use a single-token id field.
    public func upsert(_ value: Model, idField: String, id: String) throws {
        try index.upsert(value, idField: idField, id: id)
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
        _ query: String, limit: Int = 10, fields: [String] = [], boosts: [String: Double] = [:]
    ) throws -> [Model] {
        try index.search(query, as: Model.self, limit: limit, fields: fields, boosts: boosts)
    }

    /// Search and return each match together with its relevance score.
    public func searchScored(
        _ query: String, limit: Int = 10, fields: [String] = [], boosts: [String: Double] = [:]
    ) throws -> [(score: Float, model: Model)] {
        try index.search(query, limit: limit, fields: fields, boosts: boosts)
            .map { (score: $0.score, model: try $0.decode(Model.self)) }
    }
}
