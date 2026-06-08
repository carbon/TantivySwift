import Testing
@testable import Tantivy

/// Coverage for the convenience helpers: `write {}`, `add`, and typed search.
struct HelpersTests {

    struct Doc: Codable, Equatable {
        let title: String
        let year: UInt64
        let rating: Double
        let active: Bool
        let tags: [String]
        let note: String?
    }

    private func docSchema() -> Schema {
        SchemaBuilder()
            .addTextField("title", stored: true)
            .addU64Field("year", stored: true)
            .addF64Field("rating", stored: true)
            .addBoolField("active", stored: true)
            .addStringField("tags", stored: true)
            .addTextField("note", stored: true)
            .build()
    }

    // MARK: - write {}

    @Test func writeCommitsAndMakesSearchable() throws {
        let index = try Index.inMemory(schema: docSchema())
        try index.write { w in
            try w.addDocument(["title": "Dune", "year": 1965, "rating": 4.5, "active": true, "tags": ["sci-fi"]])
        }
        #expect(index.documentCount == 1)
        #expect(try index.search("title:Dune").count == 1)
    }

    @Test func writeRollsBackOnThrow() throws {
        struct Boom: Error {}
        let index = try Index.inMemory(schema: docSchema())
        #expect(throws: Boom.self) {
            try index.write { w in
                try w.addDocument(["title": "Ghost", "year": 1, "rating": 1.0, "active": false, "tags": ["x"]])
                throw Boom()
            }
        }
        #expect(index.documentCount == 0)            // never committed
        #expect(try index.search("title:Ghost").isEmpty)
    }

    @Test func writeReturnsBodyValue() throws {
        let index = try Index.inMemory(schema: docSchema())
        let added = try index.write { w -> Int in
            try w.addDocument(["title": "A", "year": 1, "rating": 1.0, "active": true, "tags": []])
            try w.addDocument(["title": "B", "year": 2, "rating": 1.0, "active": true, "tags": []])
            return 2
        }
        #expect(added == 2)
        #expect(index.documentCount == 2)
    }

    // MARK: - add

    @Test func addDictSingularAndBatch() throws {
        let index = try Index.inMemory(schema: docSchema())
        try index.add(["title": "Solo", "year": 1, "rating": 1.0, "active": true, "tags": ["a"]])
        #expect(index.documentCount == 1)
        try index.add(contentsOf: [
            ["title": "Two", "year": 2, "rating": 1.0, "active": true, "tags": ["a"]],
            ["title": "Three", "year": 3, "rating": 1.0, "active": true, "tags": ["a"]],
        ])
        #expect(index.documentCount == 3)
    }

    @Test func addEncodableSingularAndBatch() throws {
        let index = try Index.inMemory(schema: docSchema())
        try index.add(Doc(title: "One", year: 1, rating: 1, active: true, tags: ["a"], note: nil))
        try index.add(contentsOf: [
            Doc(title: "Two", year: 2, rating: 1, active: true, tags: ["a"], note: nil),
            Doc(title: "Three", year: 3, rating: 1, active: true, tags: ["a"], note: nil),
        ])
        #expect(index.documentCount == 3)
    }

    // MARK: - typed search

    @Test func typedSearchDecodesFullModel() throws {
        let index = try Index.inMemory(schema: docSchema())
        try index.add(contentsOf: [
            Doc(title: "Dune", year: 1965, rating: 4.5, active: true, tags: ["sci-fi", "classic"], note: "great"),
            Doc(title: "Foundation", year: 1951, rating: 4.0, active: false, tags: ["sci-fi"], note: nil),
        ])

        let dune = try #require(try index.search("title:Dune", as: Doc.self).first)
        #expect(dune == Doc(title: "Dune", year: 1965, rating: 4.5, active: true,
                            tags: ["sci-fi", "classic"], note: "great"))
    }

    @Test func typedSearchHandlesSingleElementArraysAndMissingOptionals() throws {
        let index = try Index.inMemory(schema: docSchema())
        try index.add(Doc(title: "Foundation", year: 1951, rating: 4.0, active: false,
                          tags: ["sci-fi"], note: nil))
        let doc = try #require(try index.search("title:Foundation", as: Doc.self).first)
        #expect(doc.tags == ["sci-fi"])  // single-element multi-valued field
        #expect(doc.note == nil)         // optional, field absent
        #expect(doc.active == false)
    }

    @Test func typedSearchEmptyResult() throws {
        let index = try Index.inMemory(schema: docSchema())
        #expect(try index.search("nothing", as: Doc.self).isEmpty)
    }

    @Test func typedSearchThrowsOnTypeMismatch() throws {
        struct WrongTitle: Codable { let title: Int }  // title is text, not numeric
        let index = try Index.inMemory(schema: docSchema())
        try index.add(Doc(title: "Dune", year: 1965, rating: 4.5, active: true, tags: ["a"], note: nil))
        #expect(throws: DecodingError.self) {
            try index.search("title:Dune", as: WrongTitle.self)
        }
    }

    @Test func typedSearchRespectsStoredVsOptional() throws {
        // body is indexed but NOT stored.
        let schema = SchemaBuilder()
            .addTextField("title", stored: true)
            .addTextField("body", stored: false)
            .build()
        let index = try Index.inMemory(schema: schema)
        try index.add(["title": "x", "body": "hidden"])

        struct NeedsBody: Codable { let title: String; let body: String }
        #expect(throws: DecodingError.self) {
            try index.search("title:x", as: NeedsBody.self)  // body not stored -> not decodable
        }

        struct OptBody: Codable { let title: String; let body: String? }
        let r = try #require(try index.search("title:x", as: OptBody.self).first)
        #expect(r.title == "x")
        #expect(r.body == nil)
    }
}
