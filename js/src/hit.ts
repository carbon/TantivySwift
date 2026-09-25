import type { FieldValue, RawHit } from "./msgpack.js";

/**
 * One search result: its relevance score and the stored fields of the matched
 * document. tantivy stores every field as a list of values.
 *
 * Integers come back as `number` when exact and `bigint` beyond 2^53.
 */
export class SearchHit {
  /** BM25 relevance score (higher is better); 0 for field-ordered hits. */
  readonly score: number;
  /** Stored fields, keyed by name; each an array of values. */
  readonly fields: Readonly<Record<string, FieldValue[]>>;
  /** Highlighted HTML per field passed to `highlight` (matches in `<b>…</b>`). */
  readonly snippets: Readonly<Record<string, string>>;

  constructor(hit: RawHit) {
    this.score = hit.score;
    this.fields = hit.fields;
    this.snippets = hit.snippets;
  }

  /** The highlighted snippet for `name`, if one was generated. */
  snippet(name: string): string | undefined {
    return this.snippets[name];
  }

  /** All values of `name` (empty if absent or not stored). Swift's subscript. */
  values(name: string): FieldValue[] {
    return this.fields[name] ?? [];
  }

  /** First string value of `name`. */
  string(name: string): string | undefined {
    return this.values(name).find((v): v is string => typeof v === "string");
  }

  /** First value of `name` as an integer that fits a `number` exactly (fractions truncate). */
  int(name: string): number | undefined {
    for (const v of this.values(name)) {
      if (typeof v === "number") return Math.trunc(v);
      if (typeof v === "bigint" && isSafe(v)) return Number(v);
    }
    return undefined;
  }

  /** `int`, for non-negative values only. */
  uint(name: string): number | undefined {
    for (const v of this.values(name)) {
      if (typeof v === "number" && v >= 0) return Math.trunc(v);
      if (typeof v === "bigint" && v >= 0n && isSafe(v)) return Number(v);
    }
    return undefined;
  }

  /** First integer of `name` as a `bigint` — exact across the full 64-bit range. */
  bigint(name: string): bigint | undefined {
    for (const v of this.values(name)) {
      if (typeof v === "bigint") return v;
      if (typeof v === "number" && Number.isInteger(v)) return BigInt(v);
    }
    return undefined;
  }

  /** First numeric value of `name` as a `number` (64-bit integers widened, maybe inexactly). */
  double(name: string): number | undefined {
    for (const v of this.values(name)) {
      if (typeof v === "number") return v;
      if (typeof v === "bigint") return Number(v);
    }
    return undefined;
  }

  /** First boolean value of `name`. */
  bool(name: string): boolean | undefined {
    return this.values(name).find((v): v is boolean => typeof v === "boolean");
  }

  /** First `bytes` value of `name`. */
  data(name: string): Uint8Array | undefined {
    return this.values(name).find((v): v is Uint8Array => v instanceof Uint8Array);
  }

  /** First value of a `date` field as a `Date`. */
  date(name: string): Date | undefined {
    const s = this.string(name);
    if (s === undefined) return undefined;
    const d = new Date(s);
    return Number.isNaN(d.getTime()) ? undefined : d;
  }

  /**
   * The stored fields as a plain object: a field with one value becomes that
   * value, one with several an array. Name fields in `arrays` to always get an
   * array — a multi-valued field holding a single value otherwise reads as a
   * scalar. The JavaScript counterpart of Swift's `decode(_:)`.
   */
  toObject<T = Record<string, unknown>>(arrays: readonly string[] = []): T {
    const out: Record<string, unknown> = {};
    for (const [name, values] of Object.entries(this.fields)) {
      out[name] = arrays.includes(name) || values.length !== 1 ? values : values[0];
    }
    return out as T;
  }
}

function isSafe(v: bigint): boolean {
  return v >= BigInt(Number.MIN_SAFE_INTEGER) && v <= BigInt(Number.MAX_SAFE_INTEGER);
}
