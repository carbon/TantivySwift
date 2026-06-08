import Foundation

/// A `Codable` model that carries its own index schema, so a `SearchCollection`
/// can be created without restating the schema at the call site.
///
/// ```swift
/// struct Book: IndexableDocument {
///     let title: String
///     let year: UInt64
///
///     static let searchSchema = SchemaBuilder()
///         .addTextField("title", stored: true)
///         .addU64Field("year", stored: true, fast: true)
///         .build()
/// }
///
/// let books = try SearchCollection<Book>(path: url)   // schema comes from Book
/// ```
///
/// The schema's field names must match the model's coding keys.
public protocol IndexableDocument: Codable {
    static var searchSchema: Schema { get }
}

extension SearchCollection where Model: IndexableDocument {
    /// Open or create the collection at `path` (nil → in-memory) using the
    /// model's `searchSchema`.
    public convenience init(path: URL? = nil) throws {
        self.init(index: try Index(path: path, schema: Model.searchSchema))
    }

    /// An in-memory collection using the model's `searchSchema`.
    public static func inMemory() throws -> SearchCollection {
        SearchCollection(index: try Index.inMemory(schema: Model.searchSchema))
    }
}
