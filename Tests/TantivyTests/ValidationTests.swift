import Foundation
import Testing
@testable import Tantivy

/// Regressions for inputs that previously panicked inside the engine
/// ("tantivy_ffi: internal panic"), were silently ignored, or were silently
/// truncated at the C-string boundary.
struct ValidationTests {

    private func corpus() throws -> Index {
        let index = try Index.inMemory(schema: SchemaBuilder()
            .addTextField("title", stored: true)
            .addU64Field("year", stored: true)
            .build())
        try index.add(contentsOf: [
            ["title": "dune", "year": 1965],
            ["title": "hyperion", "year": 1989],
        ])
        return index
    }

    /// A range with neither bound used to panic inside tantivy (the engine
    /// derives the range's field from a bound term); now it's a clean error.
    @Test func unboundedRangeThrowsCleanly() throws {
        let index = try corpus()
        #expect(throws: TantivyError.self) {
            try index.search(.range("year", from: nil, to: nil))
        }
        // Same guard on the delete-by-query path, where the stakes are higher.
        #expect(throws: TantivyError.self) {
            try index.delete(matching: .range("year", from: nil, to: nil))
        }
        #expect(try index.search(.matchAll).count == 2)  // nothing was deleted
    }

    /// A one-sided range is still fine.
    @Test func oneSidedRangeWorks() throws {
        let index = try corpus()
        #expect(try index.search(.range("year", from: .included(.int(1980)))).count == 1)
    }

    /// A negative minimum used to be dropped silently (matching *more* than
    /// asked); now it's rejected.
    @Test func negativeMinimumShouldMatchThrows() throws {
        let index = try corpus()
        let q = Query.anyOf([.term("title", "dune"), .term("title", "hyperion")],
                            minimumShouldMatch: -1)
        #expect(throws: TantivyError.self) { try index.search(q) }
    }

    /// A negative limit used to wrap to `usize::MAX` at the FFI boundary and
    /// panic in TopDocs' preallocation; same for snippetMaxChars.
    @Test func negativeLimitThrows() throws {
        let index = try corpus()
        #expect(throws: TantivyError.self) { try index.search("dune", limit: -1) }
        #expect(throws: TantivyError.self) { try index.search(.matchAll, limit: -1) }
        #expect(throws: TantivyError.self) { try index.search("dune", snippetMaxChars: -1) }
    }

    /// A huge (but non-negative) limit is legal: the engine caps it at the
    /// corpus size instead of preallocating for it.
    @Test func hugeLimitIsSafe() throws {
        let index = try corpus()
        #expect(try index.search("dune", limit: Int.max).count == 1)
        #expect(try index.search(.matchAll, limit: Int.max).count == 2)
    }

    /// Query strings travel as C strings; an interior NUL used to truncate the
    /// query silently (searching only "dune" here). Now it's rejected.
    @Test func interiorNulInQueryThrows() throws {
        let index = try corpus()
        #expect(throws: TantivyError.self) { try index.search("dune\0 OR hyperion") }
        #expect(throws: TantivyError.self) { try index.count("dune\0 OR hyperion") }
    }

    // MARK: - Interior NUL in *field names*

    /// Two fields where one name is a prefix of the other, so a NUL-truncated
    /// name resolves to a real — but different — field instead of erroring.
    private func prefixFieldCorpus() throws -> Index {
        let index = try Index.inMemory(schema: SchemaBuilder()
            .addStringField("title", stored: true, fast: true)
            .addStringField("titleSlug", stored: true, fast: true)
            .build())
        try index.add(contentsOf: [
            ["title": "red", "titleSlug": "red-slug"],
            ["title": "blue", "titleSlug": "blue-slug"],
        ])
        return index
    }

    /// The one with teeth: a NUL in the delete-by-term field name used to
    /// truncate `"title\0Slug"` to `"title"`, so a delete of
    /// `titleSlug == "red"` — which matches nothing — instead matched
    /// `title == "red"` and removed that document.
    @Test func interiorNulInDeleteFieldThrows() throws {
        let index = try prefixFieldCorpus()
        #expect(throws: TantivyError.self) {
            try index.write { try $0.deleteDocuments(field: "title\0Slug", equals: "red") }
        }
        #expect(index.documentCount == 2)  // nothing was deleted

        // The field actually named matches nothing, which is the behaviour the
        // truncated call was silently diverging from.
        try index.write { try $0.deleteDocuments(field: "titleSlug", equals: "red") }
        #expect(index.documentCount == 2)
    }

    /// `fields:` / `highlight:` / `orderBy:` names travel as a comma-separated
    /// C string, so a NUL truncated them to a different field — searching,
    /// highlighting, or sorting on something other than what was asked.
    @Test func interiorNulInFieldNamesThrows() throws {
        let index = try prefixFieldCorpus()
        #expect(throws: TantivyError.self) { try index.search("red", fields: ["title\0Slug"]) }
        #expect(throws: TantivyError.self) { try index.count("red", fields: ["title\0Slug"]) }
        #expect(throws: TantivyError.self) {
            try index.search("red", fields: ["title"], highlight: ["title\0Slug"])
        }
        #expect(throws: TantivyError.self) {
            try index.search("red", fields: ["title"], orderBy: .descending("title\0Slug"))
        }
        #expect(throws: TantivyError.self) {
            try index.search(.matchAll, highlight: ["title\0Slug"])
        }
        #expect(throws: TantivyError.self) {
            try index.search(.matchAll, orderBy: .descending("title\0Slug"))
        }
        #expect(throws: TantivyError.self) {
            try index.search("red", fields: ["title"], boosts: ["title\0Slug": 2.0])
        }
    }

    /// A comma inside a field name would split into two names at the same CSV
    /// boundary, widening the field set rather than truncating it.
    @Test func commaInFieldNameThrows() throws {
        let index = try prefixFieldCorpus()
        #expect(throws: TantivyError.self) {
            try index.search("red", fields: ["title,titleSlug"])
        }
    }

    /// The aggregation request is raw JSON crossing the same boundary: a NUL
    /// used to run whatever prefix still parsed and drop the rest silently.
    @Test func interiorNulInAggregationThrows() throws {
        let index = try prefixFieldCorpus()
        #expect(throws: TantivyError.self) {
            try index.aggregate("{\"a\":{\"terms\":{\"field\":\"title\"}}}\0trailing garbage")
        }
        #expect(throws: TantivyError.self) { try index.termCounts("title\0Slug") }
    }

    /// The structured `Query` tree JSON-escapes a NUL rather than truncating,
    /// so the engine rejects the field outright — no silent substitution.
    @Test func interiorNulInStructuredQueryIsRejectedByEngine() throws {
        let index = try prefixFieldCorpus()
        #expect(throws: TantivyError.self) { try index.count(.term("title\0Slug", "red")) }
        #expect(index.documentCount == 2)
    }

    // MARK: - Other unvalidated FFI-boundary integers

    /// A negative `heapSize` wrapped to a huge `usize` and surfaced as the
    /// engine's arena-cap error, which never mentioned the value passed.
    @Test func negativeHeapSizeThrowsCleanly() throws {
        let index = try corpus()
        let error = #expect(throws: TantivyError.self) { try index.writer(heapSize: -1) }
        #expect(error?.isEncoding == true)
    }

    /// A negative `termCounts` limit reached tantivy's aggregation parser as a
    /// bad `u32` and surfaced as an opaque serde message.
    @Test func negativeTermCountsLimitThrowsCleanly() throws {
        let index = try prefixFieldCorpus()
        let error = #expect(throws: TantivyError.self) { try index.termCounts("title", limit: -1) }
        #expect(error?.isEncoding == true)
    }
}
