// Loading the WebAssembly module, and one running instance of it.
//
// The module is the Rust library's C ABI compiled for `wasm32-wasip1` — the
// same functions the Swift package calls. Each `Index` gets an instance of its
// own: its own linear memory, so closing an index returns all of that memory
// (WebAssembly memory can grow but never shrink), and a crash in one index
// cannot corrupt another.

import { TantivyError } from "./errors.js";

/** What `init` accepts as the module: bytes, a URL or path, a fetch `Response`, or a compiled module. */
export type WasmSource =
  | WebAssembly.Module
  | BufferSource
  | Response
  | URL
  | string
  | PromiseLike<WebAssembly.Module | BufferSource | Response | URL | string>;

let compiled: WebAssembly.Module | undefined;

/**
 * Load and compile the engine. Call once, before creating an index.
 *
 * With no argument the module is read from `tantivy.wasm` next to this file —
 * from disk under Node, with `fetch` elsewhere (bundlers that understand
 * `new URL(..., import.meta.url)` copy it into the build). Pass `source` to
 * load it from somewhere else.
 */
export async function init(source?: WasmSource): Promise<void> {
  if (compiled && source === undefined) return;
  compiled = await compile(await (source ?? defaultSource()));
}

/**
 * Compile the engine synchronously from bytes or an already compiled module.
 * Browsers refuse to compile large modules synchronously on the main thread;
 * use `init` there, or call this from a worker.
 */
export function initSync(source: WebAssembly.Module | BufferSource): void {
  compiled = source instanceof WebAssembly.Module ? source : new WebAssembly.Module(source);
}

function defaultSource(): URL {
  return new URL("./tantivy.wasm", import.meta.url);
}

async function compile(
  source: WebAssembly.Module | BufferSource | Response | URL | string,
): Promise<WebAssembly.Module> {
  if (source instanceof WebAssembly.Module) return source;
  if (typeof Response !== "undefined" && source instanceof Response) {
    return WebAssembly.compile(await source.arrayBuffer());
  }
  if (typeof source === "string" || source instanceof URL) {
    const url = typeof source === "string" ? toURL(source) : source;
    if (url.protocol === "file:") {
      const { readFile } = await import(/* webpackIgnore: true */ "node:fs/promises" as string);
      return WebAssembly.compile(await readFile(url));
    }
    const response = await fetch(url);
    if (!response.ok) {
      throw TantivyError.ffi(`could not load ${url}: HTTP ${response.status}`);
    }
    return WebAssembly.compile(await response.arrayBuffer());
  }
  return WebAssembly.compile(source as BufferSource);
}

function toURL(source: string): URL {
  try {
    return new URL(source);
  } catch {
    // A bare path: relative to the page, or to the working directory under Node.
    const base =
      typeof location !== "undefined"
        ? location.href
        : `file://${(globalThis as { process?: { cwd(): string } }).process?.cwd() ?? ""}/`;
    return new URL(source, base);
  }
}

/** The C ABI, as the module exports it. `usize` and pointers are `number`s; `i64` is `bigint`. */
interface Exports {
  memory: WebAssembly.Memory;
  tantivy_alloc(len: number): number;
  tantivy_dealloc(ptr: number, len: number): void;
  tantivy_string_free(ptr: number): void;
  tantivy_version(): number;

  tantivy_result_bytes(result: number): number;
  tantivy_result_len(result: number): number;
  tantivy_result_free(result: number): void;

  tantivy_index_open_or_create(path: number, schema: number, reloadOnCommit: number, err: number): number;
  tantivy_index_free(index: number): void;
  tantivy_index_reload(index: number, err: number): number;
  tantivy_index_num_docs(index: number, err: number): bigint;
  tantivy_index_stats(index: number, err: number): number;
  tantivy_index_analyze(index: number, tokenizer: number, text: number, err: number): number;
  tantivy_index_search(
    index: number, query: number, fields: number, boosts: number, snippetFields: number,
    snippetMaxChars: number, limit: number, orderBy: number, ascending: number, err: number,
  ): number;
  tantivy_index_count(index: number, query: number, fields: number, boosts: number, err: number): bigint;
  tantivy_index_search_query(
    index: number, query: number, snippetFields: number, snippetMaxChars: number, limit: number,
    orderBy: number, ascending: number, err: number,
  ): number;
  tantivy_index_count_query(index: number, query: number, err: number): bigint;
  tantivy_index_aggregate(index: number, query: number, aggregations: number, err: number): number;

