import { test } from "node:test";
import assert from "node:assert/strict";
import { Index, SchemaBuilder, Query, RangeBound, TantivyError, SearchCollection } from "../dist/index.js";
import "./helpers.mjs";

const isEncoding = (e) => e instanceof TantivyError && e.isEncoding;
const isEngine = (e) => e instanceof TantivyError && e.kind === "ffi";

test("bytes fields store, match and delete exact bytes", () => {
  const index = Index.inMemory(
    new SchemaBuilder().addBytesField("key", { stored: true }).addTextField("body", { stored: true }).build(),
  );
  const k1 = new Uint8Array([0, 1, 2, 255, 0]);
  const k2 = new Uint8Array([0xde, 0xad, 0xbe, 0xef]);
  index.addAll([
    { key: k1, body: "one" },
    { key: k2.buffer, body: "two" }, // an ArrayBuffer works too
  ]);
  const [hit] = index.search(Query.term("key", k1));
  assert.equal(hit.string("body"), "one");
  assert.deepEqual(hit.data("key"), k1);
  assert.equal(index.count(Query.range("key", { from: RangeBound.included(new Uint8Array([0xd0])) })), 1);
  index.write((w) => w.deleteDocuments("key", k2));
  assert.equal(index.documentCount, 1);
  index.write((w) => w.deleteDocumentsAnyOf("key", [k1]));
  assert.equal(index.documentCount, 0);
});

test("a byte value aimed at a text field is an error, not a silent miss", () => {
  const index = Index.inMemory(new SchemaBuilder().addStringField("id").build());
  assert.throws(() => index.search(Query.term("id", new Uint8Array([1]))), isEngine);
});

test("dates index as RFC3339 at second precision", () => {
  const index = Index.inMemory(new SchemaBuilder().addDateField("at", { stored: true, fast: true }).build());
  index.add({ at: new Date("2024-02-29T12:34:56.789Z") });
  assert.equal(index.search(Query.matchAll)[0].string("at"), "2024-02-29T12:34:56Z");
  assert.equal(index.count(Query.term("at", new Date("2024-02-29T12:34:56Z"))), 1);
  assert.throws(() => index.add({ at: new Date("nope") }), isEncoding);
});

test("document values the engine cannot take are rejected before it", () => {
  const index = Index.inMemory(
    new SchemaBuilder().addF64Field("x", { stored: true }).addU64Field("n").addTextField("t").build(),
  );
  assert.throws(() => index.add({ x: NaN }), isEncoding);
  assert.throws(() => index.add({ x: Infinity }), isEncoding);
  assert.throws(() => index.add({ n: 2n ** 64n }), isEncoding);
  assert.throws(() => index.add({ t: null }), isEncoding);
  assert.throws(() => index.add({ t: { nested: 1 } }), isEncoding);
  assert.throws(() => index.add({ t: [["nested"]] }), isEncoding);
  // Type mismatches the engine reports.
  assert.throws(() => index.add({ n: -1 }), isEngine);
  assert.throws(() => index.add({ n: 1.5 }), isEngine);
  assert.throws(() => index.add({ nope: "x" }), (e) => isEngine(e) && /unknown field/.test(e.message));
  // Whole numbers suit float fields; undefined values are skipped.
  index.add({ x: 2, t: undefined });
  assert.equal(index.search(Query.matchAll)[0].double("x"), 2);
});

test("arguments are validated as Swift validates them", () => {
  const index = Index.inMemory(new SchemaBuilder().addTextField("t").addU64Field("n", { fast: true }).build());
  assert.throws(() => index.search("a\0b"), isEncoding);
  assert.throws(() => index.search("a", { fields: ["t,n"] }), isEncoding);
  assert.throws(() => index.search("a", { highlight: ["t\0"] }), isEncoding);
  assert.throws(() => index.search("a", { limit: -1 }), isEncoding);
  assert.throws(() => index.search("a", { limit: 1.5 }), isEncoding);
  assert.throws(() => index.search("a", { boosts: { t: NaN } }), isEncoding);
  assert.throws(() => index.writer(-1), isEncoding);
  assert.throws(() => index.writer(1000), (e) => isEngine(e) && /at least 15000000/.test(e.message));
  assert.throws(() => index.search(Query.range("n", {})), isEncoding);
  assert.throws(() => index.search(Query.term("n", NaN)), isEncoding);
  assert.throws(() => index.search(Query.term("t", "x").boosted(Infinity)), isEncoding);
  assert.throws(() => index.search(Query.anyOf([Query.matchAll], -1)), isEncoding);
  assert.throws(() => index.search(Query.fuzzy("t", "x", { distance: 256 })), isEncoding);
  assert.throws(() => index.search(Query.multiPhrase("t", [{ text: "a", position: -1 }])), isEncoding);
  let deep = Query.matchAll;
  for (let i = 0; i < 41; i++) deep = deep.boosted(2);
  assert.throws(() => index.search(deep), isEncoding);
  assert.throws(() => index.search("((((((((((((((a))))))))))))))"), isEngine);
  assert.throws(() => index.termCounts("t", { limit: -1 }), isEncoding);
});

