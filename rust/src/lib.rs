//! C ABI over tantivy 0.26.1, designed to back a Swift package.
//!
//! The surface is intentionally small and JSON-oriented so the Swift side can
//! offer a clean, typed API without marshalling individual field values across
//! the boundary:
//!
//!   * schema is described with a small JSON spec
//!   * documents are added as JSON objects (`TantivyDocument::parse_json`)
//!   * search returns a JSON envelope of hits (score + stored fields)
//!
//! Error handling convention: fallible functions take an `out_error: *mut *mut
//! c_char`. On failure they return a sentinel (null / -1) and, if `out_error`
//! is non-null, write a heap-allocated C string describing the error. The
//! caller owns that string and must release it with `tantivy_string_free`.

// Raw-pointer parameters are the C ABI itself; every dereference is
// null-checked. Marking each export `unsafe` would change nothing for the
// Swift caller.
#![allow(clippy::not_unsafe_ptr_arg_deref)]

use std::ffi::{c_char, CStr, CString};
use std::os::raw::c_int;
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::ptr;

use std::ops::Bound;

use serde_json::json;
use tantivy::collector::{Count, TopDocs};
use tantivy::directory::MmapDirectory;
use tantivy::aggregation::agg_req::Aggregations;
use tantivy::aggregation::AggregationCollector;
use tantivy::query::{
    AllQuery, BooleanQuery, BoostQuery, FuzzyTermQuery, Occur, PhrasePrefixQuery, PhraseQuery,
    Query, QueryParser, RangeQuery, RegexQuery, TermQuery,
};
use tantivy::schema::document::Document;
use tantivy::schema::{
    DateOptions, Field, FieldType, IndexRecordOption, NumericOptions, Schema, TantivyDocument, Term,
    TextFieldIndexing, TextOptions,
};
use tantivy::snippet::SnippetGenerator;
use tantivy::tokenizer::{
    Language, LowerCaser, RawTokenizer, RemoveLongFilter, SimpleTokenizer, Stemmer, TextAnalyzer,
};
use tantivy::{DateTime, Index, IndexReader, IndexWriter, Order, ReloadPolicy};
use time::format_description::well_known::Rfc3339;
use time::OffsetDateTime;

// ---------------------------------------------------------------------------
// Opaque handles
// ---------------------------------------------------------------------------

/// Backing object for a Swift `Index`. Bundles the index, a reader, and the
/// schema (kept so we can render stored documents back to JSON on search).
pub struct CIndex {
    index: Index,
    reader: IndexReader,
    schema: Schema,
}

/// Backing object for a Swift `IndexWriter`.
pub struct CWriter {
    writer: IndexWriter,
}

// ---------------------------------------------------------------------------
// Small helpers
// ---------------------------------------------------------------------------

/// Write `msg` into `out_error` as an owned C string (no-op if null).
fn set_error(out_error: *mut *mut c_char, msg: impl Into<String>) {
    if out_error.is_null() {
        return;
    }
    let c = CString::new(msg.into()).unwrap_or_else(|_| CString::new("error").unwrap());
    unsafe { *out_error = c.into_raw() };
}

/// Borrow a `*const c_char` as `&str`. Returns `None` for null/invalid-UTF8.
unsafe fn opt_str<'a>(p: *const c_char) -> Option<&'a str> {
    if p.is_null() {
        return None;
    }
    CStr::from_ptr(p).to_str().ok()
}

/// Run `f`, turning panics into an error written to `out_error` and returning
/// `sentinel`. Keeps unwinding from crossing the FFI boundary (UB).
fn guard<T>(out_error: *mut *mut c_char, sentinel: T, f: impl FnOnce() -> Result<T, String>) -> T {
    match catch_unwind(AssertUnwindSafe(f)) {
        Ok(Ok(v)) => v,
        Ok(Err(e)) => {
            set_error(out_error, e);
            sentinel
        }
        Err(_) => {
            set_error(out_error, "tantivy_ffi: internal panic");
            sentinel
        }
    }
}

// ---------------------------------------------------------------------------
// Schema construction from a small JSON spec
// ---------------------------------------------------------------------------
//
// {
//   "fields": [
//     {"name":"title","type":"text","stored":true,"indexed":true,
//      "tokenizer":"default","record":"position","fast":false},
//     {"name":"id","type":"u64","stored":true,"indexed":true,"fast":true}
//   ]
// }
//
// types: text | string | u64 | i64 | f64 | bool
//   - text   : tokenized full-text (default tokenizer / positions by default)
//   - string : single raw token, exact-match (tokenizer "raw")

