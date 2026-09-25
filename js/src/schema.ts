/** An immutable index schema, produced by `SchemaBuilder`. */
export class Schema {
  /** The JSON specification handed to the engine. */
  readonly json: string;

  constructor(json: string) {
    this.json = json;
  }
}

/** How an indexed text field records postings. Mirrors tantivy's `IndexRecordOption`. */
export type TextIndexing = "basic" | "freq" | "position";

/**
 * The analyzers the engine registers. Values are the on-the-wire names; the
 * keys match the Swift `Analyzer` cases.
 */
export const Analyzer = {
  /** Lowercased, split on non-alphanumeric, unstemmed (tantivy `default`). */
  default: "default",
  /** The whole value as one token, case-sensitive (tantivy `raw`). */
  raw: "raw",
  /** Split on whitespace only (tantivy `whitespace`). */
  whitespace: "whitespace",
  /** Lowercased + English stemming (tantivy `en_stem`). */
  english: "en_stem",
  /** The whole value as one lowercased token — case-insensitive exact match. */
  lowercase: "lowercase",
  /**
   * `english`, keeping each word's surface form alongside its stem at the same
   * position. Query it with typed queries built from `Index.analyze`, never a
   * query string. See the Swift `Analyzer.englishKeepingSurface` notes.
   */
  englishKeepingSurface: "en_stem_keep",
} as const;
export type Analyzer = (typeof Analyzer)[keyof typeof Analyzer];

export interface FieldOptions {
  /** Keep the original value so it can be returned in search hits. */
  stored?: boolean;
  /** Make the field searchable (default true). */
  indexed?: boolean;
  /** Also store as a columnar fast field (sorting, aggregations, `exists`). */
  fast?: boolean;
}

export interface TextFieldOptions extends FieldOptions {
  /** The analyzer to apply (default `Analyzer.default`). */
  tokenizer?: Analyzer;
  /** What to record in the postings (default `"position"`, which phrase queries need). */
  indexing?: TextIndexing;
}

interface FieldSpec {
  name: string;
  type: string;
  stored: boolean;
  indexed: boolean;
  fast: boolean;
  tokenizer?: string;
  record?: string;
}

/**
 * Fluent builder for an index `Schema`.
 *
 * ```ts
 * const schema = new SchemaBuilder()
 *   .addTextField("title", { stored: true })
 *   .addTextField("body")
 *   .addU64Field("id", { stored: true, fast: true })
 *   .build();
 * ```
 */
export class SchemaBuilder {
  private readonly fields: FieldSpec[] = [];

  /** A tokenized, full-text field. */
  addTextField(name: string, options: TextFieldOptions = {}): this {
    return this.add(name, "text", options, {
      tokenizer: options.tokenizer ?? Analyzer.default,
      record: options.indexing ?? "position",
    });
  }

  /** A non-tokenized string field (one raw token) for exact matching: ids, tags, enums. */
  addStringField(name: string, options: FieldOptions = {}): this {
    return this.add(name, "string", options);
  }

  addU64Field(name: string, options: FieldOptions = {}): this {
    return this.add(name, "u64", options);
  }

  addI64Field(name: string, options: FieldOptions = {}): this {
    return this.add(name, "i64", options);
  }

  addF64Field(name: string, options: FieldOptions = {}): this {
    return this.add(name, "f64", options);
  }

  addBoolField(name: string, options: FieldOptions = {}): this {
    return this.add(name, "bool", options);
  }

  /** A date/time field. Values are `Date`s (or RFC3339 strings), stored at second precision. */
  addDateField(name: string, options: FieldOptions = {}): this {
    return this.add(name, "date", options);
  }

  /**
   * An opaque byte-string field — the type for a binary id or key. Indexed, the
   * whole value is one term matched byte for byte. Values are `Uint8Array`s.
   */
  addBytesField(name: string, options: FieldOptions = {}): this {
    return this.add(name, "bytes", options);
  }

  private add(
    name: string,
    type: string,
    options: FieldOptions,
    text?: { tokenizer: string; record: string },
  ): this {
    this.fields.push({
      name,
      type,
      stored: options.stored ?? false,
      indexed: options.indexed ?? true,
      fast: options.fast ?? false,
      ...text,
    });
    return this;
  }

  build(): Schema {
    return new Schema(JSON.stringify({ fields: this.fields }));
  }
}
