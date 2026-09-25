// MessagePack, the wire format for documents (in) and hits (out) — the same
// payloads the Swift package exchanges with the engine. Only what those two
// need: the engine reads each document value by its field's declared type, so
// the writer just picks the natural encoding for each JavaScript value.

import { TantivyError } from "./errors.js";
import { rfc3339 } from "./values.js";

/** A value in a stored field of a search hit. */
export type FieldValue = string | number | bigint | boolean | Uint8Array;

/** A value to index. `Date` is sent as RFC3339, for a `date` field. */
export type DocumentValue = string | number | bigint | boolean | Date | Uint8Array | ArrayBuffer;

/** A document: field name → a value, or an array of values for a multi-valued field. */
export type DocumentFields = Record<string, DocumentValue | readonly DocumentValue[] | undefined>;

const encoder = new TextEncoder();
const decoder = new TextDecoder();

const U64_MAX = (1n << 64n) - 1n;
const I64_MIN = -(1n << 63n);

class Writer {
  private buffer = new Uint8Array(256);
  private view = new DataView(this.buffer.buffer);
  length = 0;

  private reserve(n: number): void {
    if (this.length + n <= this.buffer.length) return;
    let size = this.buffer.length * 2;
    while (size < this.length + n) size *= 2;
    const next = new Uint8Array(size);
    next.set(this.buffer.subarray(0, this.length));
    this.buffer = next;
    this.view = new DataView(next.buffer);
  }

  bytes(): Uint8Array {
    return this.buffer.subarray(0, this.length);
  }

  byte(b: number): void {
    this.reserve(1);
    this.buffer[this.length++] = b;
  }

  private tagged(tag: number, width: 1 | 2 | 4 | 8, value: number | bigint): void {
    this.reserve(1 + width);
    this.buffer[this.length++] = tag;
    const at = this.length;
    if (width === 1) this.view.setUint8(at, Number(value));
    else if (width === 2) this.view.setUint16(at, Number(value));
    else if (width === 4) this.view.setUint32(at, Number(value));
    else this.view.setBigUint64(at, BigInt.asUintN(64, BigInt(value)));
    this.length += width;
  }

  header(fix: number, fixMax: number, tag16: number, tag32: number, n: number): void {
    if (n <= fixMax) this.byte(fix | n);
    else if (n <= 0xffff) this.tagged(tag16, 2, n);
    else this.tagged(tag32, 4, n);
  }

  mapHeader(n: number): void {
    this.header(0x80, 15, 0xde, 0xdf, n);
  }

  arrayHeader(n: number): void {
    this.header(0x90, 15, 0xdc, 0xdd, n);
  }

  string(s: string): void {
    const encoded = encoder.encode(s);
    const n = encoded.length;
    if (n <= 31) this.byte(0xa0 | n);
    else if (n <= 0xff) this.tagged(0xd9, 1, n);
    else if (n <= 0xffff) this.tagged(0xda, 2, n);
    else this.tagged(0xdb, 4, n);
    this.raw(encoded);
  }

  binary(data: Uint8Array): void {
    const n = data.length;
    if (n <= 0xff) this.tagged(0xc4, 1, n);
    else if (n <= 0xffff) this.tagged(0xc5, 2, n);
    else this.tagged(0xc6, 4, n);
    this.raw(data);
  }

  private raw(data: Uint8Array): void {
    this.reserve(data.length);
    this.buffer.set(data, this.length);
    this.length += data.length;
  }

  integer(value: bigint): void {
    if (value >= 0n) {
      if (value <= 0x7fn) this.byte(Number(value));
      else if (value <= 0xffn) this.tagged(0xcc, 1, value);
      else if (value <= 0xffffn) this.tagged(0xcd, 2, value);
      else if (value <= 0xffffffffn) this.tagged(0xce, 4, value);
      else this.tagged(0xcf, 8, value);
    } else if (value >= -32n) {
      this.byte(Number(value) & 0xff);
    } else {
      // int64: the engine reads any signed width.
      this.tagged(0xd3, 8, value);
    }
  }

  float(value: number): void {
    this.reserve(9);
    this.buffer[this.length++] = 0xcb;
    this.view.setFloat64(this.length, value);
    this.length += 8;
  }

  bool(value: boolean): void {
    this.byte(value ? 0xc3 : 0xc2);
  }
}

/** Encode a document as the engine's `{field: [values]}` map. */
export function encodeDocument(fields: DocumentFields): Uint8Array {
  const entries = Object.entries(fields).filter(([, value]) => value !== undefined);
  const out = new Writer();
  out.mapHeader(entries.length);
  for (const [name, value] of entries) {
    out.string(name);
    if (Array.isArray(value)) {
      out.arrayHeader(value.length);
      for (const element of value) writeValue(out, element, name);
    } else {
      out.arrayHeader(1);
      writeValue(out, value, name);
    }
  }
  return out.bytes();
}

function writeValue(out: Writer, value: unknown, field: string): void {
  switch (typeof value) {
    case "string":
      out.string(value);
      return;
    case "boolean":
      out.bool(value);
      return;
    case "bigint":
      if (value < I64_MIN || value > U64_MAX) {
        throw TantivyError.encoding(`field '${field}' has an integer outside the Int64/UInt64 range`);
      }
      out.integer(value);
      return;
    case "number":
      if (!Number.isFinite(value)) {
        throw TantivyError.encoding(`field '${field}' has a non-finite number (NaN/±∞)`);
      }
      // Whole numbers go as integers, so they suit integer fields too; the
      // engine widens them for an `f64` field.
      if (Number.isSafeInteger(value)) out.integer(BigInt(value));
      else out.float(value);
      return;
  }
  if (value instanceof Date) {
    out.string(rfc3339(value, field));
  } else if (value instanceof Uint8Array) {
    out.binary(value);
  } else if (value instanceof ArrayBuffer) {
    out.binary(new Uint8Array(value));
  } else if (Array.isArray(value)) {
    throw TantivyError.encoding(`field '${field}' has a nested array value`);
  } else {
    const type = value === null ? "null" : typeof value === "object" ? value.constructor?.name ?? "object" : typeof value;
    throw TantivyError.encoding(`field '${field}' has a value of unsupported type ${type}`);
  }
}

