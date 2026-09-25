import { test } from "node:test";
import assert from "node:assert/strict";
import { Query, RangeBound, OrderBy, TantivyError, version, Analyzer } from "../dist/index.js";
import { booksIndex, titles } from "./helpers.mjs";

test("version names the wrapped release", () => {
  assert.match(version(), /^tantivy 0\.26\.1 \/ tantivy_ffi /);
});

test("string queries search the default text fields", () => {
  const index = booksIndex();
  assert.deepEqual(new Set(titles(index.search("sea"))), new Set(["The Old Man and the Sea", "Moby Dick"]));
  assert.deepEqual(titles(index.search("title:sea")), ["The Old Man and the Sea"]);
  assert.deepEqual(titles(index.search("body:sea")), ["Moby Dick"]);
  assert.equal(index.search("title:dune AND body:spice").length, 1);
  assert.equal(index.search("\"old man\"").length, 1);
  assert.equal(index.search("nothing-matches").length, 0);
});

test("default fields and boosts", () => {
  const index = booksIndex();
  assert.equal(index.search("whale", { fields: ["title"] }).length, 0);
  assert.equal(index.search("whale", { fields: ["body"] }).length, 1);
  const [a] = index.search("sea", { fields: ["title"], boosts: { title: 10 } });
  const [b] = index.search("sea", { fields: ["title"], boosts: { title: 1 } });
  assert.ok(a.score > b.score);
});

test("limit, count and documentCount", () => {
  const index = booksIndex();
  assert.equal(index.documentCount, 4);
  assert.equal(index.search(Query.matchAll, { limit: 2 }).length, 2);
  assert.equal(index.count("the"), 3);
  assert.equal(index.count(Query.term("tag", "scifi")), 2);
});

test("stored values decode by type", () => {
  const index = booksIndex();
  const hit = index.get("id", "3");
  assert.equal(hit.string("title"), "Dune");
  assert.equal(hit.int("year"), 1965);
  assert.equal(hit.uint("year"), 1965);
  assert.equal(hit.double("rating"), 4.3);
  assert.equal(hit.date("published").toISOString(), "1965-08-01T00:00:00.000Z");
  assert.deepEqual(index.get("id", "1").values("tag"), ["classic", "sea"]);
  assert.deepEqual(index.get("id", "1").toObject(["tag"]).tag, ["classic", "sea"]);
  assert.equal(index.get("id", "3").toObject().tag, "scifi");
  assert.equal(index.get("id", "nope"), undefined);
});

test("structured term, range, boolean and boost queries", () => {
  const index = booksIndex();
  assert.deepEqual(titles(index.search(Query.term("title", "dune"))), ["Dune"]);
  assert.equal(index.count(Query.closedRange("year", 1900, 1970)), 2);
  assert.equal(index.count(Query.halfOpenRange("year", 1851, 1952)), 1);
  assert.equal(index.count(Query.range("rating", { from: RangeBound.excluded(4.0) })), 2);
  assert.equal(index.count(Query.dateRange("published", { from: new Date("1960-01-01T00:00:00Z") })), 2);
  assert.equal(index.count(Query.term("tag", "sea").and(Query.term("tag", "classic"))), 2);
  assert.equal(index.count(Query.term("title", "dune").or(Query.term("title", "moby"))), 2);
  assert.equal(index.count(Query.term("tag", "classic").excluding(Query.term("title", "moby"))), 1);
  const [top] = index.search(Query.term("title", "dune").or(Query.term("title", "moby").boosted(5)));
  assert.equal(top.string("title"), "Moby Dick");
  assert.equal(index.count(Query.anyOf([Query.term("tag", "sea"), Query.term("tag", "classic"), Query.term("tag", "scifi")], 2)), 2);
});

test("and/or chains flatten", () => {
  let q = Query.term("tag", "sea");
  for (let i = 0; i < 100; i++) q = q.and(Query.term("tag", "classic"));
  assert.equal(q.node.type, "boolean");
  assert.equal(q.node.must.length, 101);
  assert.equal(booksIndex().count(q), 2);
});

