import Tantivy

/// Shared fixtures for the test suite.
enum Fixtures {
    /// A 3-document corpus used across query tests.
    ///
    /// Schema: `title` (text, stored), `body` (text, indexed only),
    /// `year` (u64, stored + fast).
    static func animalsIndex() throws -> Index {
        let schema = SchemaBuilder()
            .addTextField("title", stored: true)
            .addTextField("body")                              // indexed, not stored
            .addU64Field("year", stored: true, indexed: true, fast: true)
            .build()

        let index = try Index.inMemory(schema: schema)
        let w = try index.writer()
        try w.addDocument(["title": "red fox",
                           "body": "the quick brown fox jumps",
                           "year": 2001])
        try w.addDocument(["title": "blue whale",
                           "body": "the whale swims in the deep sea",
                           "year": 2002])
        try w.addDocument(["title": "red crab",
                           "body": "a small red crab on the sea shore",
                           "year": 2003])
        try w.commitAndReload()
        return index
    }
}