fn build_schema(spec: &str) -> Result<Schema, String> {
    let v: serde_json::Value =
        serde_json::from_str(spec).map_err(|e| format!("invalid schema JSON: {e}"))?;
    let fields = v
        .get("fields")
        .and_then(|f| f.as_array())
        .ok_or("schema JSON must contain a 'fields' array")?;

    let mut b = Schema::builder();
    for f in fields {
        let name = f
            .get("name")
            .and_then(|x| x.as_str())
            .ok_or("each field needs a string 'name'")?;
        let ftype = f
            .get("type")
            .and_then(|x| x.as_str())
            .ok_or_else(|| format!("field '{name}' needs a string 'type'"))?;
        let stored = f.get("stored").and_then(|x| x.as_bool()).unwrap_or(false);
        let indexed = f.get("indexed").and_then(|x| x.as_bool()).unwrap_or(true);
        let fast = f.get("fast").and_then(|x| x.as_bool()).unwrap_or(false);

        match ftype {
            "text" | "string" => {
                let is_raw = ftype == "string";
                let tokenizer = f
                    .get("tokenizer")
                    .and_then(|x| x.as_str())
                    .unwrap_or(if is_raw { "raw" } else { "default" });
                let record = match f.get("record").and_then(|x| x.as_str()) {
                    Some("basic") => IndexRecordOption::Basic,
                    Some("freq") => IndexRecordOption::WithFreqs,
                    _ if is_raw => IndexRecordOption::Basic,
                    _ => IndexRecordOption::WithFreqsAndPositions,
                };
                let mut opts = TextOptions::default();
                if indexed {
                    opts = opts.set_indexing_options(
                        TextFieldIndexing::default()
                            .set_tokenizer(tokenizer)
                            .set_index_option(record),
                    );
                }
                if stored {
                    opts = opts.set_stored();
                }
                if fast {
                    opts = opts.set_fast(Some(tokenizer));
                }
                b.add_text_field(name, opts);
            }
            "u64" | "i64" | "f64" | "bool" => {
                let mut opts = NumericOptions::default();
                if stored {
                    opts = opts.set_stored();
                }
                if indexed {
                    opts = opts.set_indexed();
                }
                if fast {
                    opts = opts.set_fast();
                }
                match ftype {
                    "u64" => b.add_u64_field(name, opts),
                    "i64" => b.add_i64_field(name, opts),
                    "f64" => b.add_f64_field(name, opts),
                    "bool" => b.add_bool_field(name, opts),
                    _ => unreachable!(),
                };
            }
            "date" => {
                // Dates are added/returned as RFC3339 strings.
                let mut opts = DateOptions::default();
                if stored {
                    opts = opts.set_stored();
                }
                if indexed {
                    opts = opts.set_indexed();
                }
                if fast {
                    opts = opts.set_fast();
                }
                b.add_date_field(name, opts);
            }
            other => return Err(format!("field '{name}': unsupported type '{other}'")),
        }
    }
    Ok(b.build())
}

/// Register the extra named analyzers we ship on top of tantivy's built-ins
/// (`default`, `raw`, `en_stem`, `whitespace`). These live in the in-memory
/// tokenizer manager, so they must be re-registered every time an index is
/// opened — the schema only persists the tokenizer *name* per field.
///
///  * `en`        — alias of `en_stem` (lowercased, English-stemmed full text)
///  * `lowercase` — one lowercased token per value, for case-insensitive exact
///                  match (tags, authors, enums, ids)
fn register_analyzers(index: &Index) {
    let en = TextAnalyzer::builder(SimpleTokenizer::default())
        .filter(RemoveLongFilter::limit(40))
        .filter(LowerCaser)
        .filter(Stemmer::new(Language::English))
        .build();

    let lowercase = TextAnalyzer::builder(RawTokenizer::default())
        .filter(LowerCaser)
        .build();

    // Register into BOTH the indexing/search tokenizer manager and the
    // fast-field tokenizer manager. A `fast: true` text field builds its
    // columnar values through the latter, which otherwise knows only tantivy's
    // built-ins and fails at commit with `Tokenizer "<name>" not found`.
    for manager in [index.tokenizers(), index.fast_field_tokenizer()] {
        manager.register("en", en.clone());
        manager.register("lowercase", lowercase.clone());
    }
}

/// All indexed text fields — used as the query parser's default fields when the
/// caller doesn't specify any.
fn default_text_fields(schema: &Schema) -> Vec<Field> {
    schema
        .fields()
        .filter(|(_, e)| e.is_indexed() && matches!(e.field_type(), FieldType::Str(_)))
        .map(|(f, _)| f)
        .collect()
}

// ---------------------------------------------------------------------------
// Index lifecycle
// ---------------------------------------------------------------------------

/// Open an existing index, or create one with `schema_json`.
///
/// `path` null or empty -> an in-RAM index (not persisted).
/// Otherwise `path` must be a directory; it is created if missing.
///
/// `reload_on_commit` non-zero -> the reader reloads itself shortly after each
/// commit (tantivy's `OnCommitWithDelay`); zero -> reload only via
/// `tantivy_index_reload` (manual).
///
/// Returns null on error.
#[no_mangle]
pub extern "C" fn tantivy_index_open_or_create(
    path: *const c_char,
    schema_json: *const c_char,
    reload_on_commit: c_int,
    out_error: *mut *mut c_char,
) -> *mut CIndex {
    guard(out_error, ptr::null_mut(), || {
        let spec = unsafe { opt_str(schema_json) }.ok_or("schema_json must be valid UTF-8")?;
        let schema = build_schema(spec)?;

        let path = unsafe { opt_str(path) }.filter(|s| !s.is_empty());
        let index = match path {
            None => Index::create_in_ram(schema.clone()),
            Some(dir) => {
                std::fs::create_dir_all(dir)
                    .map_err(|e| format!("could not create directory '{dir}': {e}"))?;
                let mmap = MmapDirectory::open(dir)
                    .map_err(|e| format!("could not open directory '{dir}': {e}"))?;
                Index::open_or_create(mmap, schema.clone())
                    .map_err(|e| format!("open_or_create failed: {e}"))?
            }
        };

        register_analyzers(&index);

        let policy = if reload_on_commit != 0 {
            ReloadPolicy::OnCommitWithDelay
        } else {
            ReloadPolicy::Manual
        };
        let reader = index
            .reader_builder()
            .reload_policy(policy)
            .try_into()
            .map_err(|e| format!("reader init failed: {e}"))?;

        let boxed = Box::new(CIndex {
            index,
            reader,
            schema,
        });
        Ok(Box::into_raw(boxed))
    })
}

/// Release an index handle.
#[no_mangle]
pub extern "C" fn tantivy_index_free(index: *mut CIndex) {
    if !index.is_null() {
        unsafe { drop(Box::from_raw(index)) };
    }
}

