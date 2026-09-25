// `Index` and `IndexWriter`: the engine's C ABI wrapped the way the Swift
// package wraps it, call for call.

import { Engine } from "./engine.js";
import { TantivyError } from "./errors.js";
import { SearchHit } from "./hit.js";
import { decodeHits, encodeDocument, type DocumentFields, type FieldValue } from "./msgpack.js";
import { Query, type MoreLikeThisOptions, type Token } from "./query.js";
import { Analyzer, Schema } from "./schema.js";
import { boostsJSON, checkFieldName, checkFieldNames, checkNoNUL, usize } from "./values.js";

/** When searches start observing new commits. */
export type ReloadPolicy =
  /** Only after `reload()` (or `commitAndReload()` / the `write` helpers). The default. */
  | "manual"
  /** After every commit, with no `reload()` needed. */
  | "onCommit";

/**
 * Sort hits by a numeric or date fast field instead of relevance. Such hits
 * carry a score of 0.
 */
export interface OrderBy {
  readonly field: string;
  readonly ascending: boolean;
}
export const OrderBy = {
  /** Largest value first (newest date, highest number). */
  descending: (field: string): OrderBy => ({ field, ascending: false }),
  /** Smallest value first. */
  ascending: (field: string): OrderBy => ({ field, ascending: true }),
};

export interface SearchOptions {
  /** Maximum number of hits (0: 10). Default 10. */
  limit?: number;
  /** Stored text fields to produce highlighted snippets for. */
  highlight?: string[];
  /** Maximum snippet length (0: tantivy's default). */
  snippetMaxChars?: number;
  orderBy?: OrderBy;
}

export interface StringQueryOptions {
  /** Fields searched when the query names none (empty: every indexed text field). */
  fields?: string[];
  /** Per-field weights, e.g. `{title: 2, body: 0.5}`. */
  boosts?: Record<string, number>;
}

/** A snapshot of the index's segments and document counts, as of the last reload. */
export interface IndexStats {
  /** Live, searchable documents. */
  documentCount: number;
  /** Deleted but not yet merged away; memory is reclaimed by a merge. */
  deletedCount: number;
  /** `documentCount + deletedCount`. */
  maxDoc: number;
  /** Number of segments; many small ones slow searches. */
  segmentCount: number;
  segments: { id: string; documentCount: number; deletedCount: number; maxDoc: number }[];
}

/** One bucket of `termCounts`: a field value and how many matching documents have it. */
export interface FacetCount {
  value: FieldValue;
  count: number;
}

/** A value `deleteDocuments` can match: a term of a single-token field. */
export type DeleteValue = string | number | bigint | boolean | Uint8Array;

/** Frees a writer that was never closed, so its lock is not held forever. */
const unclosedWriters =
  typeof FinalizationRegistry === "undefined"
    ? undefined
    : new FinalizationRegistry<{ engine: Engine; handle: number }>(({ engine, handle }) => {
        try {
          engine.call(() => engine.api.tantivy_writer_free(handle));
        } catch {
          // The engine crashed; its memory, lock included, goes with it.
        }
      });

/**
 * A full-text index held in memory. Create one with `Index.inMemory` after
 * `await init()`.
 *
 * ```ts
 * const index = Index.inMemory(schema);
 * index.write((w) => w.addDocument({ title: "The Old Man and the Sea" }));
 * for (const hit of index.search("sea")) console.log(hit.score, hit.string("title"));
 * ```
 *
 * Each index runs in its own WebAssembly instance; `close()` releases its
 * memory at once (otherwise it goes when the index is garbage collected).
 */
export class Index {
  readonly schema: Schema;
  /** @internal */
  readonly engine: Engine;
  /** `CIndex *`, or 0 once closed. */
  private handle: number;

  private constructor(schema: Schema, reloadPolicy: ReloadPolicy) {
    this.schema = schema;
    this.engine = new Engine();
    const e = this.engine;
    this.handle = e.call(() =>
      e.withStrings([schema.json], ([schemaC]) =>
        e.api.tantivy_index_open_or_create(0, schemaC!, reloadPolicy === "onCommit" ? 1 : 0, e.err),
      ),
    );
    if (this.handle === 0) throw e.takeError("could not open index");
  }