  tantivy_index_writer(index: number, heapSize: number, err: number): number;
  tantivy_writer_free(writer: number): void;
  tantivy_writer_add_json(writer: number, json: number, err: number): number;
  tantivy_writer_add_msgpack(writer: number, payload: number, len: number, err: number): number;
  tantivy_writer_commit(writer: number, err: number): bigint;
  tantivy_writer_rollback(writer: number, err: number): bigint;
  tantivy_writer_delete_all(writer: number, err: number): number;
  tantivy_writer_delete_term(writer: number, field: number, valueJSON: number, err: number): number;
  tantivy_writer_delete_term_bytes(writer: number, field: number, value: number, len: number, err: number): number;
  tantivy_writer_delete_query(writer: number, query: number, err: number): number;
  tantivy_writer_merge(writer: number, err: number): number;
  tantivy_writer_garbage_collect(writer: number, err: number): number;
}

const encoder = new TextEncoder();
const decoder = new TextDecoder();

/** Thrown by the `proc_exit` import; the engine only exits by aborting. */
class Exit extends Error {}

/** How much of the engine's stderr (a panic message) to keep for error reports. */
const STDERR_LIMIT = 4096;

/**
 * One instance of the engine. Every call into it goes through `call`, which
 * turns a trap — a Rust panic aborts, since WebAssembly cannot unwind — into a
 * `TantivyError` and retires the instance, whose memory may be inconsistent.
 */
export class Engine {
  readonly api: Exports;
  private crash: string | undefined;
  private stderr = "";
  /** Scratch slot for every `out_error` argument. */
  private readonly errorSlot: number;

  constructor() {
    if (!compiled) {
      throw TantivyError.ffi("the engine is not loaded; call and await init() first");
    }
    const instance = new WebAssembly.Instance(compiled, { wasi_snapshot_preview1: this.wasi(compiled) });
    this.api = instance.exports as unknown as Exports;
    this.errorSlot = this.api.tantivy_alloc(4);
  }

  private get bytes(): Uint8Array {
    // Re-read every time: growing the memory detaches the previous buffer.
    return new Uint8Array(this.api.memory.buffer);
  }

  private get view(): DataView {
    return new DataView(this.api.memory.buffer);
  }

  /** Run `body` against the instance, retiring it if it traps. */
  call<T>(body: () => T): T {
    if (this.crash !== undefined) {
      throw TantivyError.ffi(`the engine stopped after an earlier crash (${this.crash})`);
    }
    try {
      return body();
    } catch (error) {
      if (error instanceof WebAssembly.RuntimeError || error instanceof Exit) {
        const panic = this.stderr.trim().split("\n").find((line) => line.includes("panicked"));
        this.crash = panic ?? error.message;
        throw TantivyError.ffi(`internal panic: ${this.crash}`);
      }
      throw error;
    }
  }

  // -- Arguments ------------------------------------------------------------

  /**
   * Run `body` with each string written into the instance as a NUL-terminated
   * C string (`null` passes a null pointer), freeing them afterwards.
   */
  withStrings<T>(strings: readonly (string | null)[], body: (pointers: number[]) => T): T {
    const buffers: [number, number][] = [];
    try {
      const pointers = strings.map((s) => {
        if (s === null) return 0;
        const encoded = encoder.encode(s);
        const ptr = this.alloc(encoded.length + 1);
        buffers.push([ptr, encoded.length + 1]);
        const memory = this.bytes;
        memory.set(encoded, ptr);
        memory[ptr + encoded.length] = 0;
        return ptr;
      });
      return body(pointers);
    } finally {
      for (const [ptr, len] of buffers) this.api.tantivy_dealloc(ptr, len);
    }
  }

  /** Run `body` with `data` copied into the instance. */
  withBytes<T>(data: Uint8Array, body: (ptr: number, len: number) => T): T {
    const ptr = this.alloc(data.length);
    try {
      this.bytes.set(data, ptr);
      return body(ptr, data.length);
    } finally {
      this.api.tantivy_dealloc(ptr, data.length);
    }
  }

  private alloc(len: number): number {
    const ptr = this.api.tantivy_alloc(len);
    if (ptr === 0) throw TantivyError.ffi(`out of memory allocating ${len} bytes`);
    return ptr;
  }

  // -- Results --------------------------------------------------------------

  /** The `out_error` pointer, cleared for the next call. */
  get err(): number {
    this.view.setUint32(this.errorSlot, 0, true);
    return this.errorSlot;
  }

  /** The error the last call reported, as a `TantivyError` (freeing its string). */
  takeError(fallback: string): TantivyError {
    const ptr = this.view.getUint32(this.errorSlot, true);
    if (ptr === 0) return TantivyError.ffi(fallback);
    const message = this.readCString(ptr);
    this.api.tantivy_string_free(ptr);
    return TantivyError.ffi(message);
  }