/// Reload the index reader so subsequent searches observe the latest commit.
/// Returns 0 on success, -1 on error.
#[no_mangle]
pub extern "C" fn tantivy_index_reload(index: *mut CIndex, out_error: *mut *mut c_char) -> c_int {
    guard(out_error, -1, || {
        let idx = unsafe { index.as_ref() }.ok_or("index handle is null")?;
        idx.reader
            .reload()
            .map_err(|e| format!("reload failed: {e}"))?;
        Ok(0)
    })
}

// ---------------------------------------------------------------------------
// Writing
// ---------------------------------------------------------------------------

/// Create a writer with `heap_size_bytes` of indexing memory (min ~15MB; pass 0
/// for a 50MB default). There must be at most one writer per index at a time.
/// Returns null on error.
#[no_mangle]
pub extern "C" fn tantivy_index_writer(
    index: *mut CIndex,
    heap_size_bytes: usize,
    out_error: *mut *mut c_char,
) -> *mut CWriter {
    guard(out_error, ptr::null_mut(), || {
        let idx = unsafe { index.as_ref() }.ok_or("index handle is null")?;
        let heap = if heap_size_bytes == 0 {
            50_000_000
        } else {
            heap_size_bytes
        };
        let writer: IndexWriter = idx
            .index
            .writer(heap)
            .map_err(|e| format!("could not create writer: {e}"))?;
        Ok(Box::into_raw(Box::new(CWriter { writer })))
    })
}

/// Release a writer handle. Does not commit; call `tantivy_writer_commit` first
/// to persist queued documents.
#[no_mangle]
pub extern "C" fn tantivy_writer_free(writer: *mut CWriter) {
    if !writer.is_null() {
        unsafe { drop(Box::from_raw(writer)) };
    }
}

/// Add one document, given as a JSON object whose keys are field names. Values
/// may be scalars or arrays (for multi-valued fields). Returns 0 on success,
/// -1 on error. Documents are only searchable after a commit.
#[no_mangle]
pub extern "C" fn tantivy_writer_add_json(
    writer: *mut CWriter,
    doc_json: *const c_char,
    out_error: *mut *mut c_char,
) -> c_int {
    guard(out_error, -1, || {
        let w = unsafe { writer.as_ref() }.ok_or("writer handle is null")?;
        let json = unsafe { opt_str(doc_json) }.ok_or("doc_json must be valid UTF-8")?;
        let schema = w.writer.index().schema();
        let doc = TantivyDocument::parse_json(&schema, json)
            .map_err(|e| format!("could not parse document: {e}"))?;
        w.writer
            .add_document(doc)
            .map_err(|e| format!("add_document failed: {e}"))?;
        Ok(0)
    })
}

/// Commit queued operations, making them durable and searchable (after a
/// reader reload). Returns the commit opstamp, or -1 on error.
#[no_mangle]
pub extern "C" fn tantivy_writer_commit(writer: *mut CWriter, out_error: *mut *mut c_char) -> i64 {
    guard(out_error, -1, || {
        let w = unsafe { writer.as_mut() }.ok_or("writer handle is null")?;
        let opstamp = w
            .writer
            .commit()
            .map_err(|e| format!("commit failed: {e}"))?;
        Ok(opstamp as i64)
    })
}

/// Roll back to the last commit, discarding every operation (add/delete) queued
/// since. Returns the opstamp rolled back to, or -1 on error.
#[no_mangle]
pub extern "C" fn tantivy_writer_rollback(writer: *mut CWriter, out_error: *mut *mut c_char) -> i64 {
    guard(out_error, -1, || {
        let w = unsafe { writer.as_mut() }.ok_or("writer handle is null")?;
        let opstamp = w
            .writer
            .rollback()
            .map_err(|e| format!("rollback failed: {e}"))?;
        Ok(opstamp as i64)
    })
}

/// Delete every document in the index (takes effect on the next commit).
/// Returns 0 on success, -1 on error.
#[no_mangle]
pub extern "C" fn tantivy_writer_delete_all(
    writer: *mut CWriter,
    out_error: *mut *mut c_char,
) -> c_int {
    guard(out_error, -1, || {
        let w = unsafe { writer.as_ref() }.ok_or("writer handle is null")?;
        w.writer
            .delete_all_documents()
            .map_err(|e| format!("delete_all failed: {e}"))?;
        Ok(0)
    })
}

/// Delete all documents whose `field` contains the indexed term parsed from
/// `value_json` (a JSON scalar). Use this on a single-token field — a `string`
/// (raw) or numeric/bool id field — to implement replace/upsert (delete then
/// add the new document, ideally in one commit). On a tokenized text field it
/// matches a single token, not the whole value.
///
/// Takes effect on the next commit. Returns 0 on success, -1 on error.
#[no_mangle]
pub extern "C" fn tantivy_writer_delete_term(
    writer: *mut CWriter,
    field: *const c_char,
    value_json: *const c_char,
    out_error: *mut *mut c_char,
) -> c_int {
    guard(out_error, -1, || {
        let w = unsafe { writer.as_ref() }.ok_or("writer handle is null")?;
        let field_name = unsafe { opt_str(field) }.ok_or("field must be valid UTF-8")?;
        let value_str = unsafe { opt_str(value_json) }.ok_or("value_json must be valid UTF-8")?;
        let value: serde_json::Value =
            serde_json::from_str(value_str).map_err(|e| format!("invalid value JSON: {e}"))?;

        let schema = w.writer.index().schema();
        let f = schema
            .get_field(field_name)
            .map_err(|_| format!("unknown field: '{field_name}'"))?;

        let term = match schema.get_field_entry(f).field_type() {
            FieldType::Str(_) => {
                let s = value
                    .as_str()
                    .ok_or_else(|| format!("field '{field_name}' expects a string value"))?;
                Term::from_field_text(f, s)
            }
            FieldType::U64(_) => Term::from_field_u64(
                f,
                value
                    .as_u64()
                    .ok_or_else(|| format!("field '{field_name}' expects a u64 value"))?,
            ),
            FieldType::I64(_) => Term::from_field_i64(
                f,
                value
                    .as_i64()
                    .ok_or_else(|| format!("field '{field_name}' expects an i64 value"))?,
            ),
            FieldType::F64(_) => Term::from_field_f64(
                f,
                value
                    .as_f64()
                    .ok_or_else(|| format!("field '{field_name}' expects an f64 value"))?,
            ),
            FieldType::Bool(_) => Term::from_field_bool(
                f,
                value
                    .as_bool()
                    .ok_or_else(|| format!("field '{field_name}' expects a bool value"))?,
            ),
            _ => {
                return Err(format!(
                    "delete by term is not supported for field '{field_name}' (use a string/numeric/bool field)"
                ))
            }
        };

        w.writer.delete_term(term);
        Ok(0)
    })
}

