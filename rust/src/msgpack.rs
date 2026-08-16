//! A minimal MessagePack encoder, covering exactly the value grammar the hit
//! envelope uses: nil, bool, uint, int, float64, str, bin, array, map.
//!
//! Hand-rolled rather than pulled from a crate for two reasons: the grammar is
//! small enough that a dependency would be most of the cost of the feature, and
//! the Swift side has to be hand-rolled regardless (Foundation has no
//! MessagePack), so this keeps both ends symmetrical and dependency-free.
//!
//! Encoding is a tag byte, an optional big-endian length, and the payload —
//! there is no state and nothing to get slow, so a benchmark against this is
//! measuring the format rather than the implementation.

/// MessagePack tag bytes (see the spec's type-system table).
mod tag {
    pub const NIL: u8 = 0xc0;
    pub const FALSE: u8 = 0xc2;
    pub const TRUE: u8 = 0xc3;
    pub const BIN8: u8 = 0xc4;
    pub const BIN16: u8 = 0xc5;
    pub const BIN32: u8 = 0xc6;
    pub const FLOAT64: u8 = 0xcb;
    pub const UINT8: u8 = 0xcc;
    pub const UINT16: u8 = 0xcd;
    pub const UINT32: u8 = 0xce;
    pub const UINT64: u8 = 0xcf;
    pub const INT8: u8 = 0xd0;
    pub const INT16: u8 = 0xd1;
    pub const INT32: u8 = 0xd2;
    pub const INT64: u8 = 0xd3;
    pub const STR8: u8 = 0xd9;
    pub const STR16: u8 = 0xda;
    pub const STR32: u8 = 0xdb;
    pub const ARRAY16: u8 = 0xdc;
    pub const ARRAY32: u8 = 0xdd;
    pub const MAP16: u8 = 0xde;
    pub const MAP32: u8 = 0xdf;

    pub const FIXMAP: u8 = 0x80;
    pub const FIXARRAY: u8 = 0x90;
    pub const FIXSTR: u8 = 0xa0;
}

pub fn write_nil(out: &mut Vec<u8>) {
    out.push(tag::NIL);
}

pub fn write_bool(out: &mut Vec<u8>, value: bool) {
    out.push(if value { tag::TRUE } else { tag::FALSE });
}

pub fn write_u64(out: &mut Vec<u8>, value: u64) {
    match value {
        // positive fixint
        0..=0x7f => out.push(value as u8),
        v if v <= u8::MAX as u64 => {
            out.push(tag::UINT8);
            out.push(v as u8);
        }
        v if v <= u16::MAX as u64 => {
            out.push(tag::UINT16);
            out.extend_from_slice(&(v as u16).to_be_bytes());
        }
        v if v <= u32::MAX as u64 => {
            out.push(tag::UINT32);
            out.extend_from_slice(&(v as u32).to_be_bytes());
        }
        v => {
            out.push(tag::UINT64);
            out.extend_from_slice(&v.to_be_bytes());
        }
    }
}

pub fn write_i64(out: &mut Vec<u8>, value: i64) {
    if value >= 0 {
        return write_u64(out, value as u64);
    }
    match value {
        // negative fixint
        -32..=-1 => out.push(value as i8 as u8),
        v if v >= i8::MIN as i64 => {
            out.push(tag::INT8);
            out.push(v as i8 as u8);
        }
        v if v >= i16::MIN as i64 => {
            out.push(tag::INT16);
            out.extend_from_slice(&(v as i16).to_be_bytes());
        }
        v if v >= i32::MIN as i64 => {
            out.push(tag::INT32);
            out.extend_from_slice(&(v as i32).to_be_bytes());
        }
        v => {
            out.push(tag::INT64);
            out.extend_from_slice(&v.to_be_bytes());
        }
    }
}

pub fn write_f64(out: &mut Vec<u8>, value: f64) {
    out.push(tag::FLOAT64);
    out.extend_from_slice(&value.to_be_bytes());
}

pub fn write_str(out: &mut Vec<u8>, value: &str) {
    let bytes = value.as_bytes();
    match bytes.len() {
        n if n < 32 => out.push(tag::FIXSTR | n as u8),
        n if n <= u8::MAX as usize => {
            out.push(tag::STR8);
            out.push(n as u8);
        }
        n if n <= u16::MAX as usize => {
            out.push(tag::STR16);
            out.extend_from_slice(&(n as u16).to_be_bytes());
        }
        n => {
            out.push(tag::STR32);
            out.extend_from_slice(&(n as u32).to_be_bytes());
        }
    }
    out.extend_from_slice(bytes);
}