  /** Read a C string the library returned and free it. */
  takeString(ptr: number): string {
    const s = this.readCString(ptr);
    this.api.tantivy_string_free(ptr);
    return s;
  }

  readCString(ptr: number): string {
    const memory = this.bytes;
    let end = ptr;
    while (memory[end] !== 0) end++;
    return decoder.decode(memory.subarray(ptr, end));
  }

  /** Copy a `CResult`'s payload out of the instance and free it. */
  takeResult(result: number): Uint8Array {
    try {
      const len = this.api.tantivy_result_len(result);
      const ptr = this.api.tantivy_result_bytes(result);
      if (len === 0 || ptr === 0) return new Uint8Array(0);
      return this.bytes.slice(ptr, ptr + len);
    } finally {
      this.api.tantivy_result_free(result);
    }
  }

  // -- WASI -----------------------------------------------------------------

  /**
   * The WASI imports Rust's standard library links against. There is no
   * filesystem and no environment: randomness (segment ids), clocks, stderr
   * (kept for panic messages) and the no-op sleep of a lock retry that a
   * single thread never reaches. Anything else the module imports reports
   * `ENOSYS`.
   */
  private wasi(module: WebAssembly.Module): Record<string, (...args: never[]) => unknown> {
    const SUCCESS = 0;
    const ENOSYS = 52;
    const view = () => this.view;
    const imports: Record<string, (...args: never[]) => unknown> = {
      random_get: (buf: number, len: number) => {
        // getRandomValues fills at most 64 KiB per call.
        for (let offset = 0; offset < len; offset += 65536) {
          const chunk = new Uint8Array(this.api.memory.buffer as ArrayBuffer, buf + offset, Math.min(65536, len - offset));
          globalThis.crypto.getRandomValues(chunk);
        }
        return SUCCESS;
      },
      environ_sizes_get: (count: number, size: number) => {
        view().setUint32(count, 0, true);
        view().setUint32(size, 0, true);
        return SUCCESS;
      },
      environ_get: () => SUCCESS,
      clock_time_get: (id: number, _precision: bigint, time: number) => {
        // 0 is the realtime clock; the others are monotonic.
        const ms = id === 0 ? Date.now() : performance.now();
        view().setBigUint64(time, BigInt(Math.round(ms * 1e6)), true);
        return SUCCESS;
      },
      fd_write: (fd: number, iovs: number, iovsLen: number, written: number) => {
        let total = 0;
        for (let i = 0; i < iovsLen; i++) {
          const ptr = view().getUint32(iovs + i * 8, true);
          const len = view().getUint32(iovs + i * 8 + 4, true);
          if (fd === 2) this.stderr += decoder.decode(this.bytes.subarray(ptr, ptr + len));
          total += len;
        }
        if (this.stderr.length > STDERR_LIMIT) this.stderr = this.stderr.slice(-STDERR_LIMIT);
        view().setUint32(written, total, true);
        return SUCCESS;
      },
      poll_oneoff: (subscriptions: number, events: number, count: number, eventCount: number) => {
        // Only reached by `thread::sleep`: report every clock as expired at once.
        for (let i = 0; i < count; i++) {
          const sub = subscriptions + i * 48;
          const event = events + i * 32;
          view().setBigUint64(event, view().getBigUint64(sub, true), true); // userdata
          view().setUint16(event + 8, 0, true); // errno
          view().setUint8(event + 10, view().getUint8(sub + 8)); // event type
        }
        view().setUint32(eventCount, count, true);
        return SUCCESS;
      },
      sched_yield: () => SUCCESS,
      proc_exit: (code: number) => {
        throw new Exit(`the engine exited with status ${code}`);
      },
    };
    for (const entry of WebAssembly.Module.imports(module)) {
      if (entry.module === "wasi_snapshot_preview1" && !(entry.name in imports)) {
        imports[entry.name] = () => ENOSYS;
      }
    }
    return imports;
  }
}

let cachedVersion: string | undefined;

/**
 * Version of the wrapped tantivy release and FFI shim, e.g.
 * `"tantivy 0.26.1 / tantivy_ffi 0.1.0"`. Mirrors Swift's `Tantivy.version`.
 */
export function version(): string {
  if (cachedVersion === undefined) {
    const engine = new Engine();
    cachedVersion = engine.call(() => engine.readCString(engine.api.tantivy_version()));
  }
  return cachedVersion;
}
