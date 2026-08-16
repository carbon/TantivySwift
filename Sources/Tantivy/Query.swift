import Foundation

/// A structured query that mirrors tantivy's own `Query` types. This is the
/// second search API: instead of a query *string* parsed by tantivy, you build a
/// query *tree* that maps directly onto `TermQuery`, `PhraseQuery`, `RangeQuery`,
/// `BooleanQuery`, `BoostQuery`, `FuzzyTermQuery`, and `AllQuery`. No escaping,
/// no parse step.
///
/// ```swift
/// let q: Query = .term("title", "dune") && .range("year", 1900...2000)
/// let hits = try index.search(q)
/// ```
///
/// Note: `term`/`phrase` match *indexed tokens* exactly (as tantivy does), so on
/// a tokenized text field pass already-analyzed tokens (e.g. lowercase for the
/// `default` tokenizer). For analyzed/parsed input, use the string `search`.
public enum Query: Sendable {
    case matchAll
    case parsed(query: String, fields: [String])
    case term(field: String, value: TermValue)
    case fuzzy(field: String, value: String, distance: UInt8, transposition: Bool, prefix: Bool)
    case regex(field: String, pattern: String)
    case wildcard(field: String, pattern: String)
    case exists(field: String)
    case moreLikeThis(fields: [String: [String]], options: MoreLikeThisOptions)
    case phrase(field: String, terms: [String], slop: UInt32)
    case phrasePrefix(field: String, terms: [String], maxExpansions: UInt32)
    case range(field: String, lower: RangeBound?, upper: RangeBound?)
    indirect case boost(Query, Float)
    indirect case boolean(must: [Query], should: [Query], mustNot: [Query], minimumShouldMatch: Int?)
}

/// Tuning knobs for ``Query/moreLikeThis(_:options:)`` (tantivy's MoreLikeThis,
/// modeled on Lucene's). Every value is optional; `nil` keeps tantivy's default.
///
/// The two that matter most on small corpora are ``minDocFrequency`` (default 5)
/// and ``minTermFrequency`` (default 2): a term is only used to find neighbours
/// if it appears in at least that many documents and that many times in the
/// source text. On a tiny index these defaults can filter out every term and
/// return nothing — lower them to `1` to see matches.
public struct MoreLikeThisOptions: Sendable, Equatable {
    /// Ignore source terms occurring in fewer than this many documents (default 5).
    public var minDocFrequency: UInt64?
    /// Ignore source terms occurring in more than this many documents.
    public var maxDocFrequency: UInt64?
    /// Ignore source terms appearing fewer than this many times in the input (default 2).
    public var minTermFrequency: Int?
    /// Cap the number of terms in the generated query (default 25).
    public var maxQueryTerms: Int?
    /// Ignore source words shorter than this.
    public var minWordLength: Int?
    /// Ignore source words longer than this.
    public var maxWordLength: Int?
    /// Multiply the per-term boosts the query assigns (default 1.0).
    public var boostFactor: Float?
    /// Words to exclude from the source text entirely.
    public var stopWords: [String]

    public init(
        minDocFrequency: UInt64? = nil, maxDocFrequency: UInt64? = nil,
        minTermFrequency: Int? = nil, maxQueryTerms: Int? = nil,
        minWordLength: Int? = nil, maxWordLength: Int? = nil,
        boostFactor: Float? = nil, stopWords: [String] = []
    ) {
        self.minDocFrequency = minDocFrequency
        self.maxDocFrequency = maxDocFrequency
        self.minTermFrequency = minTermFrequency
        self.maxQueryTerms = maxQueryTerms
        self.minWordLength = minWordLength
        self.maxWordLength = maxWordLength
        self.boostFactor = boostFactor
        self.stopWords = stopWords
    }

    /// tantivy's defaults (see the per-property notes).
    public static var `default`: MoreLikeThisOptions { .init() }
}