/** One decoded hit: the engine's `{score, doc, snippets?}`. */
export interface RawHit {
  score: number;
  fields: Record<string, FieldValue[]>;
  snippets: Record<string, string>;
}

/**
 * A cursor over a MessagePack buffer. Every read bounds-checks, so a
 * truncated or corrupt payload throws rather than reading past the end.
 */
class Reader {
  private index = 0;
  private readonly view: DataView;

  constructor(private readonly buffer: Uint8Array) {
    this.view = new DataView(buffer.buffer, buffer.byteOffset, buffer.byteLength);
  }

  private need(n: number): number {
    if (this.index + n > this.buffer.length) {
      throw new Error(`truncated payload: needed ${n} bytes, ${this.buffer.length - this.index} available`);
    }
    const at = this.index;
    this.index += n;
    return at;
  }

  private u8(): number {
    return this.view.getUint8(this.need(1));
  }

  private u16(): number {
    return this.view.getUint16(this.need(2));
  }

  private u32(): number {
    return this.view.getUint32(this.need(4));
  }

  private span(n: number): Uint8Array {
    const at = this.need(n);
    return this.buffer.subarray(at, at + n);
  }

  private header(fix: number, fixMask: number, tag16: number, tag32: number, what: string): number {
    const tag = this.u8();
    if ((tag & ~fixMask) === fix) return tag & fixMask;
    if (tag === tag16) return this.u16();
    if (tag === tag32) return this.u32();
    throw new Error(`unexpected tag 0x${tag.toString(16)}, expected ${what}`);
  }

  mapHeader(): number {
    return this.header(0x80, 0x0f, 0xde, 0xdf, "a map header");
  }

  arrayHeader(): number {
    return this.header(0x90, 0x0f, 0xdc, 0xdd, "an array header");
  }

  string(): string {
    const value = this.value();
    if (typeof value !== "string") throw new Error("expected a string");
    return value;
  }

  number(): number {
    const value = this.value();
    if (typeof value === "number") return value;
    if (typeof value === "bigint") return Number(value);
    throw new Error("expected a number");
  }

  /** Any scalar. Integers outside the safe range come back as `bigint`. */
  value(): FieldValue | null {
    const tag = this.u8();
    if (tag <= 0x7f) return tag;
    if (tag >= 0xe0) return tag - 0x100;
    if ((tag & 0xe0) === 0xa0) return decoder.decode(this.span(tag & 0x1f));
    switch (tag) {
      case 0xc0: return null;
      case 0xc2: return false;
      case 0xc3: return true;
      case 0xc4: return this.span(this.u8()).slice();
      case 0xc5: return this.span(this.u16()).slice();
      case 0xc6: return this.span(this.u32()).slice();
      case 0xca: return this.view.getFloat32(this.need(4));
      case 0xcb: return this.view.getFloat64(this.need(8));
      case 0xcc: return this.u8();
      case 0xcd: return this.u16();
      case 0xce: return this.u32();
      case 0xcf: return safe(this.view.getBigUint64(this.need(8)));
      case 0xd0: return this.view.getInt8(this.need(1));
      case 0xd1: return this.view.getInt16(this.need(2));
      case 0xd2: return this.view.getInt32(this.need(4));
      case 0xd3: return safe(this.view.getBigInt64(this.need(8)));
      case 0xd9: return decoder.decode(this.span(this.u8()));
      case 0xda: return decoder.decode(this.span(this.u16()));
      case 0xdb: return decoder.decode(this.span(this.u32()));
    }
    throw new Error(`unexpected tag 0x${tag.toString(16)}`);
  }
}

/** A `bigint` as a `number` when that is exact. */
function safe(value: bigint): number | bigint {
  return value >= BigInt(Number.MIN_SAFE_INTEGER) && value <= BigInt(Number.MAX_SAFE_INTEGER)
    ? Number(value)
    : value;
}

/** Decode the engine's hit envelope, `{"hits": [{score, doc, snippets?}]}`. */
export function decodeHits(payload: Uint8Array): RawHit[] {
  if (payload.length === 0) return [];
  try {
    const r = new Reader(payload);
    const hits: RawHit[] = [];
    for (let i = r.mapHeader(); i > 0; i--) {
      if (r.string() !== "hits") throw new Error("expected 'hits'");
      for (let n = r.arrayHeader(); n > 0; n--) {
        const hit: RawHit = { score: 0, fields: {}, snippets: {} };
        for (let k = r.mapHeader(); k > 0; k--) {
          const key = r.string();
          if (key === "score") {
            hit.score = r.number();
          } else if (key === "doc") {
            for (let f = r.mapHeader(); f > 0; f--) {
              const name = r.string();
              const values: FieldValue[] = [];
              for (let v = r.arrayHeader(); v > 0; v--) {
                const value = r.value();
                if (value !== null) values.push(value);
              }
              hit.fields[name] = values;
            }
          } else if (key === "snippets") {
            for (let s = r.mapHeader(); s > 0; s--) {
              const name = r.string();
              hit.snippets[name] = r.string();
            }
          } else {
            r.value();
          }
        }
        hits.push(hit);
      }
    }
    return hits;
  } catch (error) {
    throw TantivyError.encoding(`could not decode search response: ${(error as Error).message}`);
  }
}
