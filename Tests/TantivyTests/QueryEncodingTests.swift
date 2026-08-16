import Foundation
import Testing
@testable import Tantivy

/// Coverage for the query wire format.
///
/// Query trees are written straight from the `Query` enum by ``JSONWriter``
/// rather than handed to `JSONSerialization`, so nothing validates the output
/// for us. A missed escape would produce a payload the engine rejects with an
/// opaque parse error — or worse, one that parses into a *different* query. The
/// first two tests are the guard against that.
struct QueryEncodingTests {

    /// Every node shape must produce JSON that a real parser accepts.
    @Test func everyNodeShapeEmitsValidJSON() throws {
        let queries: [Query] = [
            .matchAll,
            .parsed("old man", fields: ["title", "body"]),
            .term("tag", "book"),
            .term("n", Int64(-7)),
            .term("u", UInt64.max),
            .term("f", 2.5),
            .term("b", true),
            .term("key", Data([0x00, 0xFF])),
            .term("created", date: Date(timeIntervalSince1970: 1_000_000)),
            .fuzzy("title", "seaa", distance: 2, transposition: false, prefix: true),
            .regex("tag", "boo.*"),
            .wildcard("tag", "boo*"),
            .exists("year"),
            .moreLikeThis(["body": ["text one", "text two"]], options: .init(
                minDocFrequency: 1, maxDocFrequency: 100, minTermFrequency: 1,
                maxQueryTerms: 5, minWordLength: 2, maxWordLength: 20,
                boostFactor: 1.5, stopWords: ["the", "a"])),
            .phrase("body", ["old", "man"], slop: 2),
            .phrasePrefix("body", ["old", "ma"], maxExpansions: 10),
            .range("year", 1900...2000),
            .range(field: "year", lower: .excluded(.int(1900)), upper: nil),
            .term("t", "x").boosted(by: 2.5),
            (.term("a", "1") && .term("b", "2")).excluding(.term("c", "3")),
            .anyOf([.term("a", "1"), .term("b", "2")], minimumShouldMatch: 2),
        ]

        for query in queries {
            let json = try query.jsonString()
            #expect(throws: Never.self, "invalid JSON for \(query): \(json)") {
                try JSONSerialization.jsonObject(with: Data(json.utf8))
            }
        }
    }

    /// Strings that need escaping must survive into the engine and match the
    /// document they came from — not merely produce parseable JSON.
    @Test func awkwardStringsSurviveEncodingAndMatch() throws {
        let values = [
            #"quote " inside"#,
            #"backslash \ inside"#,
            "newline \n inside",
            "tab \t inside",
            "carriage \r return",
            "control \u{01}\u{1F} chars",
            "unicode é 🙂 中文",
            "slash / inside",
        ]
        let schema = SchemaBuilder().addStringField("s", stored: true).build()
        let index = try Index.inMemory(schema: schema)
        let w = try index.writer()
        for value in values {
            var doc = Document()
            doc["s"] = .string(value)
            try w.addDocument(doc)
        }
        try w.commitAndReload()

        for value in values {
            let json = try Query.term("s", value).jsonString()
            #expect(throws: Never.self, "invalid JSON for \(value.debugDescription)") {
                try JSONSerialization.jsonObject(with: Data(json.utf8))
            }
            let hits = try index.search(.term("s", value))
            #expect(hits.count == 1, "no match for \(value.debugDescription) — \(json)")
            #expect(hits.first?.string("s") == value)
        }
    }

    /// Byte values are tagged, not bare base64 — see ``JSONWriter/write(_:)-(Data)``.
    @Test func byteValuesAreTagged() throws {
        let json = try Query.term("key", Data([0xDE, 0xAD])).jsonString()
        #expect(json == #"{"type":"term","field":"key","value":{"$bytes":"3q0="}}"#)
    }

    /// Aiming a `Data` at a non-bytes field must be reported, not silently
    /// searched for as base64 text. This is what the tag buys.
    @Test func byteValueOnAStringFieldIsRejected() throws {
        let schema = SchemaBuilder().addStringField("tag", stored: true).build()
        let index = try Index.inMemory(schema: schema)
        #expect(throws: TantivyError.self) {
            try index.search(.term("tag", Data([0x01])))
        }
    }

    /// Output is deterministic. `JSONSerialization` emitted dictionary keys in
    /// hash order, so the same query could serialize differently between runs.
    @Test func outputIsStable() throws {
        let query: Query = (.term("a", "1") || .term("key", Data([0x01]))).boosted(by: 2)
        let first = try query.jsonString()
        for _ in 0..<20 {
            #expect(try query.jsonString() == first)
        }
    }

    /// Non-finite numbers are rejected before serializing: JSON cannot
    /// represent them, and a bare `nan` would fail in the engine's parser with
    /// a message that says nothing about which value caused it.
    @Test func nonFiniteNumbersAreRejected() throws {
        #expect(throws: TantivyError.self) { try Query.term("f", Double.nan).jsonString() }
        #expect(throws: TantivyError.self) { try Query.term("f", Double.infinity).jsonString() }
        #expect(throws: TantivyError.self) {
            try Query.term("f", 1.0).boosted(by: .nan).jsonString()
        }
        #expect(throws: TantivyError.self) {
            try Query.range(field: "f", lower: .included(.double(.nan)), upper: nil).jsonString()
        }
    }

    /// Doubles must not lose precision on the way through the writer.
    @Test func doublesRoundTripExactly() throws {
        let schema = SchemaBuilder().addF64Field("f", stored: true, indexed: true).build()
        let index = try Index.inMemory(schema: schema)
        let values = [1.5, -2.25, Double.pi, 1e300, -1e-300, 4.0, 0.1 + 0.2]
        let w = try index.writer()
        for value in values {
            var doc = Document()
            doc["f"] = .double(value)
            try w.addDocument(doc)
        }
        try w.commitAndReload()

        for value in values {
            #expect(try index.count(.term("f", value)) == 1, "lost precision on \(value)")
        }
    }
}