  /** A new, empty in-memory index. */
  static inMemory(schema: Schema, options: { reloadPolicy?: ReloadPolicy } = {}): Index {
    return new Index(schema, options.reloadPolicy ?? "manual");
  }

  /** @internal The live handle, or a throw once closed. */
  ptr(): number {
    if (this.handle === 0) throw TantivyError.ffi("the index is closed");
    return this.handle;
  }

  /** Release the index. Its writers keep working until they are closed. */
  close(): void {
    if (this.handle === 0) return;
    const handle = this.handle;
    this.handle = 0;
    this.engine.call(() => this.engine.api.tantivy_index_free(handle));
  }

  /**
   * Create a writer. There can be one writer per index at a time; `close()` it
   * (or use `write`) to let the next one in.
   * @param heapSize indexing memory budget in bytes (0: 50 MB, minimum 15 MB).
   */
  writer(heapSize = 0): IndexWriter {
    const heap = usize(heapSize, "heapSize");
    const e = this.engine;
    const w = e.call(() => e.api.tantivy_index_writer(this.ptr(), heap, e.err));
    if (w === 0) throw e.takeError("could not create writer");
    return new IndexWriter(w, this);
  }

  /** Make searches observe the latest commit. */
  reload(): void {
    const e = this.engine;
    if (e.call(() => e.api.tantivy_index_reload(this.ptr(), e.err)) !== 0) {
      throw e.takeError("reload failed");
    }
  }

  /** Number of searchable documents as of the last reload. */
  get documentCount(): number {
    const e = this.engine;
    const n = e.call(() => e.api.tantivy_index_num_docs(this.ptr(), e.err));
    if (n < 0n) {
      e.takeError("");
      return 0;
    }
    return Number(n);
  }

  // -- Searching ------------------------------------------------------------

  /**
   * Search with a query string in tantivy syntax (`"sea"`, `"title:whale"`,
   * `"\"old man\""`, `"body:fish AND title:sea"`) or a structured `Query`.
   */
  search(query: string, options?: SearchOptions & StringQueryOptions): SearchHit[];
  search(query: Query, options?: SearchOptions): SearchHit[];
  search(query: string | Query, options: SearchOptions & StringQueryOptions = {}): SearchHit[] {
    const limit = usize(options.limit ?? 10, "limit");
    const snippetMaxChars = usize(options.snippetMaxChars ?? 0, "snippetMaxChars");
    const highlight = options.highlight ?? [];
    checkFieldNames(highlight, "highlight");
    if (options.orderBy) checkFieldName(options.orderBy.field, "order-by");
    const snippets = csv(highlight);
    const orderBy = options.orderBy?.field || null;
    const ascending = options.orderBy?.ascending ? 1 : 0;
    const e = this.engine;

    let result: number;
    if (typeof query === "string") {
      checkNoNUL(query, "query string");
      const fields = options.fields ?? [];
      checkFieldNames(fields, "default");
      const boosts = boostsJSON(options.boosts ?? {});
      result = e.call(() =>
        e.withStrings([query, csv(fields), boosts, snippets, orderBy], ([q, f, b, s, o]) =>
          e.api.tantivy_index_search(this.ptr(), q!, f!, b!, s!, snippetMaxChars, limit, o!, ascending, e.err),
        ),
      );
    } else {
      const json = query.jsonString();
      result = e.call(() =>
        e.withStrings([json, snippets, orderBy], ([q, s, o]) =>
          e.api.tantivy_index_search_query(this.ptr(), q!, s!, snippetMaxChars, limit, o!, ascending, e.err),
        ),
      );
    }
    if (result === 0) throw e.takeError("search failed");
    return decodeHits(e.call(() => e.takeResult(result))).map((hit) => new SearchHit(hit));
  }

  /** Number of documents matching `query`, without loading any — not capped by a limit. */
  count(query: string | Query, options: StringQueryOptions = {}): number {
    const e = this.engine;
    let n: bigint;
    if (typeof query === "string") {
      checkNoNUL(query, "query string");
      const fields = options.fields ?? [];
      checkFieldNames(fields, "default");
      const boosts = boostsJSON(options.boosts ?? {});
      n = e.call(() =>
        e.withStrings([query, csv(fields), boosts], ([q, f, b]) =>
          e.api.tantivy_index_count(this.ptr(), q!, f!, b!, e.err),
        ),
      );
    } else {
      const json = query.jsonString();
      n = e.call(() => e.withStrings([json], ([q]) => e.api.tantivy_index_count_query(this.ptr(), q!, e.err)));
    }
    if (n < 0n) throw e.takeError("count failed");
    return Number(n);
  }