/// Write a byte string. This is the whole reason a binary envelope simplifies
/// things: bytes are a native type here, so they need no side blob and no
/// `{"$bytes": [...]}` indirection.
pub fn write_bin(out: &mut Vec<u8>, value: &[u8]) {
    match value.len() {
        n if n <= u8::MAX as usize => {
            out.push(tag::BIN8);
            out.push(n as u8);
        }
        n if n <= u16::MAX as usize => {
            out.push(tag::BIN16);
            out.extend_from_slice(&(n as u16).to_be_bytes());
        }
        n => {
            out.push(tag::BIN32);
            out.extend_from_slice(&(n as u32).to_be_bytes());
        }
    }
    out.extend_from_slice(value);
}

pub fn write_array_header(out: &mut Vec<u8>, len: usize) {
    match len {
        n if n < 16 => out.push(tag::FIXARRAY | n as u8),
        n if n <= u16::MAX as usize => {
            out.push(tag::ARRAY16);
            out.extend_from_slice(&(n as u16).to_be_bytes());
        }
        n => {
            out.push(tag::ARRAY32);
            out.extend_from_slice(&(n as u32).to_be_bytes());
        }
    }
}

pub fn write_map_header(out: &mut Vec<u8>, len: usize) {
    match len {
        n if n < 16 => out.push(tag::FIXMAP | n as u8),
        n if n <= u16::MAX as usize => {
            out.push(tag::MAP16);
            out.extend_from_slice(&(n as u16).to_be_bytes());
        }
        n => {
            out.push(tag::MAP32);
            out.extend_from_slice(&(n as u32).to_be_bytes());
        }
    }
}

// ---------------------------------------------------------------------------
// Reading
// ---------------------------------------------------------------------------

/// A cursor over a MessagePack buffer.
///
/// Every read bounds-checks, so a truncated or malformed payload produces an
/// error rather than reading past the end. Values are read *by expected type*
/// rather than discovered: the schema already says what each field holds, so
/// the reader is told what to expect and rejects anything else.
pub struct Reader<'a> {
    buffer: &'a [u8],
    index: usize,
}

impl<'a> Reader<'a> {
    pub fn new(buffer: &'a [u8]) -> Self {
        Reader { buffer, index: 0 }
    }

    fn byte(&mut self) -> Result<u8, String> {
        let b = *self
            .buffer
            .get(self.index)
            .ok_or("truncated MessagePack payload")?;
        self.index += 1;
        Ok(b)
    }

    fn peek(&self) -> Result<u8, String> {
        self.buffer
            .get(self.index)
            .copied()
            .ok_or_else(|| "truncated MessagePack payload".to_string())
    }

    fn be(&mut self, count: usize) -> Result<u64, String> {
        let end = self.index + count;
        let slice = self
            .buffer
            .get(self.index..end)
            .ok_or("truncated MessagePack payload")?;
        self.index = end;
        Ok(slice.iter().fold(0u64, |acc, b| (acc << 8) | *b as u64))
    }

