// The structured query API: a query *tree* that maps onto tantivy's own query
// types, serialized to the JSON grammar the engine reads (see rust/src/lib.rs).
// Mirrors Swift's `Query`.

import { TantivyError } from "./errors.js";
import { base64, rfc3339 } from "./values.js";

/**
 * A value in a `term` or `range` clause, interpreted by the field's type:
 * numbers for numeric fields (`bigint` for 64-bit values beyond 2^53), `Date`
 * for dates, `Uint8Array` for bytes.
 */
export type TermValue = string | number | bigint | boolean | Date | Uint8Array;

/** One end of a range, inclusive or exclusive. */
export interface RangeBound {
  readonly value: TermValue;
  readonly included: boolean;
}
export const RangeBound = {
  included: (value: TermValue): RangeBound => ({ value, included: true }),
  excluded: (value: TermValue): RangeBound => ({ value, included: false }),
};

/** One position of a multi-phrase: any one of `terms` at `offset` satisfies it. */
export interface PhrasePosition {
  offset: number;
  terms: string[];
}

/** A token from `Index.analyze`. Tokens sharing a `position` are alternatives in `multiPhrase`. */
export interface Token {
  text: string;
  position: number;
  /** UTF-8 byte offset of the token's first byte in the analyzed text. */
  offsetFrom: number;
  /** UTF-8 byte offset one past the token's last byte. */
  offsetTo: number;
}

/**
 * Tuning for `Query.moreLikeThis`; every value optional, tantivy's default
 * otherwise. On a small corpus lower `minDocFrequency` (default 5) and
 * `minTermFrequency` (default 2) to 1, or nothing may match.
 */
export interface MoreLikeThisOptions {
  minDocFrequency?: number;
  maxDocFrequency?: number;
  minTermFrequency?: number;
  maxQueryTerms?: number;
  minWordLength?: number;
  maxWordLength?: number;
  boostFactor?: number;
  stopWords?: string[];
}

export type QueryNode =
  | { type: "all" }
  | { type: "parsed"; query: string; fields: string[] }
  | { type: "term"; field: string; value: TermValue }
  | { type: "fuzzy"; field: string; value: string; distance: number; transposition: boolean; prefix: boolean }
  | { type: "regex"; field: string; pattern: string }
  | { type: "wildcard"; field: string; pattern: string }
  | { type: "exists"; field: string }
  | { type: "moreLikeThis"; fields: Record<string, string[]>; options: MoreLikeThisOptions }
  | { type: "phrase"; field: string; terms: string[]; slop: number }
  | { type: "phrasePrefix"; field: string; terms: string[]; maxExpansions: number }
  | { type: "multiPhrase"; field: string; positions: PhrasePosition[]; slop: number }
  | { type: "range"; field: string; lower?: RangeBound; upper?: RangeBound }
  | { type: "boost"; query: Query; boost: number }
  | { type: "boolean"; must: Query[]; should: Query[]; mustNot: Query[]; minimumShouldMatch?: number };

/**
 * A structured query. Build with the static constructors and combine with
 * `and` / `or` (Swift's `&&` / `||`), `excluding` and `boosted`:
 *
 * ```ts
 * const q = Query.term("title", "dune").and(Query.closedRange("year", 1900, 2000));
 * const hits = index.search(q);
 * ```
 *
 * `term` and `phrase` match *indexed tokens* exactly, so on a tokenized field
 * pass analyzed tokens (lowercase for the default analyzer). For raw user
 * input use `Query.parsed` or a query string.
 */
export class Query {
  /** The query tree, for inspection. */
  readonly node: QueryNode;

  private constructor(node: QueryNode) {
    this.node = node;
  }

  static readonly matchAll: Query = new Query({ type: "all" });

  /**
   * A query *string* in tantivy syntax, analyzed and parsed by the engine, as
   * a node of a structured query. `fields` are searched when the string names
   * none (empty: every indexed text field).
   */
  static parsed(query: string, fields: string[] = []): Query {
    return new Query({ type: "parsed", query, fields });
  }

  /** Exact match of one indexed term. */
  static term(field: string, value: TermValue): Query {
    return new Query({ type: "term", field, value });
  }

