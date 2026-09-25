import { test } from "node:test";
import assert from "node:assert/strict";
import { Index, SchemaBuilder, Query, TantivyError } from "../dist/index.js";
import "./helpers.mjs"; // loads the engine

const idSchema = () =>
  new SchemaBuilder()
    .addStringField("id", { stored: true })
    .addTextField("body", { stored: true })
    .addU64Field("n", { stored: true, fast: true })
    .build();

const ids = (index) => index.search(Query.matchAll, { limit: 1000 }).map((h) => h.string("id")).sort();

test("documents are searchable after commit and reload, not before", () => {
  const index = Index.inMemory(idSchema());
  const w = index.writer();
  w.addDocument({ id: "a" });
  assert.equal(index.documentCount, 0);
  w.commit();
  assert.equal(index.documentCount, 0); // manual reload policy
  index.reload();
  assert.equal(index.documentCount, 1);
  w.close();
});

test("the onCommit policy reloads without being asked", () => {
  const index = Index.inMemory(idSchema(), { reloadPolicy: "onCommit" });
  const w = index.writer();
  w.addDocument({ id: "a" });
  w.commit();
  assert.equal(index.documentCount, 1);
  w.close();
});

test("opstamps match tantivy's IndexWriter", () => {
  const index = Index.inMemory(idSchema());
  const w = index.writer();
  w.addDocument({ id: "a" }); // opstamp 0
  w.addDocument({ id: "b" }); // 1
  assert.equal(w.commit(), 2);
  w.addDocument({ id: "c" }); // 3
  assert.equal(w.rollback(), 2);
  w.addDocument({ id: "c" }); // 2 again: rollback rewinds
  assert.equal(w.commit(), 3);
  w.close();
});

test("rollback discards adds and deletes", () => {
  const index = Index.inMemory(idSchema());
  index.addAll([{ id: "a" }, { id: "b" }]);
  const w = index.writer();
  w.addDocument({ id: "c" });
  w.deleteDocuments("id", "a");
  w.deleteAllDocuments();
  w.rollback();
  w.addDocument({ id: "d" });
  w.commitAndReload();
  w.close();
  assert.deepEqual(ids(index), ["a", "b", "d"]);
});

test("a delete only affects documents added before it", () => {
  const index = Index.inMemory(idSchema());
  index.add({ id: "old" });
  const w = index.writer();
  w.addDocument({ id: "x", body: "first" });
  w.deleteDocuments("id", "x"); // removes the first x
  w.addDocument({ id: "x", body: "second" }); // survives
  w.deleteDocuments("id", "old");
  w.commitAndReload();
  w.close();
  assert.deepEqual(ids(index), ["x"]);
  assert.equal(index.get("id", "x").string("body"), "second");
});

test("upsert replaces in place", () => {
  const index = Index.inMemory(idSchema());
  for (let i = 0; i < 5; i++) index.upsert({ id: "k", n: i }, "id", "k");
  assert.equal(index.documentCount, 1);
  assert.equal(index.get("id", "k").int("n"), 4);
});

test("delete by any-of, by query, and all", () => {
  const index = Index.inMemory(idSchema());
  index.addAll([...Array(10).keys()].map((n) => ({ id: `d${n}`, n })));
  index.write((w) => w.deleteDocumentsAnyOf("id", ["d0", "d1"]));
  assert.equal(index.documentCount, 8);
  index.deleteMatching(Query.closedRange("n", 5, 9));
  assert.deepEqual(ids(index), ["d2", "d3", "d4"]);
  index.write((w) => w.deleteDocuments("n", 3));
  assert.deepEqual(ids(index), ["d2", "d4"]);
  index.write((w) => {
    w.deleteAllDocuments();
    w.addDocument({ id: "fresh" }); // added after the delete-all: kept
  });
  assert.deepEqual(ids(index), ["fresh"]);
});