/// Delete all documents matching a structured query (same JSON grammar as
/// `tantivy_index_search_query`: all / term / fuzzy / phrase / range / boost /
/// boolean). This is the query-based counterpart to `tantivy_writer_delete_term`
/// — use it to delete by range, by several terms (a boolean `should`), etc.
///
/// Only affects documents from previous commits (or added earlier in the current
/// commit). Takes effect on the next commit. Returns 0 on success, -1 on error.
#[no_mangle]
pub extern "C" fn tantivy_writer_delete_query(
    writer: *mut CWriter,
    query_json: *const c_char,
    out_error: *mut *mut c_char,
) -> c_int {
    guard(out_error, -1, || {
        let w = unsafe { writer.as_ref() }.ok_or("writer handle is null")?;
        let qjson = unsafe { opt_str(query_json) }.ok_or("query_json must be valid UTF-8")?;
        let tree: serde_json::Value =
            serde_json::from_str(qjson).map_err(|e| format!("invalid query JSON: {e}"))?;
        let index = w.writer.index();
        let schema = index.schema();
        let query = build_query(index, &schema, &tree)?;
        w.writer
            .delete_query(query)
            .map_err(|e| format!("delete_query failed: {e}"))?;
        Ok(0)
    })
}

// ---------------------------------------------------------------------------
// Searching
// ---------------------------------------------------------------------------

/// Parse `query` (tantivy query syntax) and return the top `limit` hits as a
/// JSON string:
///
///   {"hits":[{"score":1.23,"doc":{"title":["..."],"id":[7]}}, ...]}
///
/// `default_fields_csv` is a comma-separated list of field names searched when
/// the query doesn't name a field. Null/empty -> all indexed text fields.
///
/// `boosts_json` is an optional JSON object of `{"field": boost, ...}` applied as
/// per-field weights (null/empty -> none).
///
/// Returns a heap C string (free with `tantivy_string_free`), or null on error.
/// Build a parsed query from tantivy's string query syntax, applying optional
/// default fields and per-field boosts. Shared by search and count.
fn parse_string_query(
    idx: &CIndex,
    query: &str,
    default_fields_csv: Option<&str>,
    boosts_json: Option<&str>,
) -> Result<Box<dyn Query>, String> {
    let fields: Vec<Field> = match default_fields_csv.map(str::trim).filter(|s| !s.is_empty()) {
        None => default_text_fields(&idx.schema),
        Some(csv) => {
            let mut v = Vec::new();
            for name in csv.split(',').map(str::trim).filter(|s| !s.is_empty()) {
                let f = idx
                    .schema
                    .get_field(name)
                    .map_err(|_| format!("unknown field in default fields: '{name}'"))?;
                v.push(f);
            }
            v
        }
    };

    let mut parser = QueryParser::for_index(&idx.index, fields);

    // Apply optional per-field boosts.
    if let Some(spec) = boosts_json.filter(|s| !s.is_empty()) {
        let map: serde_json::Value =
            serde_json::from_str(spec).map_err(|e| format!("invalid boosts JSON: {e}"))?;
        if let Some(obj) = map.as_object() {
            for (name, val) in obj {
                let f = idx
                    .schema
                    .get_field(name)
                    .map_err(|_| format!("unknown field in boosts: '{name}'"))?;
                let boost = val
                    .as_f64()
                    .ok_or_else(|| format!("boost for '{name}' must be a number"))?;
                parser.set_field_boost(f, boost as f32);
            }
        }
    }

    parser
        .parse_query(query)
        .map_err(|e| format!("could not parse query: {e}"))
}

/// `order_by_field` non-null/non-empty sorts hits by that fast field instead of
/// relevance (`order_ascending` non-zero -> ascending); such hits carry score 0.
#[no_mangle]
pub extern "C" fn tantivy_index_search(
    index: *mut CIndex,
    query: *const c_char,
    default_fields_csv: *const c_char,
    boosts_json: *const c_char,
    snippet_fields_csv: *const c_char,
    snippet_max_chars: usize,
    limit: usize,
    order_by_field: *const c_char,
    order_ascending: c_int,
    out_error: *mut *mut c_char,
) -> *mut c_char {
    guard(out_error, ptr::null_mut(), || {
        let idx = unsafe { index.as_ref() }.ok_or("index handle is null")?;
        let query = unsafe { opt_str(query) }.ok_or("query must be valid UTF-8")?;
        let parsed = parse_string_query(
            idx,
            query,
            unsafe { opt_str(default_fields_csv) },
            unsafe { opt_str(boosts_json) },
        )?;
        let snippet_fields = resolve_fields_csv(&idx.schema, unsafe { opt_str(snippet_fields_csv) })?;
        let order_by = unsafe { opt_str(order_by_field) }
            .filter(|s| !s.is_empty())
            .map(|f| (f, order_ascending != 0));
        execute_search(idx, &*parsed, limit, &snippet_fields, snippet_max_chars, order_by)
    })
}