  /**
   * The first document whose `field` equals `value` — a scoreless fetch by
   * id. Use a single-token field.
   */
  get(field: string, value: string | number | bigint): SearchHit | undefined {
    return this.search(Query.term(field, value), { limit: 1 })[0];
  }

  /**
   * Documents similar to the one whose `idField` equals `id`, excluding it.
   * The compared `fields` must be stored. Empty if there is no such document.
   */
  moreLikeThis(args: {
    idField: string;
    id: string;
    fields: string[];
    options?: MoreLikeThisOptions;
    limit?: number;
  }): SearchHit[] {
    const source = this.get(args.idField, args.id);
    if (!source) return [];
    const like: Record<string, string[]> = {};
    for (const field of args.fields) {
      const strings = source.values(field).filter((v): v is string => typeof v === "string");
      if (strings.length) like[field] = strings;
    }
    if (Object.keys(like).length === 0) return [];
    const query = Query.moreLikeThis(like, args.options).excluding(Query.term(args.idField, args.id));
    return this.search(query, { limit: args.limit ?? 10 });
  }

  // -- Analysis, stats, aggregations -----------------------------------------

  /** The tokens `analyzer` makes of `text` — what the index would store. */
  analyze(text: string, analyzer: Analyzer): Token[] {
    checkNoNUL(text, "analyzed text");
    checkNoNUL(analyzer, "tokenizer name");
    const e = this.engine;
    const raw = e.call(() =>
      e.withStrings([analyzer, text], ([t, s]) => e.api.tantivy_index_analyze(this.ptr(), t!, s!, e.err)),
    );
    if (raw === 0) throw e.takeError("analyze failed");
    const tokens = JSON.parse(e.takeString(raw)) as {
      text: string;
      position: number;
      offset_from: number;
      offset_to: number;
    }[];
    return tokens.map((t) => ({
      text: t.text,
      position: t.position,
      offsetFrom: t.offset_from,
      offsetTo: t.offset_to,
    }));
  }

  /** Document counts and segment layout, as of the last reload. */
  stats(): IndexStats {
    const e = this.engine;
    const raw = e.call(() => e.api.tantivy_index_stats(this.ptr(), e.err));
    if (raw === 0) throw e.takeError("stats failed");
    interface Counts {
      num_docs: number;
      num_deleted: number;
      max_doc: number;
    }
    const s = JSON.parse(e.takeString(raw)) as Counts & {
      num_segments: number;
      segments: (Counts & { id: string })[];
    };
    return {
      documentCount: s.num_docs,
      deletedCount: s.num_deleted,
      maxDoc: s.max_doc,
      segmentCount: s.num_segments,
      segments: s.segments.map((x) => ({
        id: x.id,
        documentCount: x.num_docs,
        deletedCount: x.num_deleted,
        maxDoc: x.max_doc,
      })),
    };
  }

  /**
   * Top `limit` values of `field` (which must be `fast`) among documents
   * matching `matching`, most frequent first — the facet sidebar.
   */
  termCounts(field: string, options: { matching?: Query; limit?: number } = {}): FacetCount[] {
    checkNoNUL(field, `termCounts field name '${field}'`);
    const limit = options.limit ?? 10;
    if (!Number.isInteger(limit) || limit < 0) {
      throw TantivyError.encoding(`limit must be non-negative (got ${limit})`);
    }
    const result = this.aggregate({ counts: { terms: { field, size: limit } } }, options.matching) as {
      counts: { buckets: { key: FieldValue; doc_count: number }[] };
    };
    return result.counts.buckets.map((b) => ({ value: b.key, count: b.doc_count }));
  }

  /**
   * Run a tantivy (Elasticsearch-compatible) aggregation over documents
   * matching `matching` — e.g. `{avg_year: {avg: {field: "year"}}}`. Returns
   * the parsed result. Aggregated fields must be `fast`.
   */
  aggregate(request: string | object, matching: Query = Query.matchAll): unknown {
    const text = typeof request === "string" ? request : JSON.stringify(request);
    checkNoNUL(text, "aggregation request");
    const json = matching.jsonString();
    const e = this.engine;
    const raw = e.call(() =>
      e.withStrings([json, text], ([q, a]) => e.api.tantivy_index_aggregate(this.ptr(), q!, a!, e.err)),
    );
    if (raw === 0) throw e.takeError("aggregation failed");
    return JSON.parse(e.takeString(raw));
  }

