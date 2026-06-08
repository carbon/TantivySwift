# Tantivy for Swift

Swift bindings for the [tantivy](https://github.com/quickwit-oss/tantivy) **0.26.1**
full-text search engine, with a small, idiomatic API for building a schema,
adding documents, and querying.

Works on **macOS, iOS and iPadOS** (device + simulator). The Rust engine is
shipped as a prebuilt static-library `XCFramework`; there is nothing to compile
at app-build time.

```swift
import Tantivy

// 1. Describe the schema
let schema = SchemaBuilder()
    .addTextField("title", stored: true)
    .addTextField("body")                       // indexed, not stored
    .addU64Field("year", stored: true, fast: true)
    .build()

// 2. Open an index (on disk, or .inMemory(schema:))
let index = try Index(path: indexURL, schema: schema)

// 3. Add documents and commit
let writer = try index.writer()
try writer.addDocument([
    "title": "The Old Man and the Sea",
    "body":  "He was an old man who fished alone in a skiff…",
    "year":  1952,
])
try writer.commitAndReload()                    // commit + make searchable

// 4. Query
for hit in try index.search("sea whale", limit: 10) {
    print(hit.score, hit.string("title") ?? "", hit.int("year") ?? 0)
}
```

## Requirements

- Swift 6.2 toolchain (the package is `swift-tools-version: 6.2`, Swift 6 language mode)
- macOS 15+ / iOS 18+ (iPadOS uses the iOS slices; Mac Catalyst 18+)

## Installation (Swift Package Manager)

The package vends `artifacts/CTantivy.xcframework` (a binary target), so building
an app against it needs **no Rust toolchain** — just `import Tantivy`.

**From a Git remote** — in another package's `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/your-org/TantivySwift.git", from: "0.1.0"),
],
targets: [
    .target(
        name: "YourLibrary",
        dependencies: [.product(name: "Tantivy", package: "TantivySwift")]
    ),
]
```

**From a local path** (monorepo / side-by-side checkout):

```swift
.package(path: "../TantivySwift"),
```

**In an Xcode app** — File ▸ Add Package Dependencies ▸ enter the repo URL (or
"Add Local…"), then add the **Tantivy** library to your target.

Then use it:

```swift
import Tantivy

let index = try Index.inMemory(schema:
    SchemaBuilder().addTextField("title", stored: true).build())
```

> **Consuming as a dependency requires the committed xcframework.** The
> `artifacts/CTantivy.xcframework` binary must be present in the checkout (it is,
> in this repo). When it exists, `Package.swift` links it as a clean binary
> target with no `unsafeFlags`, which is what makes the package usable as a
> dependency of other packages. The host-only fallback (used when the
> xcframework is absent) relies on `unsafeFlags` and is for local development of
> *this* package only. The xcframework is ~60 MB — consider **Git LFS** for it.

> Building **from source** (regenerating the xcframework) requires full Xcode +
> a Rust toolchain — see [Building the XCFramework](#building-the-xcframework).

## API

### Schema

`SchemaBuilder` is a fluent builder. Each field has `stored` (return it in
results), `indexed` (make it searchable), and `fast` (columnar storage) options.

| Method | Field type |
| --- | --- |
| `addTextField(_:stored:indexed:tokenizer:indexing:fast:)` | tokenized full-text |
| `addStringField(_:stored:indexed:fast:)` | single raw token (exact match: ids, tags) |
| `addU64Field` / `addI64Field` / `addF64Field` / `addBoolField` | numerics |
| `addDateField(_:stored:indexed:fast:)` | date/time (RFC3339; `Date` round-trips at second precision) |

`tokenizer` is a typed `Analyzer` (default `.default`); the cases mirror exactly
what the native layer registers (a drift-guard test enforces this):

| `Analyzer` | Behavior |
| --- | --- |
| `.default` | lowercased, split on non-alphanumeric, unstemmed |
| `.english` | `.default` + English stemming (tantivy `en_stem`) |
| `.raw` | the whole value as one token, **case-sensitive** (exact match) |
| `.tag` | the whole value as one **lowercased** token (case-insensitive tags/enums) |
| `.whitespace` | split on whitespace only |

```swift
.addTextField("title", stored: true, tokenizer: .english)
```

`indexing` controls postings detail; `.position` (the default) is required for
phrase queries.

### Index

```swift
let index = try Index(path: url, schema: schema)   // create or open on disk
let index = try Index.inMemory(schema: schema)      // not persisted

