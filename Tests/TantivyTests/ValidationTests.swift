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
}