/// A typed value used in `term`/`range` clauses; serialized per the field's type.
public enum TermValue: Sendable {
    case string(String)
    case int(Int64)
    case unsigned(UInt64)
    case double(Double)
    case bool(Bool)
    case date(Date)
    /// A value for a `bytes` field. It is not serialized into the query JSON —
    /// it crosses as raw memory, with the JSON holding a reference to it.
    case bytes(Data)
}

/// One end of a `range`, inclusive or exclusive.
public struct RangeBound: Sendable {
    public let value: TermValue
    public let included: Bool
    public static func included(_ value: TermValue) -> RangeBound { .init(value: value, included: true) }
    public static func excluded(_ value: TermValue) -> RangeBound { .init(value: value, included: false) }
}

// MARK: - Ergonomic builders

extension Query {
    public static func term(_ field: String, _ value: String) -> Query { .term(field: field, value: .string(value)) }
    public static func term(_ field: String, _ value: Int) -> Query { .term(field: field, value: .int(Int64(value))) }
    public static func term(_ field: String, _ value: Int64) -> Query { .term(field: field, value: .int(value)) }
    public static func term(_ field: String, _ value: UInt64) -> Query { .term(field: field, value: .unsigned(value)) }
    public static func term(_ field: String, _ value: Bool) -> Query { .term(field: field, value: .bool(value)) }
    public static func term(_ field: String, _ value: Double) -> Query { .term(field: field, value: .double(value)) }
    public static func term(_ field: String, date value: Date) -> Query { .term(field: field, value: .date(value)) }

    /// Exact match on a `bytes` field: documents whose value for `field` is
    /// byte-for-byte `value`. The bytes are compared as stored — no analysis, no
    /// encoding — which makes this the lookup for a binary id or key.
    public static func term(_ field: String, _ value: Data) -> Query {
        .term(field: field, value: .bytes(value))
    }

    /// Embed a query *string* (tantivy query syntax, analyzed and parsed by the
    /// engine) as a node in a structured query — the bridge between the two
    /// search APIs. Use it to combine what the user typed with programmatic
    /// filters:
    ///
    /// ```swift
    /// let q: Query = .parsed("old man") && .term("tag", "book")
    /// ```
    ///
    /// Unlike `term`/`phrase`, the string goes through the field's analyzer, so
    /// raw user input works as-is. `fields` are the default fields searched when
    /// the string doesn't name one (empty → all indexed text fields).
    public static func parsed(_ query: String, fields: [String] = []) -> Query {
        .parsed(query: query, fields: fields)
    }

    public static func phrase(_ field: String, _ terms: [String], slop: UInt32 = 0) -> Query {
        .phrase(field: field, terms: terms, slop: slop)
    }

    /// Match a phrase whose *last* term is a prefix — multi-word typeahead
    /// (e.g. `["old", "ma"]` matches "old man"). The single-token counterpart is
    /// ``prefix(_:_:)``. Like `phrase`, terms match indexed tokens, and the
    /// field needs positions (`indexing: .position`, the default) when more
    /// than one term is given. `maxExpansions` caps how many distinct tokens
    /// the prefix may expand to.
    public static func phrasePrefix(_ field: String, _ terms: [String], maxExpansions: UInt32 = 50) -> Query {
        .phrasePrefix(field: field, terms: terms, maxExpansions: maxExpansions)
    }

    public static func fuzzy(
        _ field: String, _ value: String,
        distance: UInt8 = 1, transposition: Bool = true, prefix: Bool = false
    ) -> Query {
        .fuzzy(field: field, value: value, distance: distance, transposition: transposition, prefix: prefix)
    }

    /// Exact prefix match: documents whose indexed token in `field` *starts with*
    /// `value` (e.g. `"nor"` matches `"north"`, `"norway"`). The typeahead
    /// primitive. Matches indexed tokens, so on a tokenized field pass an
    /// already-analyzed prefix (e.g. lowercase for the `default` tokenizer).
    ///
    /// Backed by a zero-distance fuzzy-prefix query, so it is exact — no typos.
    /// For typo-tolerant typeahead use ``autocomplete(_:_:typoTolerance:)``.
    public static func prefix(_ field: String, _ value: String) -> Query {
        .fuzzy(field: field, value: value, distance: 0, transposition: false, prefix: true)
    }