    fn span(&mut self, count: usize) -> Result<&'a [u8], String> {
        let end = self.index + count;
        let slice = self
            .buffer
            .get(self.index..end)
            .ok_or("truncated MessagePack payload")?;
        self.index = end;
        Ok(slice)
    }

    pub fn read_map_header(&mut self) -> Result<usize, String> {
        match self.byte()? {
            t @ tag::FIXMAP..=0x8f => Ok((t & 0x0f) as usize),
            tag::MAP16 => Ok(self.be(2)? as usize),
            tag::MAP32 => Ok(self.be(4)? as usize),
            t => Err(format!("expected a map, found tag 0x{t:02x}")),
        }
    }

    pub fn read_array_header(&mut self) -> Result<usize, String> {
        match self.byte()? {
            t @ tag::FIXARRAY..=0x9f => Ok((t & 0x0f) as usize),
            tag::ARRAY16 => Ok(self.be(2)? as usize),
            tag::ARRAY32 => Ok(self.be(4)? as usize),
            t => Err(format!("expected an array, found tag 0x{t:02x}")),
        }
    }

    pub fn read_str(&mut self) -> Result<&'a str, String> {
        let count = match self.byte()? {
            t @ tag::FIXSTR..=0xbf => (t & 0x1f) as usize,
            tag::STR8 => self.be(1)? as usize,
            tag::STR16 => self.be(2)? as usize,
            tag::STR32 => self.be(4)? as usize,
            t => return Err(format!("expected a string, found tag 0x{t:02x}")),
        };
        std::str::from_utf8(self.span(count)?).map_err(|_| "invalid UTF-8 in string".to_string())
    }

    pub fn read_bin(&mut self) -> Result<&'a [u8], String> {
        let count = match self.byte()? {
            tag::BIN8 => self.be(1)? as usize,
            tag::BIN16 => self.be(2)? as usize,
            tag::BIN32 => self.be(4)? as usize,
            t => return Err(format!("expected a byte string, found tag 0x{t:02x}")),
        };
        self.span(count)
    }

    pub fn read_bool(&mut self) -> Result<bool, String> {
        match self.byte()? {
            tag::TRUE => Ok(true),
            tag::FALSE => Ok(false),
            t => Err(format!("expected a boolean, found tag 0x{t:02x}")),
        }
    }

    pub fn read_u64(&mut self) -> Result<u64, String> {
        match self.peek()? {
            0x00..=0x7f => Ok(self.byte()? as u64),
            t @ (tag::UINT8 | tag::UINT16 | tag::UINT32 | tag::UINT64) => {
                self.index += 1;
                self.be(1 << (t - tag::UINT8))
            }
            t => Err(format!("expected an unsigned integer, found tag 0x{t:02x}")),
        }
    }

    pub fn read_i64(&mut self) -> Result<i64, String> {
        match self.peek()? {
            0x00..=0x7f => Ok(self.byte()? as i64),
            0xe0..=0xff => Ok(self.byte()? as i8 as i64),
            t @ (tag::INT8 | tag::INT16 | tag::INT32 | tag::INT64) => {
                self.index += 1;
                let width = 1usize << (t - tag::INT8);
                let raw = self.be(width)?;
                // Sign-extend from the encoded width.
                let shift = 64 - width * 8;
                Ok(((raw << shift) as i64) >> shift)
            }
            t @ (tag::UINT8 | tag::UINT16 | tag::UINT32 | tag::UINT64) => {
                self.index += 1;
                let value = self.be(1 << (t - tag::UINT8))?;
                i64::try_from(value).map_err(|_| format!("{value} does not fit an i64"))
            }
            t => Err(format!("expected an integer, found tag 0x{t:02x}")),
        }
    }

    pub fn read_f64(&mut self) -> Result<f64, String> {
        match self.peek()? {
            tag::FLOAT64 => {
                self.index += 1;
                Ok(f64::from_bits(self.be(8)?))
            }
            0xca => {
                self.index += 1;
                Ok(f32::from_bits(self.be(4)? as u32) as f64)
            }
            // Accept integer forms so a whole-valued float need not be widened
            // by the encoder.
            _ => self.read_i64().map(|v| v as f64),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn integers_use_the_narrowest_form() {
        let mut out = Vec::new();
        write_u64(&mut out, 5);
        assert_eq!(out, vec![0x05]); // positive fixint

        out.clear();
        write_u64(&mut out, 1965);
        assert_eq!(out, vec![tag::UINT16, 0x07, 0xad]);

        out.clear();
        write_i64(&mut out, -1);
        assert_eq!(out, vec![0xff]); // negative fixint

        out.clear();
        write_i64(&mut out, i64::MIN);
        assert_eq!(out[0], tag::INT64);
        assert_eq!(out.len(), 9);
    }

    #[test]
    fn strings_and_bytes_carry_their_length() {
        let mut out = Vec::new();
        write_str(&mut out, "hi");
        assert_eq!(out, vec![tag::FIXSTR | 2, b'h', b'i']);

        out.clear();
        write_bin(&mut out, &[0x00, 0xff]);
        assert_eq!(out, vec![tag::BIN8, 2, 0x00, 0xff]);
    }

    /// Everything the writer emits, the reader must read back unchanged.
    #[test]
    fn values_round_trip_through_the_reader() {
        let mut out = Vec::new();
        write_map_header(&mut out, 2);
        write_str(&mut out, "key");
        write_array_header(&mut out, 1);
        write_bin(&mut out, &[0x00, 0xff, 0x80]);
        write_str(&mut out, "n");
        write_array_header(&mut out, 3);
        write_u64(&mut out, u64::MAX);
        write_i64(&mut out, i64::MIN);
        write_f64(&mut out, -2.25);

        let mut r = Reader::new(&out);
        assert_eq!(r.read_map_header().unwrap(), 2);
        assert_eq!(r.read_str().unwrap(), "key");
        assert_eq!(r.read_array_header().unwrap(), 1);
        assert_eq!(r.read_bin().unwrap(), &[0x00, 0xff, 0x80]);
        assert_eq!(r.read_str().unwrap(), "n");
        assert_eq!(r.read_array_header().unwrap(), 3);
        assert_eq!(r.read_u64().unwrap(), u64::MAX);
        assert_eq!(r.read_i64().unwrap(), i64::MIN);
        assert_eq!(r.read_f64().unwrap(), -2.25);
    }

    #[test]
    fn integer_edges_round_trip() {
        for value in [0i64, 1, -1, 127, -32, -33, 128, i64::MAX, i64::MIN, -128, -129] {
            let mut out = Vec::new();
            write_i64(&mut out, value);
            assert_eq!(Reader::new(&out).read_i64().unwrap(), value, "i64 {value}");
        }
        for value in [0u64, 127, 128, 255, 256, 65_535, 65_536, u64::MAX] {
            let mut out = Vec::new();
            write_u64(&mut out, value);
            assert_eq!(Reader::new(&out).read_u64().unwrap(), value, "u64 {value}");
        }
    }

    #[test]
    fn a_truncated_payload_errors_rather_than_reading_past_the_end() {
        let mut out = Vec::new();
        write_str(&mut out, "hello");
        out.truncate(3);
        assert!(Reader::new(&out).read_str().is_err());

        assert!(Reader::new(&[]).read_map_header().is_err());
    }

    #[test]
    fn a_wrong_type_errors() {
        let mut out = Vec::new();
        write_str(&mut out, "not a number");
        assert!(Reader::new(&out).read_u64().is_err());
        assert!(Reader::new(&out).read_bool().is_err());
        assert!(Reader::new(&out).read_bin().is_err());
    }

    /// MessagePack widens its length prefixes at 2^4, 2^5, 2^8 and 2^16. Real
    /// documents only ever hit the small forms, so without these the `str32`,
    /// `bin32`, `array32` and `map32` branches would never execute — and a
    /// mistake in one is silent corruption, not a crash.
    #[test]
    fn every_length_class_round_trips() {
        // (length, expected tag)
        for &(len, tag) in &[(0usize, tag::FIXSTR), (31, tag::FIXSTR | 31), (32, tag::STR8),
                             (255, tag::STR8), (256, tag::STR16), (65_535, tag::STR16),
                             (65_536, tag::STR32)] {
            let value = "a".repeat(len);
            let mut out = Vec::new();
            write_str(&mut out, &value);
            assert_eq!(out[0], tag, "str of {len} used tag {:#04x}", out[0]);
            assert_eq!(Reader::new(&out).read_str().unwrap(), value, "str of {len}");
        }

        for &(len, tag) in &[(0usize, tag::BIN8), (255, tag::BIN8), (256, tag::BIN16),
                             (65_535, tag::BIN16), (65_536, tag::BIN32)] {
            let value = vec![0xABu8; len];
            let mut out = Vec::new();
            write_bin(&mut out, &value);
            assert_eq!(out[0], tag, "bin of {len} used tag {:#04x}", out[0]);
            assert_eq!(Reader::new(&out).read_bin().unwrap(), &value[..], "bin of {len}");
        }

        for &(len, tag) in &[(0usize, tag::FIXARRAY), (15, tag::FIXARRAY | 15),
                             (16, tag::ARRAY16), (65_535, tag::ARRAY16),
                             (65_536, tag::ARRAY32)] {
            let mut out = Vec::new();
            write_array_header(&mut out, len);
            assert_eq!(out[0], tag, "array of {len} used tag {:#04x}", out[0]);
            assert_eq!(Reader::new(&out).read_array_header().unwrap(), len);
        }

        for &(len, tag) in &[(0usize, tag::FIXMAP), (15, tag::FIXMAP | 15),
                             (16, tag::MAP16), (65_535, tag::MAP16), (65_536, tag::MAP32)] {
            let mut out = Vec::new();
            write_map_header(&mut out, len);
            assert_eq!(out[0], tag, "map of {len} used tag {:#04x}", out[0]);
            assert_eq!(Reader::new(&out).read_map_header().unwrap(), len);
        }
    }

    /// A string's width follows its UTF-8 *byte* length, not its character
    /// count — 20,000 emoji is 80,000 bytes and needs str32.
    #[test]
    fn string_width_follows_utf8_length() {
        let value = "🙂".repeat(20_000);
        let mut out = Vec::new();
        write_str(&mut out, &value);
        assert_eq!(out[0], tag::STR32);
        assert_eq!(Reader::new(&out).read_str().unwrap(), value);
    }

    /// A document map and a value array past their 16-bit boundaries, written
    /// and read back the way `document_from_msgpack` walks them.
    #[test]
    fn wide_structures_round_trip() {
        let field_count = 65_536usize;
        let mut out = Vec::new();
        write_map_header(&mut out, field_count);
        for n in 0..field_count {
            write_str(&mut out, &format!("f{n}"));
            write_array_header(&mut out, 1);
            write_u64(&mut out, n as u64);
        }

        let mut r = Reader::new(&out);
        assert_eq!(r.read_map_header().unwrap(), field_count);
        for n in 0..field_count {
            assert_eq!(r.read_str().unwrap(), format!("f{n}"));
            assert_eq!(r.read_array_header().unwrap(), 1);
            assert_eq!(r.read_u64().unwrap(), n as u64);
        }

        // One field holding more values than array16 can express.
        let value_count = 65_536usize;
        let mut out = Vec::new();
        write_array_header(&mut out, value_count);
        for n in 0..value_count {
            write_i64(&mut out, -(n as i64));
        }
        let mut r = Reader::new(&out);
        assert_eq!(r.read_array_header().unwrap(), value_count);
        for n in 0..value_count {
            assert_eq!(r.read_i64().unwrap(), -(n as i64));
        }
    }

    /// Every integer encoding width, and the tag each value should pick.
    #[test]
    fn integers_pick_the_expected_tag() {
        let unsigned: &[(u64, Option<u8>)] = &[
            (0, None), (127, None),
            (128, Some(tag::UINT8)), (255, Some(tag::UINT8)),
            (256, Some(tag::UINT16)), (65_535, Some(tag::UINT16)),
            (65_536, Some(tag::UINT32)), (4_294_967_295, Some(tag::UINT32)),
            (4_294_967_296, Some(tag::UINT64)), (u64::MAX, Some(tag::UINT64)),
        ];
        for &(value, tag) in unsigned {
            let mut out = Vec::new();
            write_u64(&mut out, value);
            match tag {
                Some(t) => assert_eq!(out[0], t, "u64 {value}"),
                None => assert_eq!(out[0], value as u8, "u64 {value} should be a fixint"),
            }
            assert_eq!(Reader::new(&out).read_u64().unwrap(), value);
        }

        let signed: &[(i64, Option<u8>)] = &[
            (0, None), (127, None), (-1, None), (-32, None),
            (-33, Some(tag::INT8)), (-128, Some(tag::INT8)),
            (-129, Some(tag::INT16)), (i16::MIN as i64, Some(tag::INT16)),
            (i16::MIN as i64 - 1, Some(tag::INT32)), (i32::MIN as i64, Some(tag::INT32)),
            (i32::MIN as i64 - 1, Some(tag::INT64)), (i64::MIN, Some(tag::INT64)),
            (i64::MAX, Some(tag::UINT64)),
        ];
        for &(value, tag) in signed {
            let mut out = Vec::new();
            write_i64(&mut out, value);
            if let Some(t) = tag {
                assert_eq!(out[0], t, "i64 {value} used {:#04x}", out[0]);
            }
            assert_eq!(Reader::new(&out).read_i64().unwrap(), value);
        }
    }

    /// A u64 above `i64::MAX` cannot be read as an i64 — it must be reported
    /// rather than silently wrapping to a negative number.
    #[test]
    fn an_out_of_range_unsigned_value_is_rejected_as_signed() {
        let mut out = Vec::new();
        write_u64(&mut out, u64::MAX);
        assert!(Reader::new(&out).read_i64().is_err());
    }

    #[test]
    fn headers_widen_past_their_fixed_forms() {
        let mut out = Vec::new();
        write_array_header(&mut out, 3);
        assert_eq!(out, vec![tag::FIXARRAY | 3]);

        out.clear();
        write_array_header(&mut out, 1000);
        assert_eq!(out, vec![tag::ARRAY16, 0x03, 0xe8]);

        out.clear();
        write_map_header(&mut out, 2);
        assert_eq!(out, vec![tag::FIXMAP | 2]);
    }
}