index.documentCount                                 // searchable doc count
try index.reload()                                  // observe latest commit
try index.search(_:limit:fields:)                   // -> [SearchHit]
```

`Index(path:)` creates the index if the directory is empty, or opens the
existing one (the schema must match). On iOS, pass a writable location such as
`Application Support` or `Caches`.

### Writing

```swift
let writer = try index.writer(heapSize: 0)          // 0 → 50 MB indexing budget
try writer.addDocument(["title": "Hi", "tags": ["a", "b"], "year": 2024])
try writer.addDocument(someEncodableValue)          // any Encodable
try writer.addDocument(json: #"{"title":"Hi"}"#)    // raw JSON
let opstamp = try writer.commit()                   // durable; reload to search
try writer.commitAndReload()                         // commit + index.reload()
try writer.deleteAllDocuments()
try writer.deleteDocuments(field: "id", equals: "abc123")   // delete by term
```

Use at most **one writer per index at a time**. Values may be scalars or arrays
(arrays populate multi-valued fields). Documents become searchable only after a
`commit()` followed by `Index.reload()` — `commitAndReload()` does both.

**Replace / upsert.** tantivy has no in-place update; replace a document by
deleting its id term and re-adding it (supply the *whole* document). `upsert`
does both in one commit:

```swift
try index.upsert(card, idField: "id", id: card.id)   // delete-by-term + add
```

The id field should be a single-token field (a `string`/raw or numeric/bool
field) so the term matches the whole value.

### Querying & results

`search` accepts [tantivy query syntax](https://docs.rs/tantivy/0.26.1/tantivy/query/struct.QueryParser.html):

```text
sea whale            # either term, in the default fields
title:whale          # field-scoped
"old man"            # phrase (needs .position indexing)
title:sea AND body:fish
year:[1900 TO 2000]                       # numeric range
created:[2020-01-01T00:00:00Z TO 2021-01-01T00:00:00Z]   # date range (RFC3339)
```

`fields:` (default empty) chooses which fields an unqualified term searches;
empty means *all indexed text fields*. `boosts:` applies per-field weights:

```swift
try index.search("dune", boosts: ["title": 2.0, "body": 0.5])
```

Each result is a `SearchHit`:

```swift
hit.score                 // Float relevance score (higher = better)
hit.string("title")       // first String value, or nil
hit.int("year")           // first Int64, or nil
hit.uint("count")         // first UInt64, or nil (full u64 range, exact)
hit.double("rating")
hit.bool("active")
hit["tags"]               // [FieldValue] – all values for a field
```

Only `stored` fields come back in hits. Integers round-trip exactly across the
full `i64` and `u64` ranges (`FieldValue` has both `.int(Int64)` and
`.unsigned(UInt64)` cases); the numeric accessors coerce between them.

### Structured queries (`Query`)

A second search API builds a query *tree* that maps directly onto tantivy's own
query types (`TermQuery`, `PhraseQuery`, `RangeQuery`, `BooleanQuery`,
`BoostQuery`, `FuzzyTermQuery`, `AllQuery`) — no string parsing, no escaping.

```swift
let q: Query =
    (.term("tag", "book") && .range("year", 1900...2000))
        .excluding(.term("status", "draft"))

for hit in try index.search(q) { … }                 // [SearchHit]
let books = try index.search(q, as: Book.self)        // typed
let scored = try collection.searchScored(q)           // [(score, Book)]
```

Builders: `.matchAll`, `.term(field, value)` (string / Int / UInt64 / Double /
Bool / `date:`), `.phrase(field, [tokens], slop:)`, `.fuzzy(field, value,
distance:…)`, `.range(field, 1900...2000)` / `.dateRange(field, from:to:)`,
`.allOf` / `.anyOf(_, minimumShouldMatch:)`, `&&`, `||`, `.excluding(_)`,
`.boosted(by:)`.

> `term`/`phrase` match **indexed tokens exactly** (as tantivy does): on a
> tokenized text field pass already-analyzed tokens (e.g. lowercase for the
> `default` tokenizer). For analyzed/free-text input, use the string `search`.

### Convenience helpers

`Index` has helpers that cut the writer/commit/reload boilerplate and close the
Codable loop:

```swift
// Scoped writer — auto commit + reload; nothing is committed if the body throws.
try index.write { w in
    try w.addDocument(["title": "Dune", "year": 1965])
}

// One-shot add (dictionary or Encodable), single or batch.
try index.add(["title": "Dune", "year": 1965])
try index.add(book)                          // any Encodable
try index.add(contentsOf: [book1, book2])    // one commit

// Typed search — decode hits straight into your model.
let books = try index.search("dune", as: Book.self)   // [Book]
```

Typed search uses a model-driven decoder: a scalar property reads a field's
first stored value, an array property reads them all (a one-element multi-valued
field still decodes into an array), and optionals become `nil` for absent
fields. You can also decode a single hit with `hit.decode(Book.self)`.

### Typed collection

`SearchCollection<Model>` bundles a schema + index behind a typed `add`/`search`
API:

```swift
struct Book: Codable { let title: String; let year: UInt64 }

let books = try SearchCollection<Book>(path: url) { s in
    s.addTextField("title", stored: true)
    s.addU64Field("year", stored: true, fast: true)
}                                            // or .inMemory(schema:) / (index:)

try books.add(Book(title: "Dune", year: 1965))
try books.add(contentsOf: [book1, book2])

books.count                                  // searchable document count
let results = try books.search("dune")       // [Book]
let scored  = try books.searchScored("dune") // [(score: Float, model: Book)]
try books.removeAll()
```

The schema's field names must match the model's coding keys. `books.index`
exposes the underlying `Index` for anything the façade doesn't cover.

## Building the XCFramework

The committed `artifacts/CTantivy.xcframework` is produced from tantivy 0.26.1
(pinned via crates.io in `rust/Cargo.toml`). To rebuild it (e.g. after changing
the FFI layer):

```bash
# Requires full Xcode + rustup.
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  scripts/build-xcframework.sh
```

This cross-compiles the Rust static library for:

- macOS — `arm64` + `x86_64` (universal)
- iOS device — `arm64`
- iOS simulator — `arm64` + `x86_64` (universal)

and assembles them into `artifacts/CTantivy.xcframework`. iPadOS uses the iOS
slices.

### Local development without the xcframework

If `artifacts/CTantivy.xcframework` is absent, `Package.swift` automatically
falls back to linking a **host-only** static library, so you can iterate and run
the tests on your Mac:

```bash
scripts/build-host.sh        # builds rust/target/release/libtantivy_ffi.a
swift test
```

(If your active developer dir is the Command Line Tools, prefix `swift test`
with `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` so XCTest is
found.)

## How it works

```
Swift  Sources/Tantivy        — idiomatic API (Schema, Index, IndexWriter, SearchHit)
  │     import CTantivy        — C module (header + module map)
  ▼
C ABI  rust/src/lib.rs         — #[no_mangle] extern "C" shim, JSON in/out
  ▼
Rust   tantivy =0.26.1         — the search engine, pinned from crates.io
```

The FFI surface is intentionally small and JSON-oriented: schema is a small JSON
spec, documents are added as JSON objects (`TantivyDocument::parse_json`), and
search returns a JSON envelope of hits. All heap strings crossing the boundary
are owned and freed on the Rust side via `tantivy_string_free`.

## License

The bindings in this repository follow tantivy's **MIT** license. tantivy ©
its authors.