/// Count documents matching a string query, without loading or transferring any
/// documents. Same `default_fields_csv` / `boosts_json` semantics as
/// `tantivy_index_search`. Returns the count, or -1 on error.
#[no_mangle]
pub extern "C" fn tantivy_index_count(
    index: *mut CIndex,
    query: *const c_char,
    default_fields_csv: *const c_char,
    boosts_json: *const c_char,
    out_error: *mut *mut c_char,
) -> i64 {
    guard(out_error, -1, || {
        let idx = unsafe { index.as_ref() }.ok_or("index handle is null")?;
        let query = unsafe { opt_str(query) }.ok_or("query must be valid UTF-8")?;
        let parsed = parse_string_query(
            idx,
            query,
            unsafe { opt_str(default_fields_csv) },
            unsafe { opt_str(boosts_json) },
        )?;
        let n = idx
            .reader
            .searcher()
            .search(&*parsed, &Count)
            .map_err(|e| format!("count failed: {e}"))?;
        Ok(n as i64)
    })
}

// ---------------------------------------------------------------------------
// Structured query API (mirrors tantivy's Query types)
// ---------------------------------------------------------------------------
//
// A query is a JSON tree, tagged by "type":
//   {"type":"all"}
//   {"type":"parsed","query":S,"fields":[F,...]?}   (tantivy query syntax)
//   {"type":"term","field":F,"value":V}
//   {"type":"fuzzy","field":F,"value":S,"distance":1,"transposition":true,"prefix":false}
//   {"type":"regex","field":F,"value":S}
//   {"type":"phrase","field":F,"terms":[S,...],"slop":0}
//   {"type":"phrase_prefix","field":F,"terms":[S,...],"max_expansions":N?}
//   {"type":"range","field":F,"lower":{"value":V,"included":true}|null,"upper":...}
//   {"type":"boost","query":NODE,"boost":2.0}
//   {"type":"boolean","clauses":[{"occur":"must|should|must_not","query":NODE}],
//                     "minimum_should_match":N?}

/// Resolve a comma-separated field-name list to `Field`s (empty/None -> []).
fn resolve_fields_csv(schema: &Schema, csv: Option<&str>) -> Result<Vec<Field>, String> {
    let mut v = Vec::new();
    if let Some(csv) = csv.map(str::trim).filter(|s| !s.is_empty()) {
        for name in csv.split(',').map(str::trim).filter(|s| !s.is_empty()) {
            let f = schema
                .get_field(name)
                .map_err(|_| format!("unknown field: '{name}'"))?;
            v.push(f);
        }
    }
    Ok(v)
}

/// Run `query` and serialize the top `limit` hits to the JSON envelope:
///
///   {"hits":[{"score":1.23,"doc":{...},"snippets":{"body":"…<b>x</b>…"}}, ...]}
///
/// When `snippet_fields` is non-empty, each hit gets a `snippets` map of
/// `{field: highlighted-HTML}` generated from that field's stored text.
///
/// `order_by` replaces relevance ordering with a fast-field sort: `(field,
/// ascending)`. Field-ordered hits carry a score of 0 (tantivy returns the
/// sort key instead of computing BM25).
fn execute_search(
    idx: &CIndex,
    query: &dyn Query,
    limit: usize,
    snippet_fields: &[Field],
    snippet_max_chars: usize,
    order_by: Option<(&str, bool)>,
) -> Result<*mut c_char, String> {
    let searcher = idx.reader.searcher();

    let mut generators: Vec<(String, SnippetGenerator)> = Vec::with_capacity(snippet_fields.len());
    for &f in snippet_fields {
        let mut g = SnippetGenerator::create(&searcher, query, f)
            .map_err(|e| format!("snippet generator failed: {e}"))?;
        if snippet_max_chars > 0 {
            g.set_max_num_chars(snippet_max_chars);
        }
        generators.push((idx.schema.get_field_name(f).to_string(), g));
    }

    // Cap at the corpus size so an absurd limit (e.g. usize::MAX from a caller
    // bug) cannot make TopDocs preallocate and panic; results are unaffected.
    let limit = if limit == 0 { 10 } else { limit };
    let limit = limit.min(searcher.num_docs().max(1) as usize);
    let top: Vec<(f32, tantivy::DocAddress)> = match order_by {
        None => searcher
            .search(query, &TopDocs::with_limit(limit).order_by_score())
            .map_err(|e| format!("search failed: {e}"))?,
        Some((name, ascending)) => {
            // The sort key type must match the fast column's type, so dispatch
            // on the schema. Each arm discards the key and keeps doc order.
            let field = idx
                .schema
                .get_field(name)
                .map_err(|_| format!("unknown order-by field: '{name}'"))?;
            let order = if ascending { Order::Asc } else { Order::Desc };
            let collect = |e: tantivy::TantivyError| format!("ordered search failed: {e}");
            match idx.schema.get_field_entry(field).field_type() {
                FieldType::U64(_) => searcher
                    .search(query, &TopDocs::with_limit(limit).order_by_fast_field::<u64>(name, order))
                    .map_err(collect)?
                    .into_iter()
                    .map(|(_, a)| (0.0, a))
                    .collect(),
                FieldType::I64(_) => searcher
                    .search(query, &TopDocs::with_limit(limit).order_by_fast_field::<i64>(name, order))
                    .map_err(collect)?
                    .into_iter()
                    .map(|(_, a)| (0.0, a))
                    .collect(),
                FieldType::F64(_) => searcher
                    .search(query, &TopDocs::with_limit(limit).order_by_fast_field::<f64>(name, order))
                    .map_err(collect)?
                    .into_iter()
                    .map(|(_, a)| (0.0, a))
                    .collect(),
                FieldType::Date(_) => searcher
                    .search(
                        query,
                        &TopDocs::with_limit(limit).order_by_fast_field::<DateTime>(name, order),
                    )
                    .map_err(collect)?
                    .into_iter()
                    .map(|(_, a)| (0.0, a))
                    .collect(),
                _ => {
                    return Err(format!(
                        "order-by requires a numeric or date fast field; '{name}' is not one"
                    ))
                }
            }
        }
    };

    let mut hits = Vec::with_capacity(top.len());
    for (score, addr) in top {
        let doc: TantivyDocument = searcher
            .doc(addr)
            .map_err(|e| format!("could not load doc: {e}"))?;
        let doc_val: serde_json::Value =
            serde_json::from_str(&doc.to_json(&idx.schema)).unwrap_or_else(|_| json!({}));
        let mut hit = json!({ "score": score, "doc": doc_val });
        if !generators.is_empty() {
            let mut snips = serde_json::Map::new();
            for (name, g) in &generators {
                snips.insert(name.clone(), json!(g.snippet_from_doc(&doc).to_html()));
            }
            if let Some(obj) = hit.as_object_mut() {
                obj.insert("snippets".to_string(), serde_json::Value::Object(snips));
            }
        }
        hits.push(hit);
    }
    let out = serde_json::to_string(&json!({ "hits": hits }))
        .map_err(|e| format!("could not serialize hits: {e}"))?;
    CString::new(out)
        .map(CString::into_raw)
        .map_err(|_| "result contained interior NUL".to_string())
}

