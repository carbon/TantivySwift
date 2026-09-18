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

    // MARK: - Recursion depth

    private func nested(_ depth: Int) -> String {
        String(repeating: "(", count: depth) + "dune" + String(repeating: ")", count: depth)
    }

    /// tantivy's query grammar recurses per group with no limit, so a deeply
    /// nested query string used to overflow the stack — a process crash the
    /// FFI panic guard cannot catch — and its backtracking doubles parse time
    /// per level on the way there. It is now rejected before parsing, on the
    /// string search, count, and `.parsed` paths alike.
    @Test func deeplyNestedQueryStringThrows() throws {
        let index = try corpus()
        #expect(try index.search(nested(12)).count == 1)
        #expect(try index.count(nested(12)) == 1)
        #expect(try index.search(.parsed(nested(12))).count == 1)

        for depth in [13, 100_000] {
            let error = #expect(throws: TantivyError.self) { try index.search(nested(depth)) }
            #expect(error?.message.contains("levels deep") == true)
            #expect(throws: TantivyError.self) { try index.count(nested(depth)) }
            #expect(throws: TantivyError.self) { try index.search(.parsed(nested(depth))) }
        }
    }

    /// A backslash-escaped paren is a literal, not a group.
    @Test func escapedParensDoNotCountAsNesting() throws {
        let index = try corpus()
        let escaped = String(repeating: "\\(", count: 100) + "dune"
        _ = try index.search(escaped)   // parses (matching nothing is fine)
    }

    /// The structured tree recurses too; a runaway `boost`/`boolean` nesting is
    /// reported as an encoding error at the depth the engine already refuses.
    /// (Releasing an `indirect` enum recurses inside Swift itself, so a tree
    /// hundreds of thousands of levels deep is still not survivable; the cap
    /// keeps this library's own recursion bounded and the error clear.)
    @Test func deeplyNestedQueryTreeThrows() throws {
        let index = try corpus()
        func tree(_ depth: Int) -> Query {
            var q: Query = .term("title", "dune")
            for _ in 0..<depth { q = q.excluding(.term("title", "zzz")) }
            return q
        }
        #expect(try index.search(tree(Query.maxNesting)).count == 1)
        let error = #expect(throws: TantivyError.self) { try index.search(tree(Query.maxNesting + 1)) }
        #expect(error?.isEncoding == true)
        #expect(throws: TantivyError.self) { try index.search(tree(1_000)) }
    }

    /// `&&` / `||` chains used to nest a boolean per operator, so a few dozen
    /// terms hit the engine's JSON recursion limit (and now the nesting cap).
    /// They flatten into one clause list instead.
    @Test func operatorChainsFlatten() throws {
        let index = try corpus()
        let a: Query = .term("title", "dune"), b: Query = .term("year", 1965)
        let c: Query = .term("title", "hyperion")

        if case .boolean(let must, let should, let mustNot, let minimum) = a && b && c {
            #expect(must.count == 3 && should.isEmpty && mustNot.isEmpty && minimum == nil)
        } else { Issue.record("&& chain is not a boolean") }
        if case .boolean(let must, let should, _, _) = a || b || c {
            #expect(should.count == 3 && must.isEmpty)
        } else { Issue.record("|| chain is not a boolean") }

        // Mixed operators keep their structure: `(a || b) && c` must not become
        // `a || b || c` or `a && b && c`.
        if case .boolean(let must, _, _, _) = (a || b) && c {
            #expect(must.count == 2)
            if case .boolean(_, let should, _, _) = must[0] { #expect(should.count == 2) }
            else { Issue.record("inner || was lost") }
        } else { Issue.record("mixed chain is not a boolean") }
        // A `should` with a minimum is a different query; it stays nested.
        let atLeastOne = Query.anyOf([a, c], minimumShouldMatch: 1)
        if case .boolean(_, let should, _, _) = atLeastOne || b { #expect(should.count == 2) }
        else { Issue.record("minimum-should-match boolean was merged") }
        // `excluding` yields must + mustNot, which is not pure either.
        if case .boolean(let must, _, _, _) = a.excluding(c) && b { #expect(must.count == 2) }
        else { Issue.record("excluding was merged") }

        // The point: a long chain runs, with the expected results.
        var all: Query = .term("title", "dune")
        var any: Query = .term("title", "nothing")
        for _ in 0..<200 {
            all = all && .range("year", 1900...2000)
            any = any || .term("title", "dune")
        }
        #expect(try index.search(all).count == 1)
        #expect(try index.search(any).count == 1)
        #expect(try index.search(a || b || c).count == 2)
    }

    // MARK: - Schema and document values

    /// tantivy's schema builder panics on a repeated field name, which surfaced
    /// only as "internal panic". Now it is a named error.
    @Test func duplicateFieldNameThrowsCleanly() throws {
        let schema = SchemaBuilder().addTextField("title").addU64Field("title").build()
        let error = #expect(throws: TantivyError.self) { try Index.inMemory(schema: schema) }
        #expect(error?.message.contains("duplicate field 'title'") == true)
    }

    /// An integer wider than 64 bits used to hit `Int64(_:)`, which traps on
    /// overflow instead of throwing.
    @Test func outOfRangeWideIntegerThrows() throws {
        let index = try corpus()
        let tooBig = Int128(Int64.max) + 1
        let error = #expect(throws: TantivyError.self) {
            try index.add(["title": "x", "year": tooBig] as [String: Any])
        }
        #expect(error?.isEncoding == true)
        #expect(throws: TantivyError.self) {
            try index.add(["title": "x", "year": UInt128(UInt64.max) + 1] as [String: Any])
        }
        // In range still works.
        try index.add(["title": "x", "year": Int128(2000)] as [String: Any])
        #expect(try index.count(.term("year", 2000)) == 1)
    }
}