test("engine errors carry the engine's message", () => {
  const index = Index.inMemory(new SchemaBuilder().addTextField("t").build());
  assert.throws(() => index.search("t:(unclosed"), (e) => isEngine(e) && /could not parse query/.test(e.message));
  assert.throws(() => index.search(Query.term("missing", "x")), (e) => /unknown field 'missing'/.test(e.message));
  assert.throws(() => index.count(Query.moreLikeThis("t", "x")), isEngine);
  assert.throws(() => index.analyze("x", "no_such_analyzer"), /not found/);
  assert.equal(String(TantivyError.ffi("boom")), "tantivy: boom");
  assert.equal(String(TantivyError.encoding("boom")), "tantivy encoding: boom");
});

test("schema mistakes are reported when the index opens", () => {
  const dup = new SchemaBuilder().addTextField("a").addTextField("a").build();
  assert.throws(() => Index.inMemory(dup), /duplicate field 'a'/);
});

test("closed indexes and writers refuse further calls", () => {
  const index = Index.inMemory(new SchemaBuilder().addTextField("t").build());
  const w = index.writer();
  w.close();
  w.close(); // idempotent
  assert.throws(() => w.addDocument({ t: "x" }), /writer is closed/);
  index.close();
  assert.throws(() => index.search("x"), /index is closed/);
});

test("a crash retires only the index it happened in", () => {
  const schema = new SchemaBuilder().addTextField("t", { stored: true }).build();
  const crashing = Index.inMemory(schema);
  const healthy = Index.inMemory(schema);
  healthy.add({ t: "survivor" });
  const e = crashing.engine;
  // Read through a wild pointer: a real trap, as a Rust panic would be.
  assert.throws(() => e.call(() => e.api.tantivy_result_len(0xfffffff0)), /internal panic/);
  assert.throws(() => crashing.search("x"), /stopped after an earlier crash/);
  assert.equal(healthy.search("survivor").length, 1);
});

test("SearchCollection gives typed models", () => {
  const books = SearchCollection.inMemory(
    (s) => {
      s.addStringField("slug", { stored: true });
      s.addTextField("title", { stored: true });
      s.addU64Field("year", { stored: true, fast: true });
      s.addStringField("tags", { stored: true, fast: true });
    },
    { arrays: ["tags"] },
  );
  books.addAll([
    { slug: "dune", title: "Dune", year: 1965, tags: ["scifi"] },
    { slug: "moby", title: "Moby Dick", year: 1851, tags: ["classic", "sea"] },
  ]);
  assert.deepEqual(books.get("slug", "dune"), { slug: "dune", title: "Dune", year: 1965, tags: ["scifi"] });
  assert.equal(books.count, 2);
  assert.equal(books.countMatching("moby"), 1);
  assert.deepEqual(books.search(Query.closedRange("year", 1900, 2000)).map((b) => b.slug), ["dune"]);
  assert.ok(books.searchScored("dune")[0].score > 0);
  books.upsert({ slug: "dune", title: "Dune Messiah", year: 1969, tags: ["scifi"] }, "slug", "dune");
  assert.equal(books.get("slug", "dune").title, "Dune Messiah");
  assert.equal(books.count, 2);

  const w = books.writer();
  w.add({ slug: "neuro", title: "Neuromancer", year: 1984, tags: ["scifi"] });
  w.remove("slug", "moby");
  assert.equal(books.count, 2); // not yet committed
  w.commit();
  w.close();
  assert.deepEqual(books.search(Query.matchAll).map((b) => b.slug).sort(), ["dune", "neuro"]);
  assert.deepEqual(books.termCounts("tags"), [{ value: "scifi", count: 2 }]);
  books.removeMatching(Query.term("slug", "neuro"));
  assert.equal(books.count, 1);
  books.removeAll();
  assert.equal(books.count, 0);
});