/// Build a `Term` for `field` from a JSON scalar, per the field's type.
fn term_for(schema: &Schema, field: Field, v: &serde_json::Value) -> Result<Term, String> {
    let name = schema.get_field_name(field);
    match schema.get_field_entry(field).field_type() {
        FieldType::Str(_) => v
            .as_str()
            .map(|s| Term::from_field_text(field, s))
            .ok_or_else(|| format!("field '{name}' expects a string value")),
        FieldType::U64(_) => v
            .as_u64()
            .map(|n| Term::from_field_u64(field, n))
            .ok_or_else(|| format!("field '{name}' expects a u64 value")),
        FieldType::I64(_) => v
            .as_i64()
            .map(|n| Term::from_field_i64(field, n))
            .ok_or_else(|| format!("field '{name}' expects an i64 value")),
        FieldType::F64(_) => v
            .as_f64()
            .map(|n| Term::from_field_f64(field, n))
            .ok_or_else(|| format!("field '{name}' expects an f64 value")),
        FieldType::Bool(_) => v
            .as_bool()
            .map(|b| Term::from_field_bool(field, b))
            .ok_or_else(|| format!("field '{name}' expects a bool value")),
        FieldType::Date(_) => {
            let s = v
                .as_str()
                .ok_or_else(|| format!("field '{name}' expects an RFC3339 date string"))?;
            let odt = OffsetDateTime::parse(s, &Rfc3339)
                .map_err(|e| format!("invalid date for '{name}': {e}"))?;
            // Match the seconds-precision terms written to the index.
            Ok(Term::from_field_date_for_search(field, DateTime::from_utc(odt)))
        }
        _ => Err(format!("field '{name}' has an unsupported type for terms")),
    }
}

/// Resolve a node's `field` + `value` pair.
fn field_and_value<'a>(
    schema: &Schema,
    node: &'a serde_json::Value,
) -> Result<(Field, &'a serde_json::Value), String> {
    let name = node
        .get("field")
        .and_then(|x| x.as_str())
        .ok_or("query node missing 'field'")?;
    let field = schema
        .get_field(name)
        .map_err(|_| format!("unknown field '{name}'"))?;
    let value = node.get("value").ok_or("query node missing 'value'")?;
    Ok((field, value))
}

fn bound_for(
    schema: &Schema,
    field: Field,
    b: Option<&serde_json::Value>,
) -> Result<Bound<Term>, String> {
    match b {
        None | Some(serde_json::Value::Null) => Ok(Bound::Unbounded),
        Some(obj) => {
            let val = obj.get("value").ok_or("range bound requires 'value'")?;
            let term = term_for(schema, field, val)?;
            let included = obj.get("included").and_then(|x| x.as_bool()).unwrap_or(true);
            Ok(if included {
                Bound::Included(term)
            } else {
                Bound::Excluded(term)
            })
        }
    }
}

