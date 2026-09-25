//! Record authentication for persisted state (#177 §3.5, B7): HMAC-SHA256 under a
//! 32-byte record key held by the caller, replacing the plain SHA-256
//! `staged_checksum` a same-origin attacker could simply recompute.
//!
//! Construction, so other code (and tests with WebCrypto) can reproduce it:
//! `HMAC-SHA256(key, domain ‖ for each part: u32 LE length ‖ part)` with
//! `domain = "family-mls-v2/entry\0"` over `(room, entry key, entry value)` and
//! `domain = "family-mls-v2/meta\0"` over `(meta bytes)`. Length prefixes make the
//! part boundaries unambiguous; the domains keep an entry tag from ever verifying
//! as a meta tag.
//!
//! Rollback (restoring an older, validly tagged database) is **not** detectable
//! without an external witness; this is integrity against modification only.
//! The record key comes from the caller today; the custody unlock derives it (M2b-3).
use super::*;
use hmac::{Hmac, Mac};
use sha2::Sha256;

const ENTRY: &[u8] = b"family-mls-v2/entry\0";
const META: &[u8] = b"family-mls-v2/meta\0";
pub(crate) const TAG_LEN: usize = 32;

fn keyed(key: &[u8], domain: &[u8], parts: &[&[u8]]) -> Result<Hmac<Sha256>, Rejected> {
    if key.len() != 32 { return Err(Rejected("record key rejected")); }
    let mut mac = <Hmac<Sha256> as Mac>::new_from_slice(key).map_err(rejected)?;
    mac.update(domain);
    for part in parts {
        let len = u32::try_from(part.len()).map_err(rejected)?;
        mac.update(&len.to_le_bytes());
        mac.update(part);
    }
    Ok(mac)
}

fn entry_mac(key: &[u8], room: &str, entry_key: &[u8], value: &[u8]) -> Result<Hmac<Sha256>, Rejected> {
    if room.is_empty() || room.len() > 128 || entry_key.is_empty() { return Err(rejected(())); }
    keyed(key, ENTRY, &[room.as_bytes(), entry_key, value])
}

#[wasm_bindgen]
pub fn entry_tag(key: &[u8], room: &str, entry_key: &[u8], value: &[u8]) -> Result<Vec<u8>, Rejected> {
    Ok(entry_mac(key, room, entry_key, value)?.finalize().into_bytes().to_vec())
}

/// Constant-time check of an entry tag.
#[wasm_bindgen]
pub fn entry_verify(key: &[u8], room: &str, entry_key: &[u8], value: &[u8], tag: &[u8]) -> Result<bool, Rejected> {
    Ok(tag.len() == TAG_LEN && entry_mac(key, room, entry_key, value)?.verify_slice(tag).is_ok())
}

#[wasm_bindgen]
pub fn meta_tag(key: &[u8], meta: &[u8]) -> Result<Vec<u8>, Rejected> {
    Ok(keyed(key, META, &[meta])?.finalize().into_bytes().to_vec())
}

/// Constant-time check of a meta tag.
#[wasm_bindgen]
pub fn meta_verify(key: &[u8], meta: &[u8], tag: &[u8]) -> Result<bool, Rejected> {
    Ok(tag.len() == TAG_LEN && keyed(key, META, &[meta])?.verify_slice(tag).is_ok())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn tags_bind_key_domain_and_every_part() {
        let key = [7u8; 32];
        let tag = entry_tag(&key, "room", b"k", b"v").unwrap();
        assert!(entry_verify(&key, "room", b"k", b"v", &tag).unwrap());
        assert!(!entry_verify(&[8u8; 32], "room", b"k", b"v", &tag).unwrap(), "other key");
        assert!(!entry_verify(&key, "room2", b"k", b"v", &tag).unwrap(), "other room");
        assert!(!entry_verify(&key, "room", b"k", b"w", &tag).unwrap(), "other value");
        // Length prefixes: moving a byte across the key/value boundary changes the tag.
        assert_ne!(entry_tag(&key, "room", b"kv", b"").unwrap(), entry_tag(&key, "room", b"k", b"v").unwrap());
        // Domain separation: the same bytes never verify across entry/meta.
        let meta = meta_tag(&key, b"x").unwrap();
        assert!(meta_verify(&key, b"x", &meta).unwrap());
        assert!(!meta_verify(&key, b"y", &meta).unwrap());
        assert_ne!(meta, entry_tag(&key, "x", b"x", b"x").unwrap());
        assert!(!meta_verify(&key, b"x", &meta[..31]).unwrap(), "short tag");
        assert_eq!(meta_tag(&[1u8; 31], b"x"), Err(Rejected("record key rejected")));
        assert!(entry_tag(&key, "", b"k", b"v").is_err());
    }

    /// Matches the documented construction computed independently (what the
    /// browser smoke recomputes with WebCrypto to forge a validly tagged record).
    #[test]
    fn meta_tag_matches_documented_construction() {
        let key = [3u8; 32];
        let meta = b"{\"a\":1}";
        let mut message = META.to_vec();
        message.extend((meta.len() as u32).to_le_bytes());
        message.extend(meta);
        let mut mac = <Hmac<Sha256> as Mac>::new_from_slice(&key).unwrap();
        mac.update(&message);
        assert_eq!(meta_tag(&key, meta).unwrap(), mac.finalize().into_bytes().to_vec());
    }
}
