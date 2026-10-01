//! Standard-alphabet base64 (RFC 4648, with padding) — the relay's Go `[]byte`
//! JSON encoding. Hand-rolled so the bot keeps a minimal dependency graph; the
//! round-trip is pinned by RFC test vectors below.

pub fn encode(input: &[u8]) -> String {
    const TABLE: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let mut out = String::with_capacity(input.len().div_ceil(3) * 4);
    for chunk in input.chunks(3) {
        let b = [chunk[0], *chunk.get(1).unwrap_or(&0), *chunk.get(2).unwrap_or(&0)];
        let n = (u32::from(b[0]) << 16) | (u32::from(b[1]) << 8) | u32::from(b[2]);
        out.push(TABLE[(n >> 18) as usize & 63] as char);
        out.push(TABLE[(n >> 12) as usize & 63] as char);
        out.push(if chunk.len() > 1 { TABLE[(n >> 6) as usize & 63] as char } else { '=' });
        out.push(if chunk.len() > 2 { TABLE[n as usize & 63] as char } else { '=' });
    }
    out
}

pub fn decode(input: &str) -> Result<Vec<u8>, &'static str> {
    fn value(c: u8) -> Result<u32, &'static str> {
        match c {
            b'A'..=b'Z' => Ok(u32::from(c - b'A')),
            b'a'..=b'z' => Ok(u32::from(c - b'a') + 26),
            b'0'..=b'9' => Ok(u32::from(c - b'0') + 52),
            b'+' => Ok(62),
            b'/' => Ok(63),
            _ => Err("invalid base64 character"),
        }
    }
    let bytes = input.as_bytes();
    if bytes.len() % 4 != 0 { return Err("base64 length must be a multiple of 4"); }
    let pad = bytes.iter().rev().take_while(|&&c| c == b'=').count();
    if pad > 2 { return Err("bad base64 padding"); }
    let full_groups = (bytes.len() - pad) / 4;
    let mut out = Vec::with_capacity((bytes.len() - pad) * 3 / 4);
    for (group, chunk) in bytes.chunks(4).enumerate() {
        if group < full_groups {
            let n = value(chunk[0])? << 18 | value(chunk[1])? << 12
                | value(chunk[2])? << 6 | value(chunk[3])?;
            out.extend_from_slice(&[(n >> 16) as u8, (n >> 8) as u8, n as u8]);
        } else {
            // Final, padded group: like Go's StdEncoding, trailing bits that
            // would encode a phantom byte are rejected (non-canonical).
            match bytes.len() - pad - full_groups * 4 {
                2 => {
                    let n = value(chunk[0])? << 18 | value(chunk[1])? << 12;
                    if (n >> 12) & 0x0F != 0 { return Err("non-canonical base64 trailing bits"); }
                    out.push((n >> 16) as u8);
                }
                3 => {
                    let n = value(chunk[0])? << 18 | value(chunk[1])? << 12 | value(chunk[2])? << 6;
                    if (n >> 6) & 0x03 != 0 { return Err("non-canonical base64 trailing bits"); }
                    out.extend_from_slice(&[(n >> 16) as u8, (n >> 8) as u8]);
                }
                _ => return Err("invalid base64 group length"),
            }
        }
    }
    Ok(out)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn rfc4648_vectors() {
        assert_eq!(encode(b""), "");
        assert_eq!(encode(b"f"), "Zg==");
        assert_eq!(encode(b"fo"), "Zm8=");
        assert_eq!(encode(b"foo"), "Zm9v");
        assert_eq!(encode(b"foob"), "Zm9vYg==");
        assert_eq!(encode(b"fooba"), "Zm9vYmE=");
        assert_eq!(encode(b"foobar"), "Zm9vYmFy");
        for (raw, encoded) in [
            (&b""[..], ""), (&b"f"[..], "Zg=="), (&b"fo"[..], "Zm8="),
            (&b"foo"[..], "Zm9v"), (&b"foob"[..], "Zm9vYg=="),
            (&b"fooba"[..], "Zm9vYmE="), (&b"foobar"[..], "Zm9vYmFy"),
        ] {
            assert_eq!(decode(encoded).unwrap(), raw);
        }
    }

    #[test]
    fn binary_roundtrip_and_rejections() {
        let raw: Vec<u8> = (0..=255u8).cycle().take(10_000).collect();
        assert_eq!(decode(&encode(&raw)).unwrap(), raw);
        assert!(decode("A").is_err()); // length not multiple of 4
        assert!(decode("AAAA=").is_err()); // padding > 2
        assert!(decode("A*==").is_err()); // invalid character
        assert!(decode("Zh==").is_err()); // trailing bits would encode a phantom byte
        assert_eq!(decode("ZA==").unwrap(), b"d"); // trailing bits zero → canonical
    }
}