  static phrase(field: string, terms: string[], slop = 0): Query {
    return new Query({ type: "phrase", field, terms, slop });
  }

  /** A phrase whose last term is a prefix — multi-word typeahead. */
  static phrasePrefix(field: string, terms: string[], maxExpansions = 50): Query {
    return new Query({ type: "phrasePrefix", field, terms, maxExpansions });
  }

  /**
   * A phrase with alternatives at each position. Pass one array of terms per
   * position (`[["graphic"], ["designers", "design"]]`), or the tokens from
   * `Index.analyze`, where tokens sharing a position become alternatives.
   */
  static multiPhrase(field: string, positions: string[][] | Token[], slop = 0): Query {
    let resolved: PhrasePosition[];
    if (positions.every((p): p is string[] => Array.isArray(p))) {
      resolved = positions.map((terms, offset) => ({ offset, terms }));
    } else {
      const byPosition = new Map<number, string[]>();
      for (const token of positions as Token[]) {
        const terms = byPosition.get(token.position) ?? [];
        terms.push(token.text);
        byPosition.set(token.position, terms);
      }
      resolved = [...byPosition.entries()]
        .sort(([a], [b]) => a - b)
        .map(([offset, terms]) => ({ offset, terms }));
    }
    return new Query({ type: "multiPhrase", field, positions: resolved, slop });
  }

  static fuzzy(
    field: string,
    value: string,
    options: { distance?: number; transposition?: boolean; prefix?: boolean } = {},
  ): Query {
    return new Query({
      type: "fuzzy",
      field,
      value,
      distance: options.distance ?? 1,
      transposition: options.transposition ?? true,
      prefix: options.prefix ?? false,
    });
  }

  /** Exact prefix match on an indexed token — the typeahead primitive. */
  static prefix(field: string, value: string): Query {
    return Query.fuzzy(field, value, { distance: 0, transposition: false, prefix: true });
  }

  /** Typo-tolerant typeahead: a prefix match allowing `typoTolerance` edits. */
  static autocomplete(field: string, value: string, typoTolerance = 1): Query {
    return Query.fuzzy(field, value, { distance: typoTolerance, transposition: true, prefix: true });
  }

  /** Indexed tokens matching a regular expression (anchored to the whole token). */
  static regex(field: string, pattern: string): Query {
    return new Query({ type: "regex", field, pattern });
  }

  /** Indexed tokens matching a wildcard pattern, where `*` is any run of characters. */
  static wildcard(field: string, pattern: string): Query {
    return new Query({ type: "wildcard", field, pattern });
  }

  /** Documents with any value in `field`, which must be `fast`. */
  static exists(field: string): Query {
    return new Query({ type: "exists", field });
  }

  /**
   * Documents similar to the given text: `{field: [texts]}`, or one field and
   * one text. Scored, so it works with `search` only.
   */
  static moreLikeThis(fields: Record<string, string[]>, options?: MoreLikeThisOptions): Query;
  static moreLikeThis(field: string, text: string, options?: MoreLikeThisOptions): Query;
  static moreLikeThis(
    fieldsOrField: Record<string, string[]> | string,
    textOrOptions?: string | MoreLikeThisOptions,
    options: MoreLikeThisOptions = {},
  ): Query {
    if (typeof fieldsOrField === "string") {
      return new Query({
        type: "moreLikeThis",
        fields: { [fieldsOrField]: [textOrOptions as string] },
        options,
      });
    }
    return new Query({
      type: "moreLikeThis",
      fields: fieldsOrField,
      options: (textOrOptions as MoreLikeThisOptions | undefined) ?? {},
    });
  }

  /** A range from explicit bounds; omit a side for unbounded (but not both). */
  static range(field: string, bounds: { from?: RangeBound; to?: RangeBound }): Query {
    return new Query({ type: "range", field, lower: bounds.from, upper: bounds.to });
  }

  /** `lower...upper` — both ends included. */
  static closedRange(field: string, lower: TermValue, upper: TermValue): Query {
    return Query.range(field, { from: RangeBound.included(lower), to: RangeBound.included(upper) });
  }