  // -- Maintenance ------------------------------------------------------------

  /**
   * Merge every segment into one, then reload: reclaims the memory deleted
   * documents still hold and speeds up search on a fragmented index. Opens a
   * writer, so none may be open.
   */
  optimize(heapSize = 0): void {
    this.withWriter(heapSize, (w) => w.merge());
    this.reload();
  }

  /** Free segment files nothing refers to any more. Opens a writer. */
  garbageCollect(heapSize = 0): void {
    this.withWriter(heapSize, (w) => w.garbageCollect());
  }

  // -- Helpers ------------------------------------------------------------------

  /**
   * Run `body` with a fresh writer, then commit and reload. If `body` throws,
   * nothing is committed. One writer, commit and reload per call — batch many
   * documents into one call rather than calling it in a loop.
   */
  write<R>(body: (writer: IndexWriter) => R, heapSize = 0): R {
    return this.withWriter(heapSize, (w) => {
      const result = body(w);
      w.commit();
      this.reload();
      return result;
    });
  }

  private withWriter<R>(heapSize: number, body: (writer: IndexWriter) => R): R {
    const w = this.writer(heapSize);
    try {
      return body(w);
    } finally {
      w.close();
    }
  }

  /** Add one document and make it searchable (a commit per call). */
  add(document: DocumentFields): void {
    this.write((w) => w.addDocument(document));
  }

  /** Add many documents in one commit. */
  addAll(documents: Iterable<DocumentFields>): void {
    this.write((w) => {
      for (const d of documents) w.addDocument(d);
    });
  }

  /** Replace documents whose `idField` equals `id` with `document`, in one commit. */
  upsert(document: DocumentFields, idField: string, id: DeleteValue): void {
    this.write((w) => {
      w.deleteDocuments(idField, id);
      w.addDocument(document);
    });
  }

  /** Delete every document matching `query`, then commit and reload. */
  deleteMatching(query: Query): void {
    this.write((w) => w.deleteDocumentsMatching(query));
  }
}

/**
 * Adds and removes documents. Create with `Index.writer()`; operations queue
 * until `commit()`, and are searchable after a reload (`commitAndReload()`).
 *
 * `close()` a writer when done: it holds the index's single-writer lock, and
 * discards anything uncommitted. Keep one writer across many documents and
 * commit in batches — a commit per document is far slower.
 */
export class IndexWriter {
  /** The index this writer writes to. */
  readonly index: Index;
  private handle: number;
  private readonly engine: Engine;

  /** @internal */
  constructor(handle: number, index: Index) {
    this.handle = handle;
    this.index = index;
    this.engine = index.engine;
    unclosedWriters?.register(this, { engine: this.engine, handle }, this);
  }

  private ptr(): number {
    if (this.handle === 0) throw TantivyError.ffi("the writer is closed");
    return this.handle;
  }

  /** Release the writer and its lock, discarding uncommitted operations. */
  close(): void {
    if (this.handle === 0) return;
    const handle = this.handle;
    this.handle = 0;
    unclosedWriters?.unregister(this);
    this.engine.call(() => this.engine.api.tantivy_writer_free(handle));
  }

  /** Run a call returning 0 / -1, throwing the engine's error on -1. */
  private status(fallback: string, call: (err: number) => number): void {
    const e = this.engine;
    if (e.call(() => call(e.err)) !== 0) throw e.takeError(fallback);
  }

  /**
   * Add a document: `{title: "Hi", tags: ["a", "b"], year: 1952}`. Arrays are
   * multi-valued fields; `Date` suits date fields and `Uint8Array` bytes
   * fields; `undefined` values are skipped.
   */
  addDocument(fields: DocumentFields): void {
    const payload = encodeDocument(fields);
    const e = this.engine;
    this.status("add document failed", (err) =>
      e.withBytes(payload, (ptr, len) => e.api.tantivy_writer_add_msgpack(this.ptr(), ptr, len, err)),
    );
  }