test("text matching queries", () => {
  const index = booksIndex();
  assert.deepEqual(titles(index.search(Query.phrase("title", ["old", "man"]))), ["The Old Man and the Sea"]);
  assert.equal(index.count(Query.phrase("title", ["old", "sea"], 3)), 1);
  assert.deepEqual(titles(index.search(Query.phrasePrefix("title", ["old", "ma"]))), ["The Old Man and the Sea"]);
  assert.deepEqual(titles(index.search(Query.prefix("title", "neur"))), ["Neuromancer"]);
  assert.deepEqual(titles(index.search(Query.fuzzy("title", "dume"))), ["Dune"]);
  assert.deepEqual(titles(index.search(Query.autocomplete("title", "nuero", 1))), ["Neuromancer"]);
  assert.deepEqual(titles(index.search(Query.regex("title", "d.n."))), ["Dune"]);
  assert.deepEqual(titles(index.search(Query.wildcard("title", "*mancer"))), ["Neuromancer"]);
  assert.equal(index.count(Query.exists("rating")), 4);
  assert.equal(index.count(Query.parsed("whale OR spice")), 2);
  assert.equal(index.count(Query.parsed("spice", ["title"])), 0);
});

test("multi-phrase from positions and from analyzed tokens", () => {
  const index = booksIndex();
  assert.equal(index.count(Query.multiPhrase("title", [["old", "young"], ["man", "woman"]])), 1);
  const tokens = index.analyze("Old men", Analyzer.englishKeepingSurface);
  assert.deepEqual(tokens.map((t) => [t.text, t.position]), [["old", 0], ["men", 1]]);
  const withSynonym = [...index.analyze("old", Analyzer.default), { text: "man", position: 1, offsetFrom: 0, offsetTo: 0 }];
  assert.equal(index.count(Query.multiPhrase("title", withSynonym)), 1);
});

test("analyze keeps surface forms beside stems", () => {
  const index = booksIndex();
  const tokens = index.analyze("Designers", Analyzer.englishKeepingSurface);
  assert.deepEqual(tokens.map((t) => [t.text, t.position, t.offsetFrom, t.offsetTo]), [
    ["designers", 0, 0, 9],
    ["design", 0, 0, 9],
  ]);
});

test("more like this", () => {
  const index = booksIndex();
  const options = { minDocFrequency: 1, minTermFrequency: 1 };
  const related = index.moreLikeThis({ idField: "id", id: "1", fields: ["title"], options });
  assert.ok(related.every((h) => h.string("id") !== "1"));
  assert.ok(index.search(Query.moreLikeThis("title", "the sea", options)).length > 0);
});

test("ordering by a fast field", () => {
  const index = booksIndex();
  assert.deepEqual(titles(index.search(Query.matchAll, { orderBy: OrderBy.ascending("year") })), [
    "Moby Dick",
    "The Old Man and the Sea",
    "Dune",
    "Neuromancer",
  ]);
  const [newest] = index.search("the", { orderBy: OrderBy.descending("published") });
  assert.equal(newest.string("title"), "Neuromancer");
  assert.equal(newest.score, 0);
  assert.throws(() => index.search(Query.matchAll, { orderBy: OrderBy.ascending("title") }), TantivyError);
});

test("highlighted snippets", () => {
  const index = booksIndex();
  const [hit] = index.search("title:sea", { highlight: ["title"] });
  assert.equal(hit.snippet("title"), "The Old Man and the <b>Sea</b>");
});

test("term counts and aggregations", () => {
  const index = booksIndex();
  const counts = index.termCounts("tag");
  assert.deepEqual(
    counts.map((c) => `${c.value}=${c.count}`).sort(),
    ["classic=2", "scifi=2", "sea=2"],
  );
  assert.equal(index.termCounts("tag", { limit: 1 }).length, 1);
  assert.deepEqual(index.termCounts("tag", { matching: Query.term("title", "dune") }), [{ value: "scifi", count: 1 }]);
  const avg = index.aggregate({ avg_year: { avg: { field: "year" } } });
  assert.equal(avg.avg_year.value, (1952 + 1851 + 1965 + 1984) / 4);
});

test("64-bit integers round-trip exactly", async () => {
  const { Index, SchemaBuilder } = await import("../dist/index.js");
  const index = Index.inMemory(
    new SchemaBuilder().addU64Field("u", { stored: true }).addI64Field("i", { stored: true }).build(),
  );
  const big = 18446744073709551615n;
  const small = -9223372036854775808n;
  index.add({ u: big, i: small });
  index.add({ u: 7, i: -7 });
  const hit = index.get("u", big);
  assert.equal(hit.bigint("u"), big);
  assert.equal(hit.bigint("i"), small);
  assert.equal(hit.int("u"), undefined); // does not fit a number exactly
  assert.equal(index.get("i", -7).int("u"), 7);
  assert.equal(index.count(Query.closedRange("u", 10n, big)), 1);
});
