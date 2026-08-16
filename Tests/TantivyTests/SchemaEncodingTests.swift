import Foundation
import Testing
@testable import Tantivy

/// Coverage for the two remaining JSON payloads written by hand: the schema
/// spec and the per-field boost map.
///
/// Both used to go through `JSONSerialization`, which validated and escaped for
/// us. They are now written by ``JSONWriter``, so nothing does — and a bad
/// escape in the schema is especially unpleasant, because the index would fail
/// to open with a parse error that names no field.
struct SchemaEncodingTests {

    // MARK: - Schema

    @Test func schemaSpecHasTheExpectedShape() throws {
        let schema = SchemaBuilder()
            .addTextField("title", stored: true, tokenizer: .english, indexing: .freq)
            .addStringField("tag", fast: true)
            .addU64Field("year", stored: true)
            .addBytesField("key", indexed: true)
            .build()

        let object = try #require(
            try JSONSerialization.jsonObject(with: Data(schema.json.utf8)) as? [String: Any])
        let fields = try #require(object["fields"] as? [[String: Any]])
        #expect(fields.count == 4)

        // Text fields carry tokenizer and postings detail; nothing else does.
        #expect(fields[0]["type"] as? String == "text")
        #expect(fields[0]["tokenizer"] as? String == "en_stem")
        #expect(fields[0]["record"] as? String == "freq")
        #expect(fields[1]["tokenizer"] == nil)
        #expect(fields[2]["tokenizer"] == nil)
        #expect(fields[3]["type"] as? String == "bytes")

        #expect(fields[1]["fast"] as? Bool == true)
        #expect(fields[2]["stored"] as? Bool == true)
    }

    @Test func emptySchemaIsWellFormed() throws {
        #expect(SchemaBuilder().build().json == #"{"fields":[]}"#)
    }

    @Test func fieldOrderIsPreserved() throws {
        let names = ["b", "a", "c"]
        let builder = SchemaBuilder()
        for name in names { builder.addStringField(name) }
        let object = try JSONSerialization.jsonObject(with: Data(builder.build().json.utf8))
        let fields = try #require((object as? [String: Any])?["fields"] as? [[String: Any]])
        #expect(fields.compactMap { $0["name"] as? String } == names)
    }

    /// Field names needing escapes must survive all the way to a working index —
    /// not merely produce parseable JSON.
    @Test func awkwardFieldNamesRoundTrip() throws {
        let names = [
            #"quote " name"#,
            #"backslash \ name"#,
            "newline \n name",
            "control \u{01} name",
            "unicode é🙂 name",
        ]
        for name in names {
            let schema = SchemaBuilder().addStringField(name, stored: true).build()
            #expect(throws: Never.self, "invalid schema JSON for \(name.debugDescription)") {
                try JSONSerialization.jsonObject(with: Data(schema.json.utf8))
            }

            let index = try Index.inMemory(schema: schema)
            var doc = Document()
            doc[name] = .string("value")
            try index.add(doc)

            let hit = try #require(try index.search(.term(name, "value")).first,
                                   "no match for field \(name.debugDescription)")
            #expect(hit.string(name) == "value")
        }
    }

    // MARK: - Boosts

    @Test func boostsSerializeAndAreStable() throws {
        let boosts = ["title": 2.0, "body": 0.5, "tag": 1.25]
        let json = try Index.boostsJSON(boosts)
        let decoded = try #require(
            try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Double])
        #expect(decoded == boosts)
        // Key order is sorted, so the same request always serializes identically.
        #expect(json == #"{"body":0.5,"tag":1.25,"title":2.0}"#)
        for _ in 0..<20 { #expect(try Index.boostsJSON(boosts) == json) }
    }

    @Test func emptyBoostsProduceNoPayload() throws {
        #expect(try Index.boostsJSON([:]) == "")
    }

    @Test func boostFieldNamesAreEscaped() throws {
        let json = try Index.boostsJSON([#"a "quoted" field"#: 1.5])
        #expect(throws: Never.self) {
            try JSONSerialization.jsonObject(with: Data(json.utf8))
        }
        #expect(json.contains(#"\"quoted\""#))
    }

    @Test func invalidBoostsAreRejected() throws {
        #expect(throws: TantivyError.self) { try Index.boostsJSON(["a": .nan]) }
        #expect(throws: TantivyError.self) { try Index.boostsJSON(["a": .infinity]) }
        #expect(throws: TantivyError.self) { try Index.boostsJSON(["a\u{0}b": 1.0]) }
    }

    /// Boosts reach the engine and actually weight the results.
    @Test func boostsApplyToScores() throws {
        let index = try Fixtures.animalsIndex()
        let plain = try index.search("red sea", limit: 10)
        let boosted = try index.search("red sea", limit: 10, boosts: ["title": 8.0])
        #expect(!plain.isEmpty)
        #expect(plain.count == boosted.count)
        #expect(plain.map(\.score) != boosted.map(\.score))
    }
}
