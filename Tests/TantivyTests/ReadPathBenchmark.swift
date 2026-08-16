import Foundation
import Testing
@testable import Tantivy

/// Measures the search path after the move to MessagePack.
///
/// There is no longer a JSON hit path to compare against — it was deleted — so
/// the "before" column is the measurement taken on this machine while both
/// existed, recorded here so the comparison stays checkable rather than
/// remembered.
///
/// ```bash
/// TANTIVY_BENCH=1 swift test -c release --filter ReadPathBenchmark
/// ```
struct ReadPathBenchmark {

    private static var enabled: Bool {
        ProcessInfo.processInfo.environment["TANTIVY_BENCH"] != nil
    }

    /// Prose corpus, JSON envelope, recorded before the switch: (hits, decode
    /// ms, end-to-end ms).
    private static let jsonBaseline: [Int: (decode: Double, total: Double)] = [
        10: (0.194, 0.224),
        100: (1.96, 2.12),
        1_000: (19.59, 21.61),
    ]

    private func corpus(documents: Int) throws -> Index {
        let schema = SchemaBuilder()
            .addTextField("title", stored: true)
            .addTextField("body", stored: true)
            .addStringField("tag", stored: true)
            .addU64Field("year", stored: true, indexed: true, fast: true)
            .build()
        let index = try Index.inMemory(schema: schema)
        let w = try index.writer()
        let words = ["search", "engine", "index", "query", "token", "segment",
                     "posting", "score", "relevance", "corpus", "term", "field"]
        for n in 0..<documents {
            var body = ""
            for i in 0..<40 { body += words[(n &+ i) % words.count] + " " }
            try w.addDocument([
                "title": "document number \(n)", "body": body,
                "tag": "tag-\(n % 8)", "year": 1900 + (n % 120),
            ] as [String: Any])
        }
        try w.commitAndReload()
        return index
    }

    private func measure(iterations: Int = 50, _ body: () throws -> Void) rethrows -> Double {
        for _ in 0..<5 { try body() }
        var samples: [Double] = []
        for _ in 0..<iterations {
            let start = DispatchTime.now().uptimeNanoseconds
            try body()
            samples.append(Double(DispatchTime.now().uptimeNanoseconds - start))
        }
        samples.sort()
        return samples[samples.count / 2] / 1_000_000   // ms
    }

    @Test(.enabled(if: ReadPathBenchmark.enabled))
    func measureSearchPath() throws {
        print("")
        print("Search path: MessagePack, against the JSON baseline recorded before the switch")
        let index = try corpus(documents: 2_000)

        for limit in [10, 100, 1_000] {
            let payload = try index.rawSearchPayload(.matchAll, limit: limit)
            let decode = try measure {
                try payload.withUnsafeBytes { _ = try MessagePackReader.decodeHits($0) }
            }
            let total = try measure(iterations: 30) {
                _ = try index.search(.matchAll, limit: limit)
            }
            let baseline = Self.jsonBaseline[limit]!

            print("")
            print("  \(limit) hits — wire \(String(format: "%.1f KB", Double(payload.count) / 1024))")
            print(String(format: "    decode       %6.3f ms   (JSON was %6.3f ms — %.1f× faster)",
                         decode, baseline.decode, baseline.decode / decode))
            print(String(format: "    end to end   %6.3f ms   (JSON was %6.3f ms — %.1f× faster)",
                         total, baseline.total, baseline.total / total))
            print(String(format: "    decode is now %.0f%% of a search, was %.0f%%",
                         100 * decode / total, 100 * baseline.decode / baseline.total))
        }
        print("")
    }
}