/// Recursively build a tantivy `Query` from the JSON tree. Takes the `Index`
/// (not just the schema) because the `parsed` node runs tantivy's
/// `QueryParser`, which needs the index's tokenizer manager.
fn build_query(
    index: &Index,
    schema: &Schema,
    node: &serde_json::Value,
) -> Result<Box<dyn Query>, String> {
    let ty = node
        .get("type")
        .and_then(|x| x.as_str())
        .ok_or("query node missing 'type'")?;
    match ty {
        "all" => Ok(Box::new(AllQuery)),
        "parsed" => {
            let q = node
                .get("query")
                .and_then(|x| x.as_str())
                .ok_or("parsed requires a string 'query'")?;
            let fields = match node.get("fields").and_then(|x| x.as_array()) {
                Some(arr) if !arr.is_empty() => {
                    let mut v = Vec::with_capacity(arr.len());
                    for f in arr {
                        let name = f.as_str().ok_or("parsed 'fields' must be strings")?;
                        v.push(
                            schema
                                .get_field(name)
                                .map_err(|_| format!("unknown field '{name}'"))?,
                        );
                    }
                    v
                }
                _ => default_text_fields(schema),
            };
            QueryParser::for_index(index, fields)
                .parse_query(q)
                .map_err(|e| format!("could not parse query: {e}"))
        }
        "term" => {
            let (field, value) = field_and_value(schema, node)?;
            Ok(Box::new(TermQuery::new(
                term_for(schema, field, value)?,
                IndexRecordOption::Basic,
            )))
        }
        "fuzzy" => {
            let (field, value) = field_and_value(schema, node)?;
            let s = value.as_str().ok_or("fuzzy 'value' must be a string")?;
            let distance = node.get("distance").and_then(|x| x.as_u64()).unwrap_or(1) as u8;
            let transposition = node
                .get("transposition")
                .and_then(|x| x.as_bool())
                .unwrap_or(true);
            let prefix = node.get("prefix").and_then(|x| x.as_bool()).unwrap_or(false);
            let term = Term::from_field_text(field, s);
            let q = if prefix {
                FuzzyTermQuery::new_prefix(term, distance, transposition)
            } else {
                FuzzyTermQuery::new(term, distance, transposition)
            };
            Ok(Box::new(q))
        }
        "regex" => {
            let (field, value) = field_and_value(schema, node)?;
            let pattern = value.as_str().ok_or("regex 'value' must be a string")?;
            let q = RegexQuery::from_pattern(pattern, field)
                .map_err(|e| format!("invalid regex pattern: {e}"))?;
            Ok(Box::new(q))
        }
        "phrase" => {
            let name = node
                .get("field")
                .and_then(|x| x.as_str())
                .ok_or("phrase missing 'field'")?;
            let field = schema
                .get_field(name)
                .map_err(|_| format!("unknown field '{name}'"))?;
            let terms_json = node
                .get("terms")
                .and_then(|x| x.as_array())
                .ok_or("phrase requires a 'terms' array")?;
            let terms: Vec<Term> = terms_json
                .iter()
                .map(|t| {
                    t.as_str()
                        .map(|s| Term::from_field_text(field, s))
                        .ok_or_else(|| "phrase terms must be strings".to_string())
                })
                .collect::<Result<_, _>>()?;
            match terms.len() {
                0 => Err("phrase requires at least one term".to_string()),
                1 => Ok(Box::new(TermQuery::new(
                    terms.into_iter().next().unwrap(),
                    IndexRecordOption::WithFreqsAndPositions,
                ))),
                _ => {
                    let slop = node.get("slop").and_then(|x| x.as_u64()).unwrap_or(0) as u32;
                    let mut pq = PhraseQuery::new(terms);
                    if slop > 0 {
                        pq.set_slop(slop);
                    }
                    Ok(Box::new(pq))
                }
            }
        }
        "phrase_prefix" => {
            let name = node
                .get("field")
                .and_then(|x| x.as_str())
                .ok_or("phrase_prefix missing 'field'")?;
            let field = schema
                .get_field(name)
                .map_err(|_| format!("unknown field '{name}'"))?;
            let terms_json = node
                .get("terms")
                .and_then(|x| x.as_array())
                .ok_or("phrase_prefix requires a 'terms' array")?;
            let terms: Vec<Term> = terms_json
                .iter()
                .map(|t| {
                    t.as_str()
                        .map(|s| Term::from_field_text(field, s))
                        .ok_or_else(|| "phrase_prefix terms must be strings".to_string())
                })
                .collect::<Result<_, _>>()?;
            if terms.is_empty() {
                return Err("phrase_prefix requires at least one term".to_string());
            }
            let mut q = PhrasePrefixQuery::new(terms);
            if let Some(n) = node.get("max_expansions").and_then(|x| x.as_u64()) {
                q.set_max_expansions(n as u32);
            }
            Ok(Box::new(q))
        }
        "range" => {
            let name = node
                .get("field")
                .and_then(|x| x.as_str())
                .ok_or("range missing 'field'")?;
            let field = schema
                .get_field(name)
                .map_err(|_| format!("unknown field '{name}'"))?;
            let lower = bound_for(schema, field, node.get("lower"))?;
            let upper = bound_for(schema, field, node.get("upper"))?;
            // tantivy's RangeQuery derives its field from a bound term, so a
            // fully unbounded range would panic inside the engine.
            if matches!(lower, Bound::Unbounded) && matches!(upper, Bound::Unbounded) {
                return Err(format!("range on '{name}' requires at least one bound"));
            }
            Ok(Box::new(RangeQuery::new(lower, upper)))
        }
        "boost" => {
            let child = node.get("query").ok_or("boost requires 'query'")?;
            let boost = node.get("boost").and_then(|x| x.as_f64()).unwrap_or(1.0) as f32;
            Ok(Box::new(BoostQuery::new(
                build_query(index, schema, child)?,
                boost,
            )))
        }
        "boolean" => {
            let clauses = node
                .get("clauses")
                .and_then(|x| x.as_array())
                .ok_or("boolean requires a 'clauses' array")?;
            let mut subs: Vec<(Occur, Box<dyn Query>)> = Vec::with_capacity(clauses.len());
            for c in clauses {
                let occur = match c.get("occur").and_then(|x| x.as_str()).unwrap_or("should") {
                    "must" => Occur::Must,
                    "must_not" => Occur::MustNot,
                    "should" => Occur::Should,
                    other => return Err(format!("unknown occur '{other}'")),
                };
                let cq =
                    build_query(index, schema, c.get("query").ok_or("clause requires 'query'")?)?;
                subs.push((occur, cq));
            }
            match node.get("minimum_should_match") {
                None | Some(serde_json::Value::Null) => Ok(Box::new(BooleanQuery::new(subs))),
                Some(v) => {
                    // Reject (rather than ignore) a negative or non-integer
                    // minimum — silently dropping it would widen the match set.
                    let min = v
                        .as_u64()
                        .ok_or("minimum_should_match must be a non-negative integer")?;
                    Ok(Box::new(BooleanQuery::with_minimum_required_clauses(
                        subs, min as usize,
                    )))
                }
            }
        }
        other => Err(format!("unknown query type '{other}'")),
    }
}

