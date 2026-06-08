/// Derives `IndexableDocument` (a `searchSchema`) from a struct's `@Field`-marked
/// stored properties — field names come from the property names, types are
/// inferred. The struct must also declare `Codable`.
///
/// ```swift
/// @Indexable
/// struct Book: Codable {
///     @Field(stored: true, analyzer: .english) var title: String
///     @Field(stored: true, fast: true) var year: UInt64
///     @Field(stored: true) var tags: [String]
/// }
///
/// let books = try SearchCollection<Book>()   // schema derived by the macro
/// ```
///
/// Supported property types: `String`, numeric (`Int`/`Int64`/`UInt64`/`Double`/
/// `…`), `Bool`, `Date`, and arrays/optionals of those.
@attached(extension, conformances: IndexableDocument, names: named(searchSchema))
public macro Indexable() =
    #externalMacro(module: "TantivyMacrosPlugin", type: "IndexableMacro")

/// Marks a stored property for inclusion in the `@Indexable`-derived schema.
@attached(peer)
public macro Field(
    stored: Bool = true,
    indexed: Bool = true,
    fast: Bool = false,
    analyzer: Analyzer = .default
) = #externalMacro(module: "TantivyMacrosPlugin", type: "FieldMacro")
