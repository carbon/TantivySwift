#ifndef CTANTIVY_H
#define CTANTIVY_H

/*
 * C ABI for tantivy 0.26.1 (see rust/src/lib.rs).
 *
 * Error convention: fallible calls take `char **out_error`. On failure they
 * return a sentinel (NULL / -1) and, when out_error is non-NULL, set *out_error
 * to a heap string you must release with tantivy_string_free().
 */

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct CIndex CIndex;
typedef struct CWriter CWriter;

/* ---- index lifecycle ---- */

/* Open or create an index. `path` NULL/empty -> in-RAM. `reload_on_commit`
 * non-zero -> the reader reloads itself shortly after each commit; zero ->
 * reload only via tantivy_index_reload(). Returns NULL on error. */
CIndex *tantivy_index_open_or_create(const char *path,
                                     const char *schema_json,
                                     int reload_on_commit,
                                     char **out_error);

void tantivy_index_free(CIndex *index);

/* Reload the reader so searches see the latest commit. 0 ok, -1 error. */
int tantivy_index_reload(CIndex *index, char **out_error);

/* Searchable document count (as of last reload). Count, or -1 on error. */
int64_t tantivy_index_num_docs(CIndex *index, char **out_error);

/* ---- writing ---- */

/* Create a writer. heap_size_bytes 0 -> 50MB default. NULL on error. */
CWriter *tantivy_index_writer(CIndex *index,
                              size_t heap_size_bytes,
                              char **out_error);

void tantivy_writer_free(CWriter *writer);

/* Add one JSON document (keys = field names). 0 ok, -1 error. */
int tantivy_writer_add_json(CWriter *writer,
                            const char *doc_json,
                            char **out_error);

/* Commit queued ops. Returns opstamp, or -1 on error. */
int64_t tantivy_writer_commit(CWriter *writer, char **out_error);

/* Discard all ops queued since the last commit. Returns the opstamp rolled back
 * to, or -1 on error. */
int64_t tantivy_writer_rollback(CWriter *writer, char **out_error);

/* Delete all documents (effective on next commit). 0 ok, -1 error. */
int tantivy_writer_delete_all(CWriter *writer, char **out_error);

/*
 * Delete all documents whose `field` contains the term parsed from `value_json`
 * (a JSON scalar). Intended for single-token fields (string/numeric/bool id) to
 * implement replace/upsert. Effective on next commit. 0 ok, -1 error.
 */
int tantivy_writer_delete_term(CWriter *writer,
                               const char *field,
                               const char *value_json,
                               char **out_error);

/*
 * Delete all documents matching a structured query (same JSON grammar as
 * tantivy_index_search_query). The query-based counterpart to
 * tantivy_writer_delete_term (delete by range, by several terms, etc.).
 * Effective on next commit. 0 ok, -1 error.
 */
int tantivy_writer_delete_query(CWriter *writer,
                                const char *query_json,
                                char **out_error);

/* ---- searching ---- */

/*
 * Run `query` and return up to `limit` hits as a JSON string:
 *   {"hits":[{"score":1.23,"doc":{"title":["..."],"id":[7]}}, ...]}
 * `default_fields_csv` NULL/empty -> all indexed text fields.
 * Returns a heap string (free with tantivy_string_free), or NULL on error.
 */
/* snippet_fields_csv: comma-separated stored text fields to highlight (NULL/empty
 * = none); snippet_max_chars: 0 = default. When set, each hit gains a "snippets"
 * map {field: highlighted-HTML}. */
char *tantivy_index_search(CIndex *index,
                           const char *query,
                           const char *default_fields_csv,
                           const char *boosts_json,
                           const char *snippet_fields_csv,
                           size_t snippet_max_chars,
                           size_t limit,
                           char **out_error);

/*
 * Run a structured query (a JSON query tree mirroring tantivy's Query types:
 * all / parsed / term / fuzzy / regex / phrase / phrase_prefix / range /
 * boost / boolean). Same hit envelope as tantivy_index_search. Returns a heap
 * string (free with tantivy_string_free), or NULL on error.
 */
char *tantivy_index_search_query(CIndex *index,
                                 const char *query_json,
                                 const char *snippet_fields_csv,
                                 size_t snippet_max_chars,
                                 size_t limit,
                                 char **out_error);

/*
 * Count matches without loading documents. tantivy_index_count takes a string
 * query (same default_fields_csv / boosts_json as tantivy_index_search);
 * tantivy_index_count_query takes a structured query tree. Each returns the
 * match count, or -1 on error.
 */
int64_t tantivy_index_count(CIndex *index,
                            const char *query,
                            const char *default_fields_csv,
                            const char *boosts_json,
                            char **out_error);

int64_t tantivy_index_count_query(CIndex *index,
                                  const char *query_json,
                                  char **out_error);

/*
 * Run a tantivy aggregation (Elasticsearch-compatible request JSON, e.g.
 * {"tags":{"terms":{"field":"tag","size":10}}}) over the documents matching a
 * structured query. Aggregated fields must be `fast` in the schema. Returns
 * the result JSON (free with tantivy_string_free), or NULL on error.
 */
char *tantivy_index_aggregate(CIndex *index,
                              const char *query_json,
                              const char *aggregations_json,
                              char **out_error);

/* ---- misc ---- */

/* Free a string returned by this library. */
void tantivy_string_free(char *s);

/* Static version string (do NOT free). */
const char *tantivy_version(void);

#ifdef __cplusplus
}
#endif

#endif /* CTANTIVY_H */