test("a delete-all followed by commit empties the index", () => {
  const index = Index.inMemory(idSchema());
  index.addAll([{ id: "a" }, { id: "b" }]);
  index.write((w) => w.deleteAllDocuments());
  assert.equal(index.documentCount, 0);
  assert.equal(index.stats().segmentCount, 0);
});

test("a body that throws commits nothing", () => {
  const index = Index.inMemory(idSchema());
  assert.throws(() =>
    index.write((w) => {
      w.addDocument({ id: "a" });
      throw new Error("abort");
    }),
  );
  assert.equal(index.documentCount, 0);
  index.add({ id: "b" }); // the writer lock was released
  assert.equal(index.documentCount, 1);
});

test("one writer at a time", () => {
  const index = Index.inMemory(idSchema());
  const w = index.writer();
  assert.throws(() => index.writer(), (e) => e instanceof TantivyError && /lock/i.test(e.message));
  w.close();
  index.writer().close();
});

test("a writer flushes segments as it outgrows its memory budget", () => {
  const index = Index.inMemory(idSchema());
  const w = index.writer(15_000_000); // the minimum budget
  const text = "lorem ipsum dolor sit amet consectetur adipiscing elit ".repeat(20);
  for (let n = 0; n < 20_000; n++) w.addDocument({ id: `d${n}`, body: `${text} unique${n}`, n });
  w.deleteDocumentsMatching(Query.halfOpenRange("n", 0, 10_000)); // spans the flushed segments
  w.commitAndReload();
  w.close();
  assert.equal(index.documentCount, 10_000);
  assert.equal(index.count(Query.term("body", "unique15000")), 1);
  assert.equal(index.count(Query.term("body", "unique5000")), 0);
});

test("merge compacts segments and drops deleted documents", () => {
  const index = Index.inMemory(idSchema());
  index.addAll([{ id: "a" }, { id: "b" }]);
  for (const id of ["c", "d"]) index.add({ id });
  assert.equal(index.stats().segmentCount, 3);
  index.write((w) => w.deleteDocuments("id", "b"));
  assert.equal(index.stats().deletedCount, 1); // a tombstone in the a+b segment
  index.write((w) => w.deleteDocuments("id", "c"));
  assert.equal(index.stats().segmentCount, 2); // c's segment had nothing left
  index.optimize();
  const s = index.stats();
  assert.equal(s.segmentCount, 1);
  assert.equal(s.deletedCount, 0);
  assert.deepEqual(ids(index), ["a", "d"]);
  index.garbageCollect();
});

test("many small commits are merged by policy", () => {
  const index = Index.inMemory(idSchema());
  const w = index.writer();
  for (let i = 0; i < 40; i++) {
    w.addDocument({ id: `d${i}` });
    w.commit();
  }
  w.close();
  index.reload();
  assert.equal(index.documentCount, 40);
  assert.ok(index.stats().segmentCount < 10, `${index.stats().segmentCount} segments`);
});

test("merged and deleted segments give their memory back", () => {
  const index = Index.inMemory(idSchema());
  const body = "x".repeat(2000);
  const churn = () => {
    const w = index.writer();
    for (let i = 0; i < 500; i++) w.addDocument({ id: `d${i}`, body: `${body} ${i}` });
    w.deleteAllDocuments(); // nothing survives the batch
    for (let i = 0; i < 500; i++) {
      w.deleteDocuments("id", `d${i}`);
      w.addDocument({ id: `d${i}`, body: `${body} ${i}` });
    }
    w.commitAndReload();
    w.close();
    index.optimize();
  };
  churn();
  const settled = index.engine.api.memory.buffer.byteLength;
  for (let round = 0; round < 10; round++) churn();
  assert.equal(index.documentCount, 500);
  // Linear memory never shrinks, so steady state means it stopped growing.
  assert.ok(index.engine.api.memory.buffer.byteLength <= settled * 1.5);
});

test("addDocumentJSON takes a raw JSON document", () => {
  const index = Index.inMemory(idSchema());
  index.write((w) => w.addDocumentJSON('{"id": "j", "n": 3}'));
  assert.equal(index.get("id", "j").int("n"), 3);
});