  /** Add a document from a JSON object string — the escape hatch for JSON you already have. */
  addDocumentJSON(json: string): void {
    checkNoNUL(json, "document JSON");
    const e = this.engine;
    this.status("add document failed", (err) =>
      e.withStrings([json], ([j]) => e.api.tantivy_writer_add_json(this.ptr(), j!, err)),
    );
  }

  /** Commit queued operations. Returns the opstamp. */
  commit(): number {
    const e = this.engine;
    const opstamp = e.call(() => e.api.tantivy_writer_commit(this.ptr(), e.err));
    if (opstamp < 0n) throw e.takeError("commit failed");
    return Number(opstamp);
  }

  /** Commit and reload the index, so the changes are searchable at once. */
  commitAndReload(): number {
    const opstamp = this.commit();
    this.index.reload();
    return opstamp;
  }

  /** Discard every operation queued since the last commit. Returns the opstamp rolled back to. */
  rollback(): number {
    const e = this.engine;
    const opstamp = e.call(() => e.api.tantivy_writer_rollback(this.ptr(), e.err));
    if (opstamp < 0n) throw e.takeError("rollback failed");
    return Number(opstamp);
  }

  /** Queue deletion of every document. */
  deleteAllDocuments(): void {
    this.status("delete all failed", (err) => this.engine.api.tantivy_writer_delete_all(this.ptr(), err));
  }

  /**
   * Queue deletion of documents whose `field` equals `value`. Meant for a
   * single-token field — `string`, numeric, bool or bytes — as the delete half
   * of an upsert; on a tokenized text field it matches one token.
   */
  deleteDocuments(field: string, value: DeleteValue): void {
    checkNoNUL(field, `delete field name '${field}'`);
    const e = this.engine;
    if (value instanceof Uint8Array) {
      this.status("delete term failed", (err) =>
        e.withStrings([field], ([f]) =>
          e.withBytes(value, (ptr, len) => e.api.tantivy_writer_delete_term_bytes(this.ptr(), f!, ptr, len, err)),
        ),
      );
      return;
    }
    const json = deleteValueJSON(value);
    this.status("delete term failed", (err) =>
      e.withStrings([field, json], ([f, v]) => e.api.tantivy_writer_delete_term(this.ptr(), f!, v!, err)),
    );
  }

  /** Queue deletion of documents whose `field` equals any of `values`. No-op when empty. */
  deleteDocumentsAnyOf(field: string, values: readonly DeleteValue[]): void {
    if (values.length === 0) return;
    this.deleteDocumentsMatching(Query.anyOf(values.map((v) => Query.term(field, v))));
  }

  /**
   * Queue deletion of every document matching `query` (unscored, so not
   * `moreLikeThis`). Affects documents added before this call.
   */
  deleteDocumentsMatching(query: Query): void {
    const json = query.jsonString();
    const e = this.engine;
    this.status("delete query failed", (err) =>
      e.withStrings([json], ([q]) => e.api.tantivy_writer_delete_query(this.ptr(), q!, err)),
    );
  }

  /**
   * Merge every committed segment into one. Reclaims deleted documents'
   * memory; costly on a large index, so run it when `stats()` says it pays.
   */
  merge(): void {
    this.status("merge failed", (err) => this.engine.api.tantivy_writer_merge(this.ptr(), err));
  }

  /** Free segment files nothing refers to. Commits and merges already do this. */
  garbageCollect(): void {
    this.status("garbage collect failed", (err) =>
      this.engine.api.tantivy_writer_garbage_collect(this.ptr(), err),
    );
  }
}

function deleteValueJSON(value: DeleteValue): string {
  switch (typeof value) {
    case "string":
      return JSON.stringify(value);
    case "boolean":
      return value ? "true" : "false";
    case "bigint":
      return value.toString();
    case "number":
      if (!Number.isFinite(value)) throw TantivyError.encoding("non-finite number in delete term");
      return JSON.stringify(value);
  }
  throw TantivyError.encoding(`unsupported delete term value ${Object.prototype.toString.call(value)}`);
}

function csv(names: readonly string[]): string | null {
  return names.length ? names.join(",") : null;
}

// `using` support where the runtime has explicit resource management.
const dispose = (Symbol as { dispose?: symbol }).dispose;
if (dispose) {
  for (const type of [Index, IndexWriter]) {
    Object.defineProperty(type.prototype, dispose, {
      value(this: { close(): void }) {
        this.close();
      },
    });
  }
}
