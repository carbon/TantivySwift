// A typed, store-like façade over an `Index` for one kind of model. Mirrors
// Swift's `SearchCollection<Model>`; models are plain objects whose keys are
// field names.

import type { SearchHit } from "./hit.js";
import type { DocumentFields } from "./msgpack.js";
import { Query } from "./query.js";
import { Schema, SchemaBuilder } from "./schema.js";
import {
  Index,
  IndexWriter,
  type DeleteValue,
  type FacetCount,
  type OrderBy,
  type ReloadPolicy,
  type StringQueryOptions,
} from "./search-index.js";

export interface CollectionOptions<Model> {
  reloadPolicy?: ReloadPolicy;
  /**
   * Turn a hit into a model. The default is `hit.toObject(arrays)`: one value
   * per field, or an array when there are several.
   */
  decode?: (hit: SearchHit) => Model;
  /** Fields the default decoder always returns as arrays (multi-valued fields). */
  arrays?: string[];
}

export class SearchCollection<Model extends object> {
  /** The underlying index, for anything the typed API does not cover. */
  readonly index: Index;
  private readonly decode: (hit: SearchHit) => Model;

  constructor(index: Index, options: Pick<CollectionOptions<Model>, "decode" | "arrays"> = {}) {
    this.index = index;
    const arrays = options.arrays ?? [];
    this.decode = options.decode ?? ((hit) => hit.toObject<Model>(arrays));
  }

  /** An in-memory collection, with the schema given or built inline. */
  static inMemory<Model extends object>(
    schema: Schema | ((builder: SchemaBuilder) => void),
    options: CollectionOptions<Model> = {},
  ): SearchCollection<Model> {
    let built: Schema;
    if (schema instanceof Schema) {
      built = schema;
    } else {
      const builder = new SchemaBuilder();
      schema(builder);
      built = builder.build();
    }
    return new SearchCollection(Index.inMemory(built, { reloadPolicy: options.reloadPolicy }), options);
  }

  // -- Writing ------------------------------------------------------------------

  /** Add one model and make it searchable (a commit per call). */
  add(model: Model): void {
    this.index.add(fields(model));
  }

  /** Add many models in one commit. */
  addAll(models: Iterable<Model>): void {
    this.index.write((w) => {
      for (const m of models) w.addDocument(fields(m));
    });
  }

  /** Replace documents whose `idField` equals `id` with `model`, in one commit. */
  upsert(model: Model, idField: string, id: DeleteValue): void {
    this.index.upsert(fields(model), idField, id);
  }

  /** A long-lived typed writer: queue many operations, then `commit()` once. */
  writer(heapSize = 0): CollectionWriter<Model> {
    return new CollectionWriter(this.index.writer(heapSize));
  }

  /** Run a batch of writer operations in one commit. */
  write<R>(body: (writer: IndexWriter) => R): R {
    return this.index.write(body);
  }

  /** Delete every document. */
  removeAll(): void {
    this.index.write((w) => w.deleteAllDocuments());
  }

  /** Delete every document matching `query` (commit and reload). */
  removeMatching(query: Query): void {
    this.index.deleteMatching(query);
  }

  reload(): void {
    this.index.reload();
  }

  // -- Reading ------------------------------------------------------------------

  /** Number of searchable documents. */
  get count(): number {
    return this.index.documentCount;
  }

  /** Number of documents matching `query`, without loading any. */
  countMatching(query: string | Query, options?: StringQueryOptions): number {
    return this.index.count(query, options);
  }

  /** The model whose `idField` equals `id`. */
  get(idField: string, id: string | number | bigint): Model | undefined {
    const hit = this.index.get(idField, id);
    return hit && this.decode(hit);
  }

  search(query: string | Query, options: { limit?: number; orderBy?: OrderBy } & StringQueryOptions = {}): Model[] {
    return this.hits(query, options).map(this.decode);
  }

  /** Search, keeping each match's relevance score. */
  searchScored(
    query: string | Query,
    options: { limit?: number } & StringQueryOptions = {},
  ): { score: number; model: Model }[] {
    return this.hits(query, options).map((hit) => ({ score: hit.score, model: this.decode(hit) }));
  }

  /** Top values of a `fast` field among matching documents. */
  termCounts(field: string, options: { matching?: Query; limit?: number } = {}): FacetCount[] {
    return this.index.termCounts(field, options);
  }

  private hits(query: string | Query, options: { limit?: number; orderBy?: OrderBy } & StringQueryOptions) {
    return typeof query === "string" ? this.index.search(query, options) : this.index.search(query, options);
  }
}

/**
 * A long-lived writer over a collection. Operations queue until `commit()`,
 * which also reloads so they are searchable. `close()` it when done.
 */
export class CollectionWriter<Model extends object> {
  /** The underlying writer, for operations the typed API does not cover. */
  readonly indexWriter: IndexWriter;

  constructor(indexWriter: IndexWriter) {
    this.indexWriter = indexWriter;
  }

  add(model: Model): void {
    this.indexWriter.addDocument(fields(model));
  }

  addAll(models: Iterable<Model>): void {
    for (const m of models) this.add(m);
  }

  /** Queue a replace: delete documents whose `idField` equals `id`, then add `model`. */
  upsert(model: Model, idField: string, id: DeleteValue): void {
    this.indexWriter.deleteDocuments(idField, id);
    this.add(model);
  }

  remove(idField: string, id: DeleteValue): void {
    this.indexWriter.deleteDocuments(idField, id);
  }

  removeMatching(query: Query): void {
    this.indexWriter.deleteDocumentsMatching(query);
  }

  removeAll(): void {
    this.indexWriter.deleteAllDocuments();
  }

  /** Commit and reload, making queued operations searchable. Returns the opstamp. */
  commit(): number {
    return this.indexWriter.commitAndReload();
  }

  rollback(): number {
    return this.indexWriter.rollback();
  }

  close(): void {
    this.indexWriter.close();
  }
}

function fields(model: object): DocumentFields {
  return model as DocumentFields;
}

const dispose = (Symbol as { dispose?: symbol }).dispose;
if (dispose) {
  Object.defineProperty(CollectionWriter.prototype, dispose, {
    value(this: CollectionWriter<object>) {
      this.close();
    },
  });
}
