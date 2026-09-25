/** Errors surfaced by the library. Mirrors Swift's `TantivyError`. */
export class TantivyError extends Error {
  /**
   * `ffi`: reported by the tantivy engine. `encoding`: a value could not be
   * encoded for, or decoded from, the engine — raised on the JavaScript side.
   */
  readonly kind: "ffi" | "encoding";

  private constructor(kind: "ffi" | "encoding", message: string) {
    super(message);
    this.name = "TantivyError";
    this.kind = kind;
  }

  static ffi(message: string): TantivyError {
    return new TantivyError("ffi", message);
  }

  static encoding(message: string): TantivyError {
    return new TantivyError("encoding", message);
  }

  /** True for a JavaScript-side encode/decode failure rather than an engine error. */
  get isEncoding(): boolean {
    return this.kind === "encoding";
  }

  override toString(): string {
    return this.kind === "ffi" ? `tantivy: ${this.message}` : `tantivy encoding: ${this.message}`;
  }
}
