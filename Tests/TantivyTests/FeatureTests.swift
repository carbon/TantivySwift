import Foundation
import Testing
@testable import Tantivy

/// Coverage for dates, per-field boosts, named analyzers, and delete-by-term.
struct FeatureTests {

    // MARK: - Date fields

    @Test func dateRangeQueryViaRFC3339Strings() throws {
        let schema = SchemaBuilder()
            .addTextField("title", stored: true)
            .addDateField("created", stored: true, indexed: true, fast: true)
            .build()
        let index = try Index.inMemory(schema: schema)
        try index.add(contentsOf: [
            ["title": "old", "created": "2020-01-01T00:00:00Z"],
            ["title": "new", "created": "2021-06-15T12:00:00Z"],
        ])

        let hits = try index.search("created:[2020-06-01T00:00:00Z TO 2022-01-01T00:00:00Z]")
        #expect(hits.compactMap { $0.string("title") } == ["new"])
    }

    @Test func dateRoundTripsThroughEncodableAndTypedDecode() throws {
        struct Event: Codable, Equatable { let title: String; let at: Date }
        let schema = SchemaBuilder()
            .addTextField("title", stored: true)
            .addDateField("at", stored: true, indexed: true)
            .build()
        let index = try Index.inMemory(schema: schema)

        let when = Date(timeIntervalSince1970: 1_600_000_000)   // whole seconds
        try index.add(Event(title: "launch", at: when))

        let got = try #require(try index.search("title:launch", as: Event.self).first)
        #expect(got.title == "launch")
        #expect(got.at == when)        // second-precision round-trip
    }

    /// A `Date` carrying a fraction of a second is *truncated* (not rounded) on
    /// the way in, which is the documented second precision. Pinned because it
    /// is silently lossy: the value read back is not the value written.
    @Test func subSecondDatesAreTruncatedNotRounded() throws {
        struct Event: Codable { let at: Date }
        let index = try Index.inMemory(schema: SchemaBuilder()
            .addDateField("at", stored: true, indexed: true, fast: true).build())

        let whole = 1_600_000_000.0
        try index.add(Event(at: Date(timeIntervalSince1970: whole + 0.999)))
        let got = try #require(try index.search(.matchAll, as: Event.self, limit: 1).first)
        #expect(got.at.timeIntervalSince1970 == whole)          // truncated, not 1_600_000_001
        #expect(try index.search(.matchAll, limit: 1)[0].string("at") == "2020-09-13T12:26:40Z")
    }

    /// Terms built from a `Date` are truncated the same way, so a query date
    /// still matches a document stored with sub-second precision through the
    /// raw-JSON path — the two sides agree on second granularity.
    @Test func dateTermsMatchAcrossSubSecondPrecision() throws {
        let index = try Index.inMemory(schema: SchemaBuilder()
            .addDateField("at", stored: true, indexed: true, fast: true).build())
        try index.add(["at": "2020-09-13T12:26:40.750Z"])       // sub-second, raw JSON

        let queried = Date(timeIntervalSince1970: 1_600_000_000.25)
        #expect(try index.count(.term("at", date: queried)) == 1)
        #expect(try index.count(.dateRange("at", from: queried, to: queried)) == 1)
        // The stored value keeps its precision even though the term is coarser.
        #expect(try index.search(.matchAll, limit: 1)[0].string("at") == "2020-09-13T12:26:40.75Z")
    }

    // MARK: - Per-field boosts

    @Test func fieldBoostsChangeRanking() throws {
        let schema = SchemaBuilder()
            .addTextField("title", stored: true)
            .addTextField("body", stored: true)
            .build()
        let index = try Index.inMemory(schema: schema)
        try index.add(contentsOf: [
            ["title": "x", "body": "filler"],      // term in title
            ["title": "filler", "body": "x"],      // term in body
        ])

        // Boost title -> the title match ranks first.
        let byTitle = try index.search("x", boosts: ["title": 10.0])
        #expect(byTitle.count == 2)
        #expect(byTitle.first?.string("title") == "x")

        // Boost body -> the body match (whose title is "filler") ranks first.
        let byBody = try index.search("x", boosts: ["body": 10.0])
        #expect(byBody.first?.string("title") == "filler")
    }

    // MARK: - Named analyzers

    @Test func lowercaseAnalyzerIsLowercasedSingleToken() throws {
        let schema = SchemaBuilder()
            .addTextField("tags", stored: true, tokenizer: .lowercase)
            .build()
        let index = try Index.inMemory(schema: schema)
        try index.add(["tags": ["Property", "House Rental"]])

        #expect(try index.search("tags:property").count == 1)        // lowercased
        #expect(try index.search("tags:Property").count == 1)        // query also lowercased
        #expect(try index.search("tags:\"house rental\"").count == 1) // whole value, one token
        #expect(try index.search("tags:house").count == 0)           // not split on space
    }

    @Test func enAnalyzerStemsLikeEnStem() throws {
        let schema = SchemaBuilder()
            .addTextField("body", stored: true, tokenizer: .english)
            .build()
        let index = try Index.inMemory(schema: schema)
        try index.add(["body": "running jumps"])

        #expect(try index.search("body:run").count == 1)    // running -> run
        #expect(try index.search("body:jump").count == 1)   // jumps -> jump
    }

    // MARK: - Delete by term / upsert

    private func idIndex() throws -> Index {
        try Index.inMemory(schema: SchemaBuilder()
            .addStringField("id", stored: true)
            .addTextField("title", stored: true)
            .build())
    }

    @Test func upsertReplacesByIdInsteadOfDuplicating() throws {
        let index = try idIndex()
        try index.add(["id": "a", "title": "first"])
        #expect(index.documentCount == 1)

        try index.upsert(["id": "a", "title": "second"], idField: "id", id: "a")
        #expect(index.documentCount == 1)                       // replaced, not added
        #expect(try index.search("title:second").count == 1)
        #expect(try index.search("title:first").isEmpty)
    }

    @Test func upsertOfNewIdJustAdds() throws {
        let index = try idIndex()
        try index.upsert(["id": "b", "title": "brand new"], idField: "id", id: "b")
        #expect(index.documentCount == 1)
        #expect(try index.search("title:brand").count == 1)
    }

    @Test func deleteDocumentsByStringTerm() throws {
        let index = try idIndex()
        try index.add(contentsOf: [["id": "a", "title": "x"], ["id": "b", "title": "y"]])
        try index.write { try $0.deleteDocuments(field: "id", equals: "a") }
        #expect(index.documentCount == 1)
        #expect(try index.search("title:y").count == 1)
        #expect(try index.search("title:x").isEmpty)
    }

    @Test func deleteDocumentsByNumericTerm() throws {
        let schema = SchemaBuilder()
            .addU64Field("uid", stored: true, indexed: true)
            .addTextField("title", stored: true)
            .build()
        let index = try Index.inMemory(schema: schema)
        try index.add(contentsOf: [["uid": 7, "title": "seven"], ["uid": 9, "title": "nine"]])
        try index.write { try $0.deleteDocuments(field: "uid", equals: UInt64(7)) }
        #expect(index.documentCount == 1)
        #expect(try index.search("title:nine").count == 1)
    }

    @Test func deleteTermOnMissingFieldThrows() throws {
        let index = try idIndex()
        try index.add(["id": "a", "title": "x"])
        #expect(throws: TantivyError.self) {
            try index.write { try $0.deleteDocuments(field: "ghost", equals: "a") }
        }
    }
}
