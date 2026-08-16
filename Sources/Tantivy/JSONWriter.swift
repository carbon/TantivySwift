import Foundation

/// A minimal JSON text writer.
///
/// Query trees, the schema spec, and boosts are the parts of the FFI still
/// carried as JSON — they are small, sent once per call, and (for query trees)
/// map naturally onto `serde_json::Value`'s random access on the Rust side.
///
/// This exists so those payloads can be written straight from their typed Swift
/// representations, without an intermediate `[String: Any]` for
/// `JSONSerialization` to walk. That removes the last untyped boxing from the
/// query path, and with it any value type that could silently fail to
/// serialize. It also makes the output deterministic — `JSONSerialization`
/// emits dictionary keys in hash order, which made payloads awkward to compare
/// and to read in a debugger.
struct JSONWriter {
    private(set) var text: String = ""

    init(reservingCapacity capacity: Int = 256) {
        text.reserveCapacity(capacity)
    }

    /// Append an already-formed fragment (`{`, `,`, a literal key, …).
    mutating func raw(_ fragment: String) { text += fragment }

    /// Write a JSON string literal, escaped.
    ///
    /// Control characters must be escaped as `\uXXXX`; a raw one is invalid
    /// JSON and `serde_json` rejects the whole payload. `/` needs no escaping,
    /// and non-ASCII passes through as UTF-8.
    mutating func write(_ value: String) {
        text += "\""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"": text += "\\\""
            case "\\": text += "\\\\"
            case "\n": text += "\\n"
            case "\r": text += "\\r"
            case "\t": text += "\\t"
            default:
                if scalar.value < 0x20 {
                    text += String(format: "\\u%04x", scalar.value)
                } else {
                    text.unicodeScalars.append(scalar)
                }
            }
        }
        text += "\""
    }

    /// Write raw bytes as `{"$bytes": "<base64>"}`.
    ///
    /// JSON has no byte type, and byte strings are not valid UTF-8 in general.
    /// Documents and hits sidestep this by being MessagePack; a query carries at
    /// most a handful of keys, so the ~100 ns to encode one is not worth a
    /// side-channel of raw pointers to avoid.
    ///
    /// Wrapped rather than written as a bare string so the value stays *typed*
    /// on the wire. A bare base64 string is indistinguishable from a text term,
    /// so aiming a `Data` at a `string` field would quietly search for the
    /// base64 text instead of reporting the mismatch.
    mutating func write(_ value: Data) {
        text += #"{"$bytes":"#
        write(value.base64EncodedString())
        text += "}"
    }

    mutating func write(_ value: Bool) { text += value ? "true" : "false" }
    mutating func write(_ value: Int) { text += String(value) }
    mutating func write(_ value: Int64) { text += String(value) }
    mutating func write(_ value: UInt64) { text += String(value) }

    /// Write a number. Callers must reject non-finite values first: JSON cannot
    /// represent NaN or ±∞, and `String(Double.nan)` emits a bare `nan` that the
    /// engine rejects with an opaque parse error.
    mutating func write(_ value: Double) {
        text += String(value)
    }

    /// Write an array of strings.
    mutating func write(_ values: [String]) {
        text += "["
        for (index, value) in values.enumerated() {
            if index > 0 { text += "," }
            write(value)
        }
        text += "]"
    }
}
