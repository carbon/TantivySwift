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
    case term(field: String, value: TermValue)
    case fuzzy(field: String, value: String, distance: UInt8, transposition: Bool, prefix: Bool)
    case phrase(field: String, terms: [String], slop: UInt32)
    case range(field: String, lower: RangeBound?, upper: RangeBound?)
    indirect case boost(Query, Float)
    indirect case boolean(must: [Query], should: [Query], mustNot: [Query], minimumShouldMatch: Int?)
}

/// A typed value used in `term`/`range` clauses; serialized per the field's type.
public enum TermValue: Sendable {
    case string(String)
    case int(Int64)
    case unsigned(UInt64)
    case double(Double)
    case bool(Bool)
    case date(Date)
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

    public static func phrase(_ field: String, _ terms: [String], slop: UInt32 = 0) -> Query {
        .phrase(field: field, terms: terms, slop: slop)
    }

    public static func fuzzy(
        _ field: String, _ value: String,
        distance: UInt8 = 1, transposition: Bool = true, prefix: Bool = false
    ) -> Query {
        .fuzzy(field: field, value: value, distance: distance, transposition: transposition, prefix: prefix)
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
    fileprivate func jsonValue() -> Any {
        switch self {
        case .string(let s): return s
        case .int(let i): return i
        case .unsigned(let u): return u
        case .double(let d): return d
        case .bool(let b): return b
        case .date(let date): return TermValue.rfc3339(date)
        }
    }
    fileprivate static func rfc3339(_ date: Date) -> String {
        date.formatted(.iso8601)   // value-type ISO8601FormatStyle; second precision
    }
}

extension RangeBound {
    fileprivate func jsonObject() -> [String: Any] {
        ["value": value.jsonValue(), "included": included]
    }
}

extension Query {
    fileprivate func jsonObject() -> [String: Any] {
        switch self {
        case .matchAll:
            return ["type": "all"]
        case .term(let field, let value):
            return ["type": "term", "field": field, "value": value.jsonValue()]
        case .fuzzy(let field, let value, let distance, let transposition, let prefix):
            return ["type": "fuzzy", "field": field, "value": value,
                    "distance": Int(distance), "transposition": transposition, "prefix": prefix]
        case .phrase(let field, let terms, let slop):
            return ["type": "phrase", "field": field, "terms": terms, "slop": Int(slop)]
        case .range(let field, let lower, let upper):
            var node: [String: Any] = ["type": "range", "field": field]
            if let lower { node["lower"] = lower.jsonObject() }
            if let upper { node["upper"] = upper.jsonObject() }
            return node
        case .boost(let query, let factor):
            return ["type": "boost", "query": query.jsonObject(), "boost": Double(factor)]
        case .boolean(let must, let should, let mustNot, let minimum):
            var clauses: [[String: Any]] = []
            clauses += must.map { ["occur": "must", "query": $0.jsonObject()] }
            clauses += should.map { ["occur": "should", "query": $0.jsonObject()] }
            clauses += mustNot.map { ["occur": "must_not", "query": $0.jsonObject()] }
            var node: [String: Any] = ["type": "boolean", "clauses": clauses]
            if let minimum { node["minimum_should_match"] = minimum }
            return node
        }
    }

    /// The JSON tree handed to the FFI.
    func jsonString() -> String {
        let data = (try? JSONSerialization.data(withJSONObject: jsonObject()))
            ?? Data(#"{"type":"all"}"#.utf8)
        return String(decoding: data, as: UTF8.self)
    }
}

// MARK: - Typed structured search

extension Index {
    /// Run a structured ``Query`` and decode each hit into `T`.
    public func search<T: Decodable>(_ query: Query, as type: T.Type, limit: Int = 10) throws -> [T] {
        try search(query, limit: limit).map { try $0.decode(T.self) }
    }
}

extension SearchCollection {
    /// Run a structured ``Query`` and decode matches into `Model`.
    public func search(_ query: Query, limit: Int = 10) throws -> [Model] {
        try index.search(query, as: Model.self, limit: limit)
    }
    /// Structured ``Query`` with relevance scores.
    public func searchScored(_ query: Query, limit: Int = 10) throws -> [(score: Float, model: Model)] {
        try index.search(query, limit: limit).map { (score: $0.score, model: try $0.decode(Model.self)) }
    }
}