    /// Typo-tolerant typeahead: a prefix match that also allows up to
    /// `typoTolerance` edits (Levenshtein, with transpositions) on the prefix.
    /// `typoTolerance: 0` is an exact prefix, identical to ``prefix(_:_:)``.
    public static func autocomplete(_ field: String, _ value: String, typoTolerance: UInt8 = 1) -> Query {
        .fuzzy(field: field, value: value, distance: typoTolerance, transposition: true, prefix: true)
    }

    /// Match documents whose indexed token in `field` matches the regular
    /// expression `pattern` (tantivy's `RegexQuery`; the pattern is implicitly
    /// anchored to the whole token). Matches indexed tokens, so on a tokenized
    /// field the pattern is tested against each analyzed token.
    public static func regex(_ field: String, _ pattern: String) -> Query {
        .regex(field: field, pattern: pattern)
    }

    /// Match documents whose indexed token in `field` fits a wildcard `pattern`,
    /// where `*` stands for any run of characters and every other character is
    /// literal (e.g. `"nor*"`, `"*way"`, `"n*way"`). Like ``regex(_:_:)`` it
    /// matches indexed tokens — a single token on a tokenized text field, the
    /// whole value on a `string` field — and the pattern spans the entire token.
    public static func wildcard(_ field: String, _ pattern: String) -> Query {
        .wildcard(field: field, pattern: pattern)
    }

    /// Match documents that have any non-null value in `field` — the "is this
    /// field set?" filter, and its negation (`.exists(f).excluding` /
    /// `anyOf(...).excluding(.exists(f))`) finds documents missing it.
    ///
    /// tantivy evaluates this over the field's fast column, so `field` must be
    /// declared `fast: true` in the schema.
    public static func exists(_ field: String) -> Query {
        .exists(field: field)
    }

    /// Find documents similar to the given text — the classic "related documents"
    /// / "more like this" query. `fields` maps each field to one or more source
    /// texts; tantivy analyzes them with that field's tokenizer, picks the most
    /// characteristic terms, and builds a weighted `should` query from them.
    ///
    /// ```swift
    /// let related = try index.search(.moreLikeThis(["body": [article.body]]), limit: 5)
    /// ```
    ///
    /// On small corpora tune ``MoreLikeThisOptions`` — the defaults
    /// (`minDocFrequency` 5, `minTermFrequency` 2) can match nothing. To find
    /// documents similar to one already indexed, see
    /// ``Index/moreLikeThis(idField:id:fields:options:limit:)``.
    ///
    /// > This query relies on relevance scoring, so it works only with `search`.
    /// > `count` and `delete(matching:)` run unscored and will throw on it.
    public static func moreLikeThis(
        _ fields: [String: [String]], options: MoreLikeThisOptions = .default
    ) -> Query {
        .moreLikeThis(fields: fields, options: options)
    }

    /// `moreLikeThis` from a single field and a single source text.
    public static func moreLikeThis(
        _ field: String, _ text: String, options: MoreLikeThisOptions = .default
    ) -> Query {
        .moreLikeThis(fields: [field: [text]], options: options)
    }

    /// Open/closed range from explicit bounds (omit a side for unbounded).
    public static func range(_ field: String, from lower: RangeBound? = nil, to upper: RangeBound? = nil) -> Query {
        .range(field: field, lower: lower, upper: upper)
    }
    public static func range(_ field: String, _ r: ClosedRange<Int>) -> Query {
        .range(field: field, lower: .included(.int(Int64(r.lowerBound))), upper: .included(.int(Int64(r.upperBound))))
    }
    public static func range(_ field: String, _ r: Range<Int>) -> Query {
        .range(field: field, lower: .included(.int(Int64(r.lowerBound))), upper: .excluded(.int(Int64(r.upperBound))))
    }
    public static func range(_ field: String, _ r: ClosedRange<Int64>) -> Query {
        .range(field: field, lower: .included(.int(r.lowerBound)), upper: .included(.int(r.upperBound)))
    }
    public static func range(_ field: String, _ r: Range<Int64>) -> Query {
        .range(field: field, lower: .included(.int(r.lowerBound)), upper: .excluded(.int(r.upperBound)))
    }
    public static func range(_ field: String, _ r: ClosedRange<Double>) -> Query {
        .range(field: field, lower: .included(.double(r.lowerBound)), upper: .included(.double(r.upperBound)))
    }
    public static func dateRange(_ field: String, from: Date? = nil, to: Date? = nil) -> Query {
        .range(field: field,
               lower: from.map { .included(.date($0)) },
               upper: to.map { .included(.date($0)) })
    }

