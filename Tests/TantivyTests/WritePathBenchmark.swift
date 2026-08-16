import Foundation
import Testing
@testable import Tantivy

/// Measures the document write path, MessagePack against the JSON it replaced.
///
/// Encoding and decoding are each measured *in isolation* rather than inferred
/// by subtraction, because tantivy hands documents to indexing threads that run
/// concurrently with the add loop — so timing the loop cannot separate the two.
///
/// ```bash
/// TANTIVY_BENCH=1 swift test -c release --filter WritePathBenchmark
/// ```
///
/// Run it in release; in debug the Swift encoders are unoptimized and the
/// comparison says more about the optimizer than the formats.
struct WritePathBenchmark {

    private static var enabled: Bool {
        ProcessInfo.processInfo.environment["TANTIVY_BENCH"] != nil
    }

    private static let documentCount = 2_000

    // MARK: - Document shapes

    /// Three short fields — the shape where JSON overhead is largest relative
    /// to content, and so the friendliest case for replacing it.
    private func smallDocuments() -> (Schema, [[String: Any]]) {
        let schema = SchemaBuilder()
            .addStringField("id", stored: true)
            .addTextField("title", stored: true)
            .addU64Field("n", stored: true, indexed: true, fast: true)
            .build()
        let docs = (0..<Self.documentCount).map { n in
            ["id": "id-\(n)", "title": "document \(n)", "n": n] as [String: Any]
        }
        return (schema, docs)
    }

    /// A realistic document: a title, a paragraph of body text, a tag, a year.
    private func proseDocuments() -> (Schema, [[String: Any]]) {
        let schema = SchemaBuilder()
            .addTextField("title", stored: true)
            .addTextField("body", stored: true)
            .addStringField("tag", stored: true)
            .addU64Field("year", stored: true, indexed: true, fast: true)
            .build()
        let words = ["search", "engine", "index", "query", "token", "segment",
                     "posting", "score", "relevance", "corpus", "term", "field"]
        let docs = (0..<Self.documentCount).map { n -> [String: Any] in
            var body = ""
            for i in 0..<40 { body += words[(n &+ i) % words.count] + " " }
            return ["title": "document number \(n)", "body": body,
                    "tag": "tag-\(n % 8)", "year": 1900 + (n % 120)]
        }
        return (schema, docs)
    }

    /// A 32-byte binary key plus two small fields — the shape this branch added,
    /// where the key already bypasses JSON.
    private func byteKeyDocuments() -> (Schema, [[String: Any]]) {
        let schema = SchemaBuilder()
            .addBytesField("key", stored: true, indexed: true)
            .addTextField("body", stored: true)
            .addU64Field("n", stored: true, indexed: true, fast: true)
            .build()
        let docs = (0..<Self.documentCount).map { n -> [String: Any] in
            var key = Data()
            for i in 0..<32 { key.append(UInt8((n &* 31 &+ i) % 256)) }
            return ["key": key, "body": "record \(n) search", "n": n]
        }
        return (schema, docs)
    }

    // MARK: - Timing

    private func measure(iterations: Int = 10, _ body: () throws -> Void) rethrows -> Double {
        for _ in 0..<2 { try body() }
        var samples: [Double] = []
        for _ in 0..<iterations {
            let start = DispatchTime.now().uptimeNanoseconds
            try body()
            samples.append(Double(DispatchTime.now().uptimeNanoseconds - start))
        }
        samples.sort()
        return samples[samples.count / 2]
    }

    private func ms(_ nanos: Double) -> String { String(format: "%7.2f ms", nanos / 1_000_000) }
    private func perDoc(_ nanos: Double) -> String {
        String(format: "%6.2f µs/doc", nanos / 1_000 / Double(Self.documentCount))
    }

    // MARK: - The benchmark

    @Test(.enabled(if: WritePathBenchmark.enabled))
    func compareWritePath() throws {
        print("")
        print("Write path: MessagePack vs the JSON it replaced")
        print("\(Self.documentCount) documents per iteration, median of 10.")

        for (name, make, jsonComparable) in [
            ("small (3 short fields)", smallDocuments, true),
            ("prose (40-word body)", proseDocuments, true),
            ("32-byte keys", byteKeyDocuments, false),
        ] as [(String, () -> (Schema, [[String: Any]]), Bool)] {
            let (schema, documents) = make()

            // Index and writer are built outside the timed region: creating them
            // spins up tantivy's indexing thread pool, which costs more than the
            // difference being measured and varies enough to swamp it.
            func timeIngest(_ add: (IndexWriter) throws -> Void) throws -> Double {
                let index = try Index.inMemory(schema: schema)
                let writer = try index.writer()
                defer { _ = index }
                return try measure {
                    try add(writer)
                    try writer.commit()
                }
            }

            // The path as it ships now.
            let messagePack = try timeIngest { writer in
                for document in documents { try writer.addDocument(document) }
            }

            // Encoders alone, no index involved — the cleanest attributable
            // comparison, since neither touches tantivy.
            let messagePackEncode = try measure {
                for document in documents { _ = try MessagePackWriter.document(document) }
            }
            let jsonEncode = try measure {
                for document in documents { _ = try Self.encodeAsJSON(document) }
            }

            print("")
            print("  \(name)")
            print("    encode only      MsgPack \(ms(messagePackEncode))   \(perDoc(messagePackEncode))")
            if jsonComparable {
                print("                        JSON \(ms(jsonEncode))   \(perDoc(jsonEncode))"
                      + String(format: "   (%.2f× slower)", jsonEncode / messagePackEncode))
            }
            print("    full ingest      MsgPack \(ms(messagePack))   \(perDoc(messagePack))")

            guard jsonComparable else {
                // The old path carried byte values in a side-channel that no
                // longer exists, so there is nothing faithful to compare to.
                print("                        JSON  — the old path used a byte side-channel"
                      + " that has since been removed")
                continue
            }

            // The same documents through the old path, encoding included: this
            // is what `addDocument([String: Any])` used to do end to end.
            let json = try timeIngest { writer in
                for document in documents {
                    guard Self.allFinite(document) else { return }
                    try writer.addDocument(json: try Self.encodeAsJSON(document))
                }
            }
            print("                        JSON \(ms(json))   \(perDoc(json))"
                  + String(format: "   (%.2f× slower)", json / messagePack))
        }
        print("")
    }

    /// What the old `[String: Any]` path produced: a JSON object, rebuilt as a
    /// `String` on the way to a NUL-terminated C string.
    private static func encodeAsJSON(_ document: [String: Any]) throws -> String {
        var jsonFields = document
        for (name, value) in document where value is Data {
            // Byte values had their own side-channel; base64 stands in here so
            // the payload stays comparable in size.
            jsonFields[name] = (value as! Data).base64EncodedString()
        }
        return String(decoding: try JSONSerialization.data(withJSONObject: jsonFields), as: UTF8.self)
    }

    /// The NaN pre-scan the JSON path required, because a non-finite number
    /// reaching `JSONSerialization` raises an *uncatchable* `NSException`. The
    /// MessagePack encoder checks inline as it writes, so this pass is gone.
    private static func allFinite(_ value: Any) -> Bool {
        switch value {
        case let d as Double: return d.isFinite
        case let f as Float: return f.isFinite
        case let array as [Any]: return array.allSatisfy(allFinite)
        case let dict as [String: Any]: return dict.values.allSatisfy(allFinite)
        default: return true
        }
    }
}
