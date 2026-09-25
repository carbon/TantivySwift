// Small shared conversions and argument checks, each matching the Swift
// package's so both reject the same inputs with the same messages.

import { TantivyError } from "./errors.js";

/** A date as RFC3339 at second precision, as the Swift package sends it. */
export function rfc3339(date: Date, what: string): string {
  if (Number.isNaN(date.getTime())) {
    throw TantivyError.encoding(`${what} has an invalid Date`);
  }
  return date.toISOString().replace(/\.\d{3}Z$/, "Z");
}

export function base64(data: Uint8Array): string {
  let binary = "";
  for (let i = 0; i < data.length; i += 0x8000) {
    binary += String.fromCharCode(...data.subarray(i, i + 0x8000));
  }
  return btoa(binary);
}

/**
 * Strings reach the engine as C strings, so an interior NUL would silently
 * truncate one there — searching, sorting or deleting on a different field
 * than asked whenever the truncated prefix is itself a field name.
 */
export function checkNoNUL(s: string, what: string): void {
  if (s.includes("\0")) throw TantivyError.encoding(`${what} contains an interior NUL character`);
}

/** Field names travel comma-separated, so a comma would split one in two. */
export function checkFieldName(name: string, what: string): void {
  checkNoNUL(name, `${what} field name '${name}'`);
  if (name.includes(",")) throw TantivyError.encoding(`${what} field name '${name}' contains a comma`);
}

export function checkFieldNames(names: readonly string[], what: string): void {
  for (const name of names) checkFieldName(name, what);
}

/**
 * A count crossing as a 32-bit `usize`. Negative or fractional values are
 * rejected, as Swift rejects negative ones; anything past the 32-bit range is
 * capped, which the engine caps further (a limit at the corpus size).
 */
export function usize(value: number, name: string): number {
  if (!Number.isInteger(value) || value < 0) {
    throw TantivyError.encoding(`${name} must be a non-negative integer (got ${value})`);
  }
  return Math.min(value, 0xffffffff);
}

/** An integer option that Swift types as `UInt8` / `UInt32`. */
export function checkUInt(value: number, max: number, name: string): number {
  if (!Number.isInteger(value) || value < 0 || value > max) {
    throw TantivyError.encoding(`${name} must be an integer from 0 to ${max} (got ${value})`);
  }
  return value;
}

/** `{"field": boost}`, keys sorted so identical requests serialize identically. */
export function boostsJSON(boosts: Record<string, number>): string | null {
  const fields = Object.keys(boosts).sort();
  if (fields.length === 0) return null;
  const sorted: Record<string, number> = {};
  for (const field of fields) {
    const value = boosts[field]!;
    if (!Number.isFinite(value)) {
      throw TantivyError.encoding(`non-finite boost for field '${field}' (NaN/±∞)`);
    }
    checkNoNUL(field, `boost field name '${field}'`);
    sorted[field] = value;
  }
  return JSON.stringify(sorted);
}