    /// All sub-queries must match (a `Must` boolean).
    public static func allOf(_ queries: [Query]) -> Query {
        .boolean(must: queries, should: [], mustNot: [], minimumShouldMatch: nil)
    }
    /// Any sub-query may match (a `Should` boolean).
    public static func anyOf(_ queries: [Query], minimumShouldMatch: Int? = nil) -> Query {
        .boolean(must: [], should: queries, mustNot: [], minimumShouldMatch: minimumShouldMatch)
    }

    /// Weight this query by `factor`.
    public func boosted(by factor: Float) -> Query { .boost(self, factor) }
    /// This query, but excluding documents matching `other` (a `MustNot`).
    public func excluding(_ other: Query) -> Query {
        .boolean(must: [self], should: [], mustNot: [other], minimumShouldMatch: nil)
    }
}

/// `a && b` — both must match.
public func && (lhs: Query, rhs: Query) -> Query { .allOf([lhs, rhs]) }
/// `a || b` — either may match.
public func || (lhs: Query, rhs: Query) -> Query { .anyOf([lhs, rhs]) }

// MARK: - JSON serialization (wire format for the FFI)

extension TermValue {
    /// Write this value into a query tree. A `bytes` value becomes base64 —
    /// JSON has no byte type.
    fileprivate func write(into out: inout JSONWriter) {
        switch self {
        case .string(let s): out.write(s)
        case .int(let i): out.write(i)
        case .unsigned(let u): out.write(u)
        case .double(let d): out.write(d)
        case .bool(let b): out.write(b)
        case .bytes(let data): out.write(data)
        case .date(let date): out.write(TermValue.rfc3339(date))
        }
    }
    fileprivate static func rfc3339(_ date: Date) -> String {
        date.formatted(.iso8601)   // value-type ISO8601FormatStyle; second precision
    }
}

extension RangeBound {
    fileprivate func write(into out: inout JSONWriter) {
        out.raw("{\"value\":")
        value.write(into: &out)
        out.raw(",\"included\":")
        out.write(included)
        out.raw("}")
    }
}

