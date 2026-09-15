import Foundation
import CTantivy

/// One token an ``Analyzer`` made of a piece of text.
public struct Token: Decodable, Sendable, Equatable {
    /// The term as the index stores it (lowercased, stemmed, … per analyzer).
    public let text: String
    /// Position in the token stream. Analyzers that add a token alongside
    /// another (``Analyzer/englishKeepingSurface``) give both the same position.
    public let position: Int
    /// UTF-8 byte offset of the token's first byte in the analyzed text.
    public let offsetFrom: Int
    /// UTF-8 byte offset one past the token's last byte in the analyzed text.
    public let offsetTo: Int

    /// Build a token by hand — to add a synonym to an analyzed stream before
    /// passing it to ``Query/multiPhrase(_:tokens:slop:)``, for instance. Two
    /// tokens with the same `position` become alternatives there.
    public init(text: String, position: Int, offsetFrom: Int = 0, offsetTo: Int = 0) {
        self.text = text
        self.position = position
        self.offsetFrom = offsetFrom
        self.offsetTo = offsetTo
    }

    private enum CodingKeys: String, CodingKey {
        case text, position
        case offsetFrom = "offset_from"
        case offsetTo = "offset_to"
    }
}

extension Index {
    /// The tokens `analyzer` makes of `text` — what the index would store for it.
    ///
    /// Use it to build typed queries for analyzed fields instead of handing
    /// strings to the query parser:
    ///
    /// ```swift
    /// let terms = try index.analyze("Designers", with: .english).map(\.text)
    /// let hits = try index.search(.phrase("title", terms))
    /// ```
    public func analyze(_ text: String, with analyzer: Analyzer) throws(TantivyError) -> [Token] {
        try analyze(text, tokenizer: analyzer.rawValue)
    }

    /// By native tokenizer name, for names ``Analyzer`` cannot express.
    func analyze(_ text: String, tokenizer: String) throws(TantivyError) -> [Token] {
        try Self.validateNoInteriorNUL(text, "analyzed text")
        try Self.validateNoInteriorNUL(tokenizer, "tokenizer name")
        var err: UnsafeMutablePointer<CChar>?
        let raw = tokenizer.withCString { nameC in
            text.withCString { textC in
                tantivy_index_analyze(handle, nameC, textC, &err)
            }
        }
        guard let raw else {
            throw TantivyError.take(&err, fallback: "analyze failed")
        }
        defer { tantivy_string_free(raw) }
        let data = Data(bytes: raw, count: strlen(raw))
        do {
            return try JSONDecoder().decode([Token].self, from: data)
        } catch {
            throw TantivyError.encoding("could not decode tokens: \(error)")
        }
    }
}
