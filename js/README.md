# @carbon/tantivy

[tantivy](https://github.com/quickwit-oss/tantivy) **0.26.1** full-text search
compiled to WebAssembly, with the API of the TantivySwift package in this
repository. Indexes live in memory; everything runs on the calling thread.

It runs in browsers, web workers and Node 20+ (tested in Chromium and Node 24).
It has no runtime dependencies, and needs no `SharedArrayBuffer` or
cross-origin-isolation headers.

```ts
import { init, Index, SchemaBuilder, Query, OrderBy } from "@carbon/tantivy";

await init(); // load the engine once

const index = Index.inMemory(
  new SchemaBuilder()
    .addTextField("title", { stored: true })
    .addTextField("body")
    .addU64Field("year", { stored: true, fast: true })
    .build(),
);

index.addAll([
  { title: "The Old Man and the Sea", body: "He was an old man who fished alone…", year: 1952 },
  { title: "Moby-Dick", body: "Call me Ishmael.", year: 1851 },
]);

for (const hit of index.search("sea whale", { limit: 10 })) {
  console.log(hit.score, hit.string("title"), hit.int("year"));
}

const q = Query.term("title", "sea").or(Query.closedRange("year", 1800, 1900));
index.search(q, { orderBy: OrderBy.descending("year") });
```

## Building

```bash
rustup target add wasm32-wasip1
npm install
npm run build   # scripts/build-wasm.sh → dist/tantivy.wasm, then tsc → dist/*.js
npm test
```

`example/index.html` is a small search page. To try it, serve this directory
(`python3 -m http.server`) and open `/example/`.

## Loading the engine

`init()` compiles the module once, from `tantivy.wasm` next to `dist/index.js`.
Under Node it reads the file from disk; elsewhere it uses `fetch`. Bundlers that
understand `new URL("./tantivy.wasm", import.meta.url)` (Vite, webpack 5) copy
the file for you. To load it from somewhere else,
pass a URL, bytes, a `Response` or a compiled `WebAssembly.Module`:

```ts
await init(new URL("/assets/tantivy.wasm", location.href));
initSync(bytes); // synchronous, e.g. in a worker
```

After that, everything is synchronous, as in Swift. A large commit or merge
blocks the thread it runs on, so for big indexes in a page run the index in a
Web Worker.

## Differences from Swift

- **In memory only.** There is no `Index(path:)`; use `Index.inMemory(schema)`.
  To persist an index, keep the source documents and re-index them.
- **Merges run in line.** tantivy's writer merges segments on background
  threads. Here a commit merges what tantivy's merge policy picks before it
  returns, and `optimize()` merges everything.
- **Close writers.** JavaScript has no deinit. A writer holds the index's
  single-writer lock until `close()`, or `using w = index.writer()` where
  supported. `index.write(...)` and the other helpers close it for you. An
  index's memory goes when it is garbage collected, or at once with `close()`.
- **Integers.** Stored integers come back as `number` when exact and as
  `bigint` beyond 2^53. Pass `bigint` for 64-bit values in documents and
  queries. `hit.int()` returns `undefined` for a value a `number` cannot hold
  exactly; use `hit.bigint()` for those.
- **Crashes stay local.** A Rust panic cannot unwind in WebAssembly, so it
  aborts the instance. Each index has its own instance. The call throws a
  `TantivyError` with the panic message, and that index refuses further calls,
  while other indexes carry on.

## Swift → TypeScript

| Swift | TypeScript |
| --- | --- |
| `SchemaBuilder().addTextField("t", stored: true, tokenizer: .english)` | `new SchemaBuilder().addTextField("t", { stored: true, tokenizer: Analyzer.english })` |
| `Index.inMemory(schema:reloadPolicy:)` | `Index.inMemory(schema, { reloadPolicy: "onCommit" })` |
| `index.search("q", limit:fields:boosts:highlight:snippetMaxChars:orderBy:)` | `index.search("q", { limit, fields, boosts, highlight, snippetMaxChars, orderBy })` |
| `index.search(query)`, `index.count(query)` | `index.search(query)`, `index.count(query)` |
| `index.documentCount`, `reload()`, `stats()`, `optimize()`, `garbageCollect()` | same names |
| `index.analyze(text, with: .english)` | `index.analyze(text, Analyzer.english)` |
| `index.termCounts("f", matching:limit:)` | `index.termCounts("f", { matching, limit })` |
| `index.aggregate(json, matching:)` → `String` | `index.aggregate(request, matching)` → parsed object |
| `index.moreLikeThis(idField:id:fields:options:limit:)` | `index.moreLikeThis({ idField, id, fields, options, limit })` |
| `index.write { w in … }` | `index.write((w) => …)` |
| `index.add(doc)`, `add(contentsOf:)` | `index.add(doc)`, `addAll(docs)` |
| `index.upsert(doc, idField:id:)`, `delete(matching:)`, `get(_:equals:)` | `upsert(doc, idField, id)`, `deleteMatching(query)`, `get(field, value)` |
| `writer.addDocument([...])`, `addDocument(json:)` | `addDocument({...})`, `addDocumentJSON(json)` |
| `writer.commit()`, `commitAndReload()`, `rollback()` | same names; return the opstamp as a `number` |
| `writer.deleteDocuments(field:equals:)` | `deleteDocuments(field, value)` |
| `writer.deleteDocuments(field:equalsAnyOf:)` | `deleteDocumentsAnyOf(field, values)` |
| `writer.deleteDocuments(matching:)`, `deleteAllDocuments()` | `deleteDocumentsMatching(query)`, `deleteAllDocuments()` |
| `writer.merge()`, `garbageCollect()` | same names |
| writer `deinit` | `writer.close()` |
| `a && b`, `a \|\| b` | `a.and(b)`, `a.or(b)` (chains flatten the same way) |
| `.term`, `.phrase`, `.phrasePrefix`, `.multiPhrase`, `.fuzzy`, `.prefix`, `.autocomplete`, `.regex`, `.wildcard`, `.exists`, `.moreLikeThis`, `.parsed`, `.allOf`, `.anyOf`, `.matchAll` | `Query.term(...)` etc., same names |
| `.range("f", 1...5)`, `.range("f", 1..<5)`, `.range("f", from:to:)` | `Query.closedRange("f", 1, 5)`, `Query.halfOpenRange("f", 1, 5)`, `Query.range("f", { from, to })` |
| `.boosted(by:)`, `.excluding(_:)` | `.boosted(factor)`, `.excluding(query)` |
| `SearchHit.string/int/uint/double/bool/data`, `hit["f"]`, `snippet("f")` | same, plus `bigint()` and `date()`; `hit.values("f")` |
| `hit.decode(Book.self)` | `hit.toObject<Book>(arrayFields)` |
| `SearchCollection<Book>` | `SearchCollection<Book>` (`add`, `addAll`, `upsert`, `get`, `search`, `searchScored`, `writer()`, `removeMatching`, `removeAll`, `countMatching`) |
| `TantivyError.ffi` / `.encoding`, `isEncoding` | `TantivyError` with `kind: "ffi" \| "encoding"`, `isEncoding` |
| `Tantivy.version` | `version()` |

Document values: `string`, `number`, `bigint`, `boolean`, `Date` (for date
fields), `Uint8Array`/`ArrayBuffer` (bytes fields), or an array of these for a
multi-valued field. `undefined` values are skipped; `null` is an error, as
`NSNull` is in Swift.