  /** `lower..<upper` — the upper end excluded. */
  static halfOpenRange(field: string, lower: TermValue, upper: TermValue): Query {
    return Query.range(field, { from: RangeBound.included(lower), to: RangeBound.excluded(upper) });
  }

  /** Dates from `from` to `to`, both included; omit one for unbounded. */
  static dateRange(field: string, bounds: { from?: Date; to?: Date }): Query {
    return Query.range(field, {
      from: bounds.from && RangeBound.included(bounds.from),
      to: bounds.to && RangeBound.included(bounds.to),
    });
  }

  static boolean(clauses: {
    must?: Query[];
    should?: Query[];
    mustNot?: Query[];
    minimumShouldMatch?: number;
  }): Query {
    return new Query({
      type: "boolean",
      must: clauses.must ?? [],
      should: clauses.should ?? [],
      mustNot: clauses.mustNot ?? [],
      minimumShouldMatch: clauses.minimumShouldMatch,
    });
  }

  /** Every sub-query must match. */
  static allOf(queries: Query[]): Query {
    return Query.boolean({ must: queries });
  }

  /** Any sub-query may match. */
  static anyOf(queries: Query[], minimumShouldMatch?: number): Query {
    return Query.boolean({ should: queries, minimumShouldMatch });
  }

  /** Weight this query by `factor`. */
  boosted(factor: number): Query {
    return new Query({ type: "boost", query: this, boost: factor });
  }

  /** This query, excluding documents that match `other`. */
  excluding(other: Query): Query {
    return Query.boolean({ must: [this], mustNot: [other] });
  }

  /**
   * Both must match — Swift's `&&`. Chains flatten: `a.and(b).and(c)` is one
   * `must` list of three, which scores the same and keeps the tree shallow.
   */
  and(other: Query): Query {
    return Query.allOf([...this.mustClauses(), ...other.mustClauses()]);
  }

  /** Either may match — Swift's `||`. Chains flatten like `and`. */
  or(other: Query): Query {
    return Query.anyOf([...this.shouldClauses(), ...other.shouldClauses()]);
  }

  private mustClauses(): Query[] {
    const n = this.node;
    if (n.type === "boolean" && !n.should.length && !n.mustNot.length && n.minimumShouldMatch === undefined) {
      return n.must;
    }
    return [this];
  }

  private shouldClauses(): Query[] {
    const n = this.node;
    if (n.type === "boolean" && !n.must.length && !n.mustNot.length && n.minimumShouldMatch === undefined) {
      return n.should;
    }
    return [this];
  }

  // -- Serialization --------------------------------------------------------

  /**
   * Deepest `boost`/`boolean` nesting a query may have. The engine's JSON
   * parser stops at 128 levels and a boolean clause costs three of them.
   */
  static readonly maxNesting = 40;

  /**
   * The JSON tree handed to the engine, as text. Validates first, throwing an
   * encoding error rather than sending a malformed query.
   */
  jsonString(): string {
    return json(this.wire(0));
  }