/// Run a structured query (see the JSON grammar above) and return the top
/// `limit` hits as the same JSON envelope as `tantivy_index_search`.
///
/// `order_by_field` non-null/non-empty sorts hits by that fast field instead of
/// relevance (`order_ascending` non-zero -> ascending); such hits carry score 0.
///
/// Returns a heap C string (free with `tantivy_string_free`), or null on error.
#[no_mangle]
pub extern "C" fn tantivy_index_search_query(
    index: *mut CIndex,
    query_json: *const c_char,
    snippet_fields_csv: *const c_char,
    snippet_max_chars: usize,
    limit: usize,
    order_by_field: *const c_char,
    order_ascending: c_int,
    out_error: *mut *mut c_char,
) -> *mut c_char {
    guard(out_error, ptr::null_mut(), || {
        let idx = unsafe { index.as_ref() }.ok_or("index handle is null")?;
        let qjson = unsafe { opt_str(query_json) }.ok_or("query_json must be valid UTF-8")?;
        let tree: serde_json::Value =
            serde_json::from_str(qjson).map_err(|e| format!("invalid query JSON: {e}"))?;
        let query = build_query(&idx.index, &idx.schema, &tree)?;

        let snippet_fields = resolve_fields_csv(&idx.schema, unsafe { opt_str(snippet_fields_csv) })?;
        let order_by = unsafe { opt_str(order_by_field) }
            .filter(|s| !s.is_empty())
            .map(|f| (f, order_ascending != 0));
        execute_search(idx, &*query, limit, &snippet_fields, snippet_max_chars, order_by)
    })
}

/// Count documents matching a structured query (same JSON grammar as
/// `tantivy_index_search_query`), without loading any documents. Returns the
/// count, or -1 on error.
#[no_mangle]
pub extern "C" fn tantivy_index_count_query(
    index: *mut CIndex,
    query_json: *const c_char,
    out_error: *mut *mut c_char,
) -> i64 {
    guard(out_error, -1, || {
        let idx = unsafe { index.as_ref() }.ok_or("index handle is null")?;
        let qjson = unsafe { opt_str(query_json) }.ok_or("query_json must be valid UTF-8")?;
        let tree: serde_json::Value =
            serde_json::from_str(qjson).map_err(|e| format!("invalid query JSON: {e}"))?;
        let query = build_query(&idx.index, &idx.schema, &tree)?;
        let n = idx
            .reader
            .searcher()
            .search(&*query, &Count)
            .map_err(|e| format!("count failed: {e}"))?;
        Ok(n as i64)
    })
}

/// Run a tantivy aggregation over the documents matching a structured query.
///
/// `query_json` is the structured query grammar above; `aggregations_json` is
/// tantivy's (Elasticsearch-compatible) aggregation request, e.g.:
///
///   {"tags":{"terms":{"field":"tag","size":10}}}
///
/// Aggregated fields must be `fast` in the schema. Returns the aggregation
/// result as JSON (free with `tantivy_string_free`), or null on error.
#[no_mangle]
pub extern "C" fn tantivy_index_aggregate(
    index: *mut CIndex,
    query_json: *const c_char,
    aggregations_json: *const c_char,
    out_error: *mut *mut c_char,
) -> *mut c_char {
    guard(out_error, ptr::null_mut(), || {
        let idx = unsafe { index.as_ref() }.ok_or("index handle is null")?;
        let qjson = unsafe { opt_str(query_json) }.ok_or("query_json must be valid UTF-8")?;
        let tree: serde_json::Value =
            serde_json::from_str(qjson).map_err(|e| format!("invalid query JSON: {e}"))?;
        let query = build_query(&idx.index, &idx.schema, &tree)?;

        let ajson = unsafe { opt_str(aggregations_json) }
            .ok_or("aggregations_json must be valid UTF-8")?;
        let aggs: Aggregations = serde_json::from_str(ajson)
            .map_err(|e| format!("invalid aggregations JSON: {e}"))?;
        let collector = AggregationCollector::from_aggs(aggs, Default::default());
        let res = idx
            .reader
            .searcher()
            .search(&*query, &collector)
            .map_err(|e| format!("aggregation failed: {e}"))?;
        let out = serde_json::to_string(&res)
            .map_err(|e| format!("could not serialize aggregation result: {e}"))?;
        CString::new(out)
            .map(CString::into_raw)
            .map_err(|_| "result contained interior NUL".to_string())
    })
}

/// Number of searchable documents (after the last reader reload).
/// Returns the count, or -1 on error.
#[no_mangle]
pub extern "C" fn tantivy_index_num_docs(index: *mut CIndex, out_error: *mut *mut c_char) -> i64 {
    guard(out_error, -1, || {
        let idx = unsafe { index.as_ref() }.ok_or("index handle is null")?;
        Ok(idx.reader.searcher().num_docs() as i64)
    })
}

// ---------------------------------------------------------------------------
// Memory management for returned strings
// ---------------------------------------------------------------------------

/// Free a C string returned by this library (search results, error messages).
#[no_mangle]
pub extern "C" fn tantivy_string_free(s: *mut c_char) {
    if !s.is_null() {
        unsafe { drop(CString::from_raw(s)) };
    }
}

/// Library version string (the tantivy release this wraps).
#[no_mangle]
pub extern "C" fn tantivy_version() -> *const c_char {
    // Static, NUL-terminated; never freed by the caller.
    concat!("tantivy 0.26.1 / tantivy_ffi ", env!("CARGO_PKG_VERSION"), "\0").as_ptr()
        as *const c_char
}