extension Query {
    /// Write this node as JSON.
    ///
    /// Emitted straight from the enum rather than via an intermediate
    /// `[String: Any]`: every value's type is known at compile time here, so
    /// there is nothing to box and nothing that can fail to serialize.
    fileprivate func write(into out: inout JSONWriter) {
        /// `"key":value` for an optional, omitted when nil.
        func optional<T>(_ key: String, _ value: T?, _ emit: (T, inout JSONWriter) -> Void) {
            guard let value else { return }
            out.raw(",")
            out.write(key)
            out.raw(":")
            emit(value, &out)
        }

        switch self {
        case .matchAll:
            out.raw(#"{"type":"all"}"#)

        case .parsed(let query, let fields):
            out.raw(#"{"type":"parsed","query":"#)
            out.write(query)
            out.raw(#","fields":"#)
            out.write(fields)
            out.raw("}")

        case .term(let field, let value):
            out.raw(#"{"type":"term","field":"#)
            out.write(field)
            out.raw(#","value":"#)
            value.write(into: &out)
            out.raw("}")

        case .fuzzy(let field, let value, let distance, let transposition, let prefix):
            out.raw(#"{"type":"fuzzy","field":"#)
            out.write(field)
            out.raw(#","value":"#)
            out.write(value)
            out.raw(#","distance":"#)
            out.write(Int(distance))
            out.raw(#","transposition":"#)
            out.write(transposition)
            out.raw(#","prefix":"#)
            out.write(prefix)
            out.raw("}")

        case .regex(let field, let pattern):
            out.raw(#"{"type":"regex","field":"#)
            out.write(field)
            out.raw(#","value":"#)
            out.write(pattern)
            out.raw("}")

        case .wildcard(let field, let pattern):
            out.raw(#"{"type":"wildcard","field":"#)
            out.write(field)
            out.raw(#","value":"#)
            out.write(pattern)
            out.raw("}")

        case .exists(let field):
            out.raw(#"{"type":"exists","field":"#)
            out.write(field)
            out.raw("}")

        case .moreLikeThis(let fields, let options):
            out.raw(#"{"type":"more_like_this","fields":{"#)
            for (index, name) in fields.keys.sorted().enumerated() {
                if index > 0 { out.raw(",") }
                out.write(name)
                out.raw(":")
                out.write(fields[name]!)
            }
            out.raw("}")
            optional("min_doc_frequency", options.minDocFrequency) { $0 == nil ? () : $1.write($0) }
            optional("max_doc_frequency", options.maxDocFrequency) { $1.write($0) }
            optional("min_term_frequency", options.minTermFrequency) { $1.write($0) }
            optional("max_query_terms", options.maxQueryTerms) { $1.write($0) }
            optional("min_word_length", options.minWordLength) { $1.write($0) }
            optional("max_word_length", options.maxWordLength) { $1.write($0) }
            optional("boost_factor", options.boostFactor) { $1.write(Double($0)) }
            if !options.stopWords.isEmpty {
                optional("stop_words", options.stopWords) { $1.write($0) }
            }
            out.raw("}")

        case .phrase(let field, let terms, let slop):
            out.raw(#"{"type":"phrase","field":"#)
            out.write(field)
            out.raw(#","terms":"#)
            out.write(terms)
            out.raw(#","slop":"#)
            out.write(Int(slop))
            out.raw("}")

        case .phrasePrefix(let field, let terms, let maxExpansions):
            out.raw(#"{"type":"phrase_prefix","field":"#)
            out.write(field)
            out.raw(#","terms":"#)
            out.write(terms)
            out.raw(#","max_expansions":"#)
            out.write(Int(maxExpansions))
            out.raw("}")

        case .range(let field, let lower, let upper):
            out.raw(#"{"type":"range","field":"#)
            out.write(field)
            if let lower {
                out.raw(#","lower":"#)
                lower.write(into: &out)
            }
            if let upper {
                out.raw(#","upper":"#)
                upper.write(into: &out)
            }
            out.raw("}")

        case .boost(let query, let factor):
            out.raw(#"{"type":"boost","query":"#)
            query.write(into: &out)
            out.raw(#","boost":"#)
            out.write(Double(factor))
            out.raw("}")

        case .boolean(let must, let should, let mustNot, let minimum):
            out.raw(#"{"type":"boolean","clauses":["#)
            var first = true
            for (occur, queries) in [("must", must), ("should", should), ("must_not", mustNot)] {
                for query in queries {
                    if !first { out.raw(",") }
                    first = false
                    out.raw(#"{"occur":"#)
                    out.write(occur)
                    out.raw(#","query":"#)
                    query.write(into: &out)
                    out.raw("}")
                }
            }
            out.raw("]")
            optional("minimum_should_match", minimum) { $1.write($0) }
            out.raw("}")
        }
    }

    /// Reject malformed nodes before they reach the engine:
    ///  * non-finite `Double`/`Float` (NaN / ±∞) anywhere in the tree — JSON
    ///    cannot represent them, and emitting a bare `nan` would fail in the
    ///    engine's parser with a message that says nothing about which value
    ///    caused it. (When this went through `JSONSerialization` the stakes were
    ///    higher still: a non-finite value there raises an *uncatchable*
    ///    `NSException`.)
    ///  * a range with neither bound — tantivy derives the range's field from a
    ///    bound term, so a fully unbounded range panics inside the engine.
    ///  * a negative `minimumShouldMatch` — the FFI layer would reject it; a
    ///    minimum can't be satisfied by "fewer than zero" clauses.
    private func validate() throws(TantivyError) {
        func finite(_ v: TermValue) -> Bool {
            if case .double(let d) = v { return d.isFinite }
            return true
        }
        switch self {
        case .matchAll, .parsed, .fuzzy, .regex, .wildcard, .exists, .phrase, .phrasePrefix:
            break
        case .moreLikeThis(_, let options):
            if let b = options.boostFactor, !b.isFinite {
                throw .encoding("non-finite more_like_this boost factor")
            }
        case .term(_, let value):
            if !finite(value) { throw .encoding("non-finite number in term query") }
        case .range(let field, let lower, let upper):
            if lower == nil && upper == nil {
                throw .encoding("range on '\(field)' requires at least one bound")
            }
            if let l = lower, !finite(l.value) { throw .encoding("non-finite number in range bound") }
            if let u = upper, !finite(u.value) { throw .encoding("non-finite number in range bound") }
        case .boost(let query, let factor):
            if !factor.isFinite { throw .encoding("non-finite boost factor") }
            try query.validate()
        case .boolean(let must, let should, let mustNot, let minimum):
            if let minimum, minimum < 0 {
                throw .encoding("minimumShouldMatch must be non-negative (got \(minimum))")
            }
            for q in must { try q.validate() }
            for q in should { try q.validate() }
            for q in mustNot { try q.validate() }
        }
    }

    /// The JSON tree handed to the FFI. Validates first, then serializes —
    /// never silently degrades to a match-all query.
    func jsonString() throws(TantivyError) -> String {
        try validate()
        var out = JSONWriter()
        write(into: &out)
        return out.text
    }
}

// MARK: - More-like-this by document

extension Index {
    /// Find documents similar to the one whose `idField` equals `id` — "related
    /// documents". Reads the named stored `fields` from that document and runs a
    /// ``Query/moreLikeThis(_:options:)``, excluding the source document itself.
    /// Returns `[]` if no document has that id.
    ///
    /// ```swift
    /// let related = try index.moreLikeThis(idField: "slug", id: article.slug,
    ///                                      fields: ["title", "body"], limit: 5)
    /// ```
    ///
    /// The compared `fields` must be `stored` (only stored text is available to
    /// read back). `idField` should be a single-token field (a `string`/raw or
    /// numeric id) so the self-exclusion matches exactly.
    public func moreLikeThis(
        idField: String, id: String, fields: [String],
        options: MoreLikeThisOptions = .default, limit: Int = 10
    ) throws -> [SearchHit] {
        guard let source = try get(idField, equals: id) else { return [] }
        var like: [String: [String]] = [:]
        for field in fields {
            let strings: [String] = source[field].compactMap {
                if case .string(let s) = $0 { return s } else { return nil }
            }
            if !strings.isEmpty { like[field] = strings }
        }
        guard !like.isEmpty else { return [] }
        return try search(
            .moreLikeThis(like, options: options).excluding(.term(idField, id)), limit: limit)
    }
}

// MARK: - Typed structured search

extension Index {
    /// Run a structured ``Query`` and decode each hit into `T`.
    public func search<T: Decodable>(
        _ query: Query, as type: T.Type, limit: Int = 10, orderBy: OrderBy? = nil
    ) throws -> [T] {
        try search(query, limit: limit, orderBy: orderBy).map { try $0.decode(T.self) }
    }
}

extension SearchCollection {
    /// Run a structured ``Query`` and decode matches into `Model`.
    public func search(_ query: Query, limit: Int = 10, orderBy: Index.OrderBy? = nil) throws -> [Model] {
        try index.search(query, as: Model.self, limit: limit, orderBy: orderBy)
    }
    /// Structured ``Query`` with relevance scores.
    public func searchScored(_ query: Query, limit: Int = 10) throws -> [(score: Float, model: Model)] {
        try index.search(query, limit: limit).map { (score: $0.score, model: try $0.decode(Model.self)) }
    }
}