  private wire(depth: number): unknown {
    if (depth > Query.maxNesting) {
      throw TantivyError.encoding(`query nests more than ${Query.maxNesting} levels deep`);
    }
    const n = this.node;
    switch (n.type) {
      case "all":
        return { type: "all" };
      case "parsed":
        return { type: "parsed", query: n.query, fields: n.fields };
      case "term":
        return { type: "term", field: n.field, value: termValue(n.value, "term query") };
      case "fuzzy":
        return {
          type: "fuzzy",
          field: n.field,
          value: n.value,
          distance: uint(n.distance, 0xff, "fuzzy distance"),
          transposition: n.transposition,
          prefix: n.prefix,
        };
      case "regex":
        return { type: "regex", field: n.field, value: n.pattern };
      case "wildcard":
        return { type: "wildcard", field: n.field, value: n.pattern };
      case "exists":
        return { type: "exists", field: n.field };
      case "moreLikeThis": {
        const o = n.options;
        if (o.boostFactor !== undefined && !Number.isFinite(o.boostFactor)) {
          throw TantivyError.encoding("non-finite more_like_this boost factor");
        }
        const fields: Record<string, string[]> = {};
        for (const name of Object.keys(n.fields).sort()) fields[name] = n.fields[name]!;
        return {
          type: "more_like_this",
          fields,
          min_doc_frequency: o.minDocFrequency,
          max_doc_frequency: o.maxDocFrequency,
          min_term_frequency: o.minTermFrequency,
          max_query_terms: o.maxQueryTerms,
          min_word_length: o.minWordLength,
          max_word_length: o.maxWordLength,
          boost_factor: o.boostFactor,
          stop_words: o.stopWords?.length ? o.stopWords : undefined,
        };
      }
      case "phrase":
        return { type: "phrase", field: n.field, terms: n.terms, slop: uint(n.slop, 0xffffffff, "slop") };
      case "phrasePrefix":
        return {
          type: "phrase_prefix",
          field: n.field,
          terms: n.terms,
          max_expansions: uint(n.maxExpansions, 0xffffffff, "maxExpansions"),
        };
      case "multiPhrase": {
        const bad = n.positions.find((p) => !Number.isInteger(p.offset) || p.offset < 0);
        if (bad) {
          throw TantivyError.encoding(`multi-phrase on '${n.field}' has a negative offset (${bad.offset})`);
        }
        return {
          type: "multi_phrase",
          field: n.field,
          positions: n.positions.map((p) => ({ offset: p.offset, terms: p.terms })),
          slop: uint(n.slop, 0xffffffff, "slop"),
        };
      }
      case "range": {
        if (!n.lower && !n.upper) {
          throw TantivyError.encoding(`range on '${n.field}' requires at least one bound`);
        }
        const bound = (b: RangeBound | undefined) =>
          b && { value: termValue(b.value, "range bound"), included: b.included };
        return { type: "range", field: n.field, lower: bound(n.lower), upper: bound(n.upper) };
      }
      case "boost":
        if (!Number.isFinite(n.boost)) throw TantivyError.encoding("non-finite boost factor");
        return { type: "boost", query: n.query.wire(depth + 1), boost: n.boost };
      case "boolean": {
        const min = n.minimumShouldMatch;
        if (min !== undefined && (!Number.isInteger(min) || min < 0)) {
          throw TantivyError.encoding(`minimumShouldMatch must be a non-negative integer (got ${min})`);
        }
        const clauses = [
          ...n.must.map((q) => ({ occur: "must", query: q.wire(depth + 1) })),
          ...n.should.map((q) => ({ occur: "should", query: q.wire(depth + 1) })),
          ...n.mustNot.map((q) => ({ occur: "must_not", query: q.wire(depth + 1) })),
        ];
        return { type: "boolean", clauses, minimum_should_match: min };
      }
    }
  }
}

/** A term value on the wire. */
function termValue(value: TermValue, what: string): unknown {
  if (typeof value === "number" && !Number.isFinite(value)) {
    throw TantivyError.encoding(`non-finite number in ${what}`);
  }
  if (value instanceof Date) return rfc3339(value, what);
  if (value instanceof Uint8Array) return { $bytes: base64(value) };
  return value;
}

function uint(value: number, max: number, name: string): number {
  if (!Number.isInteger(value) || value < 0 || value > max) {
    throw TantivyError.encoding(`${name} must be an integer from 0 to ${max} (got ${value})`);
  }
  return value;
}

/**
 * JSON text for a wire tree. `JSON.stringify` cannot write a `bigint`, which a
 * 64-bit term needs as a bare integer, so this writes the few shapes the tree
 * holds itself. `undefined` members are omitted, as optional keys.
 */
function json(value: unknown): string {
  switch (typeof value) {
    case "bigint":
      return value.toString();
    case "string":
    case "number":
    case "boolean":
      return JSON.stringify(value);
  }
  if (Array.isArray(value)) return `[${value.map(json).join(",")}]`;
  const members = Object.entries(value as Record<string, unknown>)
    .filter(([, v]) => v !== undefined)
    .map(([k, v]) => `${JSON.stringify(k)}:${json(v)}`);
  return `{${members.join(",")}}`;
}
