// tantivy 0.26.1 in WebAssembly — in-memory, single-threaded — with the API of
// the TantivySwift package.
//
//   import { init, Index, SchemaBuilder, Query } from "@carbon/tantivy";
//   await init();
//   const index = Index.inMemory(new SchemaBuilder().addTextField("title", { stored: true }).build());

export { init, initSync, version, type WasmSource } from "./engine.js";
export { TantivyError } from "./errors.js";
export { SearchHit } from "./hit.js";
export type { DocumentFields, DocumentValue, FieldValue } from "./msgpack.js";
export {
  Query,
  RangeBound,
  type MoreLikeThisOptions,
  type PhrasePosition,
  type QueryNode,
  type TermValue,
  type Token,
} from "./query.js";
export { Analyzer, Schema, SchemaBuilder, type FieldOptions, type TextFieldOptions, type TextIndexing } from "./schema.js";
export {
  Index,
  IndexWriter,
  OrderBy,
  type DeleteValue,
  type FacetCount,
  type IndexStats,
  type ReloadPolicy,
  type SearchOptions,
  type StringQueryOptions,
} from "./search-index.js";
export { CollectionWriter, SearchCollection, type CollectionOptions } from "./collection.js";
