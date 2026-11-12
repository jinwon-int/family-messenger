//! file-v2 detached attachments (#366 slice 3d, wire format `archive/native-mls/FILE-V2.md`).
//!
//! One implementation of the host-neutral rules — descriptor validation, client-id shape,
//! AES-256-GCM open/seal, content sniffing, safe display names — for every Rust host: the bot
//! (`bot/src/attachment.rs` · `attachment_out.rs`) and the Android app through `ios-ffi`.
//! Spool files, frames and relay transport stay with each host.
//!
//! Conformance: `archive/native-mls/tests/fixtures/file-v2-vectors.json` is checked here, by the
//! web `file-v2.js` tests and by the Android Kotlin tests, so the three decide every descriptor
//! the same way (where the web is deliberately more lenient, the vector says so).
//!
//! Secrets: the key and nonce live in [`Descriptor`] only (zeroized on drop, never in `Debug`).
//! Error values are fixed short codes that never carry sender text — safe to log.
use crate::b64;
use aes_gcm::aead::{Aead, KeyInit, Payload};
use aes_gcm::{Aes256Gcm, Nonce};
use serde::de::{self, DeserializeSeed, MapAccess, SeqAccess, Visitor};
use serde_json::{Map, Value};
use sha2::{Digest, Sha256};
use std::fmt;
use std::io::Read;
use zeroize::Zeroizing;

/// FILE-V2 §1 `v`.
pub const VERSION: u64 = 2;
/// FILE-V2 §1 `size`: 1 ~ 50 MiB plaintext (#499 owner decision).
pub const MAX_FILE_V2: u64 = 50 * 1024 * 1024;
/// FILE-V2 §1: the descriptor (MLS plaintext) is at most 4 KiB.
pub const MAX_DESCRIPTOR_BYTES: usize = 4096;
/// FILE-V2 §2 AAD.
pub const FILE_V2_AAD: &[u8] = b"hande-file-v2";
pub const GCM_TAG_BYTES: u64 = 16;
pub const KEY_BYTES: usize = 32;
pub const NONCE_BYTES: usize = 12;
/// FILE-V2 §1 `w`/`h`.
pub const MAX_DIMENSION: u64 = 20_000;
/// Outer relay client-id prefix of a file-v2 message.
pub const CLIENT_PREFIX: &str = "file-v2-";
/// JS `Number.MAX_SAFE_INTEGER` — the web reads descriptor numbers as JS numbers.
const MAX_SAFE_INTEGER: f64 = 9_007_199_254_740_991.0;
/// Same nesting cap as the Kotlin parser (a ≤ 4 KiB descriptor never nests).
const MAX_DEPTH: usize = 32;

const REQUIRED: &[&str] = &["v", "blob", "size", "key", "nonce"];
const OPTIONAL: &[&str] = &["mime", "name", "w", "h"];

/// ccc-node `core/matrix/media.py` `IMAGE_EXTENSIONS` (minus the `image/jpg` alias): the bridge
/// stages exactly these as images, so `kind` follows them.
const IMAGE_MIMES: &[&str] = &[
    "image/jpeg", "image/png", "image/gif", "image/webp", "image/heic", "image/heif", "image/bmp", "image/tiff",
];

/// A validated descriptor. `Debug` never prints the key or nonce.
#[derive(Clone)]
pub struct Descriptor {
    pub blob: String,
    pub size: u64,
    key: Zeroizing<[u8; KEY_BYTES]>,
    nonce: [u8; NONCE_BYTES],
    pub mime: Option<String>,
    pub name: Option<String>,
    pub w: Option<u64>,
    pub h: Option<u64>,
}

impl fmt::Debug for Descriptor {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("Descriptor").field("size", &self.size).finish_non_exhaustive()
    }
}

/// `^file-v2-[a-f0-9-]{36}$` — a display hint, not authentication (FILE-V2 §1).
pub fn is_client_id(client_id: &str) -> bool {
    client_id.len() == CLIENT_PREFIX.len() + 36
        && client_id.starts_with(CLIENT_PREFIX)
        && client_id[CLIENT_PREFIX.len()..].bytes().all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b) || b == b'-')
}

pub fn is_lower_hex(s: &str, len: usize) -> bool {
    s.len() == len && s.bytes().all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
}

/// U+0000–001F and U+007F–009F (the web `CONTROL` class).
pub fn is_control(c: char) -> bool {
    matches!(c as u32, 0x00..=0x1f | 0x7f..=0x9f)
}

fn mime_part_ok(part: &str) -> bool {
    let bytes = part.as_bytes();
    !bytes.is_empty()
        && bytes.len() <= 64
        && bytes[0].is_ascii_alphanumeric()
        && bytes.iter().all(|b| b.is_ascii_alphanumeric() || b"!#$&^_.+-".contains(b))
}

/// FILE-V2 §1 `mime`: ≤ 100 bytes, `type/subtype` (alphanumerics and `!#$&^_.+-`).
pub fn is_mime(mime: &str) -> bool {
    mime.len() <= 100 && mime.split_once('/').is_some_and(|(t, s)| mime_part_ok(t) && mime_part_ok(s))
}

/// FILE-V2 §1 `name`: 1 ~ 255 code points, no control characters.
pub fn is_name(name: &str) -> bool {
    (1..=255).contains(&name.chars().count()) && !name.chars().any(is_control)
}

/// RFC 4648 §5 without padding, canonical only (re-encodes to the same text), like the web
/// `base64urlDecode`.
pub fn b64url_decode(text: &str) -> Option<Vec<u8>> {
    if !text.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_') || text.len() % 4 == 1 {
        return None;
    }
    let mut standard: String = text.chars().map(|c| match c { '-' => '+', '_' => '/', other => other }).collect();
    while standard.len() % 4 != 0 {
        standard.push('=');
    }
    let bytes = b64::decode(&standard).ok()?;
    (*b64url_encode(&bytes) == text).then_some(bytes)
}

/// RFC 4648 §5, no padding. Zeroized: it carries file keys.
pub fn b64url_encode(bytes: &[u8]) -> Zeroizing<String> {
    let standard = Zeroizing::new(b64::encode(bytes));
    Zeroizing::new(standard.trim_end_matches('=').chars().map(|c| match c { '+' => '-', '/' => '_', other => other }).collect())
}

/// JS `Number.isSafeInteger(x) && lo <= x && x <= hi` — so `2.0` and `2e0` are 2, like the web and
/// Kotlin readers.
fn integer(value: Option<&Value>, lo: u64, hi: u64) -> Option<u64> {
    let value = value?;
    let n = match value.as_u64() {
        Some(n) => n,
        None => {
            let d = value.as_f64()?;
            if !d.is_finite() || d.fract() != 0.0 || d.abs() > MAX_SAFE_INTEGER || d < 0.0 {
                return None;
            }
            d as u64
        }
    };
    (n as f64 <= MAX_SAFE_INTEGER && (lo..=hi).contains(&n)).then_some(n)
}

/// JSON value that refuses a repeated object key at any depth (and nesting past [`MAX_DEPTH`]).
/// `serde_json::Value` keeps the last duplicate like `JSON.parse`; the descriptor closes instead,
/// so two clients can never see two different `blob`s in one message (Kotlin `StrictJson`).
struct Strict(usize);

impl<'de> DeserializeSeed<'de> for Strict {
    type Value = Value;
    fn deserialize<D: de::Deserializer<'de>>(self, deserializer: D) -> Result<Value, D::Error> {
        deserializer.deserialize_any(self)
    }
}

impl<'de> Visitor<'de> for Strict {
    type Value = Value;
    fn expecting(&self, f: &mut fmt::Formatter) -> fmt::Result {
        f.write_str("a JSON value")
    }
    fn visit_bool<E>(self, v: bool) -> Result<Value, E> {
        Ok(Value::Bool(v))
    }
    fn visit_i64<E>(self, v: i64) -> Result<Value, E> {
        Ok(Value::from(v))
    }
    fn visit_u64<E>(self, v: u64) -> Result<Value, E> {
        Ok(Value::from(v))
    }
    fn visit_f64<E: de::Error>(self, v: f64) -> Result<Value, E> {
        serde_json::Number::from_f64(v).map(Value::Number).ok_or_else(|| E::custom("number"))
    }
    fn visit_str<E>(self, v: &str) -> Result<Value, E> {
        Ok(Value::String(v.to_owned()))
    }
    fn visit_string<E>(self, v: String) -> Result<Value, E> {
        Ok(Value::String(v))
    }
    fn visit_unit<E>(self) -> Result<Value, E> {
        Ok(Value::Null)
    }
    fn visit_seq<A: SeqAccess<'de>>(self, mut seq: A) -> Result<Value, A::Error> {
        let depth = self.0 + 1;
        if depth > MAX_DEPTH {
            return Err(de::Error::custom("depth"));
        }
        let mut out = Vec::new();
        while let Some(v) = seq.next_element_seed(Strict(depth))? {
            out.push(v);
        }
        Ok(Value::Array(out))
    }
    fn visit_map<A: MapAccess<'de>>(self, mut map: A) -> Result<Value, A::Error> {
        let depth = self.0 + 1;
        if depth > MAX_DEPTH {
            return Err(de::Error::custom("depth"));
        }
        let mut out = Map::new();
        while let Some(k) = map.next_key::<String>()? {
            let v = map.next_value_seed(Strict(depth))?;
            if out.insert(k, v).is_some() {
                return Err(de::Error::custom("duplicate key"));
            }
        }
        Ok(Value::Object(out))
    }
}

fn strict_json(text: &str) -> Option<Value> {
    let mut de = serde_json::Deserializer::from_str(text);
    let value = Strict(0).deserialize(&mut de).ok()?;
    de.end().ok()?;
    Some(value)
}

/// FILE-V2 §1 strict validation, in the web `parseDescriptor` order. The error is a fixed code
/// (`too large` · `not utf-8` · `not json` · `not an object` · `unknown key` · `missing <key>` ·
/// `version` · `blob` · `size` · `key` · `nonce` · `mime` · `name` · `w` · `h`). Any error means the
/// message is an unopenable attachment — never text.
pub fn parse_descriptor(plaintext: &[u8]) -> Result<Descriptor, &'static str> {
    if plaintext.len() > MAX_DESCRIPTOR_BYTES {
        return Err("too large");
    }
    let text = std::str::from_utf8(plaintext).map_err(|_| "not utf-8")?;
    let raw = strict_json(text).ok_or("not json")?;
    let object = raw.as_object().ok_or("not an object")?;
    if object.keys().any(|k| !REQUIRED.contains(&k.as_str()) && !OPTIONAL.contains(&k.as_str())) {
        return Err("unknown key");
    }
    for (k, missing) in REQUIRED.iter().zip(["missing v", "missing blob", "missing size", "missing key", "missing nonce"]) {
        if !object.contains_key(*k) {
            return Err(missing);
        }
    }
    integer(object.get("v"), VERSION, VERSION).ok_or("version")?;
    let blob = object.get("blob").and_then(|v| v.as_str()).filter(|b| is_lower_hex(b, 64)).ok_or("blob")?;
    let size = integer(object.get("size"), 1, MAX_FILE_V2).ok_or("size")?;
    let key_bytes = Zeroizing::new(
        object.get("key").and_then(|v| v.as_str()).and_then(b64url_decode).filter(|k| k.len() == KEY_BYTES).ok_or("key")?,
    );
    let nonce_bytes =
        object.get("nonce").and_then(|v| v.as_str()).and_then(b64url_decode).filter(|n| n.len() == NONCE_BYTES).ok_or("nonce")?;
    let mime = match object.get("mime") {
        None => None,
        Some(v) => Some(v.as_str().filter(|m| is_mime(m)).ok_or("mime")?.to_owned()),
    };
    let name = match object.get("name") {
        None => None,
        Some(v) => Some(v.as_str().filter(|n| is_name(n)).ok_or("name")?.to_owned()),
    };
    let w = match object.get("w") {
        None => None,
        v => Some(integer(v, 1, MAX_DIMENSION).ok_or("w")?),
    };
    let h = match object.get("h") {
        None => None,
        v => Some(integer(v, 1, MAX_DIMENSION).ok_or("h")?),
    };
    let mut key = Zeroizing::new([0u8; KEY_BYTES]);
    key.copy_from_slice(&key_bytes);
    let mut nonce = [0u8; NONCE_BYTES];
    nonce.copy_from_slice(&nonce_bytes);
    Ok(Descriptor { blob: blob.to_owned(), size, key, nonce, mime, name, w, h })
}

pub fn sha256_hex(bytes: &[u8]) -> String {
    Sha256::digest(bytes).iter().map(|b| format!("{b:02x}")).collect()
}

/// FILE-V2 §4.3: length `size + 16` → sha256 = `blob` → AES-256-GCM with the file-v2 AAD →
/// plaintext length = `size`. Every mismatch is `integrity`.
pub fn open(ciphertext: &[u8], descriptor: &Descriptor) -> Result<Zeroizing<Vec<u8>>, &'static str> {
    if ciphertext.len() as u64 != descriptor.size + GCM_TAG_BYTES {
        return Err("integrity");
    }
    if sha256_hex(ciphertext) != descriptor.blob {
        return Err("integrity");
    }
    let cipher = Aes256Gcm::new_from_slice(descriptor.key.as_slice()).map_err(|_| "integrity")?;
    let plaintext = Zeroizing::new(
        cipher
            .decrypt(Nonce::from_slice(&descriptor.nonce), Payload { msg: ciphertext, aad: FILE_V2_AAD })
            .map_err(|_| "integrity")?,
    );
    if plaintext.len() as u64 != descriptor.size {
        return Err("integrity");
    }
    Ok(plaintext)
}

/// What [`seal`] returns: the ciphertext to upload and the descriptor bytes to post (they hold the
/// file key — `Debug` shows neither).
pub struct Sealed {
    pub ciphertext: Vec<u8>,
    pub descriptor: Zeroizing<Vec<u8>>,
    pub blob: String,
}

impl fmt::Debug for Sealed {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("Sealed").field("ciphertext_len", &self.ciphertext.len()).finish_non_exhaustive()
    }
}

/// FILE-V2 §2/§3 with a caller-supplied key and nonce (tests and vectors). Hosts call [`seal`].
/// Errors: `size` (plaintext not 1 ~ 50 MiB) · `mime` · `name` · `too large` (descriptor > 4 KiB) ·
/// `crypto`.
pub fn seal_with(plaintext: &[u8], key: &[u8; KEY_BYTES], nonce: &[u8; NONCE_BYTES], mime: &str, name: Option<&str>) -> Result<Sealed, &'static str> {
    if plaintext.is_empty() || plaintext.len() as u64 > MAX_FILE_V2 {
        return Err("size");
    }
    if !is_mime(mime) {
        return Err("mime");
    }
    if name.is_some_and(|n| !is_name(n)) {
        return Err("name");
    }
    let cipher = Aes256Gcm::new_from_slice(key).map_err(|_| "crypto")?;
    let ciphertext = cipher.encrypt(Nonce::from_slice(nonce), Payload { msg: plaintext, aad: FILE_V2_AAD }).map_err(|_| "crypto")?;
    let blob = sha256_hex(&ciphertext);
    // Canonical key order (web `encodeDescriptor`): v, blob, size, key, nonce, mime, name.
    let mut text = Zeroizing::new(String::with_capacity(MAX_DESCRIPTOR_BYTES));
    text.push_str(&format!(r#"{{"v":2,"blob":"{blob}","size":{},"key":""#, plaintext.len()));
    text.push_str(&b64url_encode(key));
    text.push_str(r#"","nonce":""#);
    text.push_str(&b64url_encode(nonce));
    text.push_str(&format!(r#"","mime":"{mime}""#));
    if let Some(name) = name {
        text.push_str(r#","name":"#);
        text.push_str(&serde_json::to_string(name).map_err(|_| "name")?);
    }
    text.push('}');
    if text.len() > MAX_DESCRIPTOR_BYTES {
        return Err("too large");
    }
    Ok(Sealed { ciphertext, descriptor: Zeroizing::new(text.as_bytes().to_vec()), blob })
}

/// FILE-V2 §2: a fresh random key and nonce from `/dev/urandom` (Linux, Android), never reused.
/// Errors: [`seal_with`]'s, plus `random`.
pub fn seal(plaintext: &[u8], mime: &str, name: Option<&str>) -> Result<Sealed, &'static str> {
    let mut secret = Zeroizing::new([0u8; KEY_BYTES + NONCE_BYTES]);
    std::fs::File::open("/dev/urandom").and_then(|mut f| f.read_exact(secret.as_mut_slice())).map_err(|_| "random")?;
    let mut key = Zeroizing::new([0u8; KEY_BYTES]);
    key.copy_from_slice(&secret[..KEY_BYTES]);
    let mut nonce = [0u8; NONCE_BYTES];
    nonce.copy_from_slice(&secret[KEY_BYTES..]);
    seal_with(plaintext, &key, &nonce, mime, name)
}

/// A fresh outer client id `file-v2-<uuid v4>` (FILE-V2 §1 — the shape [`is_client_id`] accepts). The
/// relay dedups per device on it, so it must never repeat; `/dev/urandom` with a time+counter
/// fallback (same as the bot's `uuid_client_id`). A display hint only — the MLS AAD still names the device.
pub fn new_client_id() -> String {
    let mut bytes = [0u8; 16];
    let filled = std::fs::File::open("/dev/urandom").and_then(|mut f| f.read_exact(&mut bytes)).is_ok();
    if !filled {
        use std::sync::atomic::{AtomicU64, Ordering};
        static COUNTER: AtomicU64 = AtomicU64::new(0);
        let nanos = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_nanos() as u64).unwrap_or(0);
        bytes[..8].copy_from_slice(&nanos.to_le_bytes());
        bytes[8..].copy_from_slice(&COUNTER.fetch_add(1, Ordering::Relaxed).to_le_bytes());
    }
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    let hex: String = bytes.iter().map(|b| format!("{b:02x}")).collect();
    format!("{CLIENT_PREFIX}{}-{}-{}-{}-{}", &hex[0..8], &hex[8..12], &hex[12..16], &hex[16..20], &hex[20..32])
}

/// FILE-V2 §4.4: the MIME comes from the content (magic bytes), never from the descriptor hint.
pub fn sniff_mime(bytes: &[u8]) -> &'static str {
    let starts = |magic: &[u8]| bytes.starts_with(magic);
    if starts(&[0xff, 0xd8, 0xff]) {
        return "image/jpeg";
    }
    if starts(b"\x89PNG\r\n\x1a\n") {
        return "image/png";
    }
    if starts(b"GIF87a") || starts(b"GIF89a") {
        return "image/gif";
    }
    if bytes.len() >= 12 && &bytes[..4] == b"RIFF" && &bytes[8..12] == b"WEBP" {
        return "image/webp";
    }
    if bytes.len() >= 12 && &bytes[4..8] == b"ftyp" {
        match &bytes[8..12] {
            b"heic" | b"heix" | b"hevc" | b"hevx" | b"heim" | b"heis" => return "image/heic",
            b"mif1" | b"msf1" => return "image/heif",
            _ => {}
        }
    }
    if starts(b"BM") && bytes.len() >= 26 {
        return "image/bmp";
    }
    if starts(b"II*\0") || starts(b"MM\0*") {
        return "image/tiff";
    }
    if starts(b"%PDF-") {
        return "application/pdf";
    }
    if starts(b"PK\x03\x04") {
        return "application/zip";
    }
    if !bytes.contains(&0) && std::str::from_utf8(bytes).is_ok() {
        return "text/plain";
    }
    "application/octet-stream"
}

/// `image` for the MIMEs the bridge stages as images, else `file`.
pub fn kind_for(mime: &str) -> &'static str {
    if IMAGE_MIMES.contains(&mime) { "image" } else { "file" }
}

/// FILE-V2 saved-name rule: a name carrying a bidirectional control is not used (it can disguise
/// an extension).
pub fn display_name(name: Option<&str>) -> Option<String> {
    let name = name?;
    let bidi = |c: char| matches!(c as u32, 0x061c | 0x200e | 0x200f | 0x202a..=0x202e | 0x2066..=0x2069);
    (!name.chars().any(bidi)).then(|| name.to_owned())
}

/// How a host stores one decrypted application message (FILE-V2 §4.1, STATUS-V1): the Android
/// `FileV2.classify` decision, minus the UI strings.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Classified {
    /// `status-<uuid>`: a transient agent status line — not stored.
    Status,
    /// `file-v1-…`: the plaintext is the file itself.
    FileV1,
    /// `file-v2-<uuid>` with a valid descriptor; `size` is the declared plaintext size.
    FileV2 { size: u64 },
    /// `file-v2-…` that is not canonical or whose descriptor fails: never shown as text.
    Undecryptable,
    /// Anything else.
    Text,
}

fn is_status_client_id(client_id: &str) -> bool {
    const PREFIX: &str = "status-";
    client_id.len() == PREFIX.len() + 36
        && client_id.starts_with(PREFIX)
        && client_id[PREFIX.len()..].bytes().all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b) || b == b'-')
}

pub fn classify(client_id: &str, plaintext: &[u8]) -> Classified {
    if is_status_client_id(client_id) {
        return Classified::Status;
    }
    if client_id.starts_with("file-v1-") {
        return Classified::FileV1;
    }
    if client_id.starts_with(CLIENT_PREFIX) {
        if !is_client_id(client_id) {
            return Classified::Undecryptable;
        }
        return match parse_descriptor(plaintext) {
            Ok(d) => Classified::FileV2 { size: d.size },
            Err(_) => Classified::Undecryptable,
        };
    }
    Classified::Text
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;

    /// Produced by WebCrypto exactly as the web `encryptFile` does (AES-GCM, 128-bit tag, AAD
    /// `hande-file-v2`) with a fixed key and nonce.
    pub(crate) const VECTOR_PLAIN_HEX: &str = "89504e470d0a1a0a2068616e64652066696c652d763220766563746f72";
    pub(crate) const VECTOR_CT_HEX: &str = "30817321f0bf400e5f66c30595e000e23ebbd5342e5a40f24238a192208844c4010d71ace6fbebaf73a07149cb";
    pub(crate) const VECTOR_BLOB: &str = "85ccb62b89f2866df3a2a31af621056988905cda26061dd4978c6795a545f317";
    pub(crate) const VECTOR_KEY: &str = "AQIDBAUGBwgJCgsMDQ4PEBESExQVFhcYGRobHB0eHyA";
    pub(crate) const VECTOR_NONCE: &str = "oKGio6Slpqeoqaqr";

    pub(crate) fn unhex(s: &str) -> Vec<u8> {
        (0..s.len()).step_by(2).map(|i| u8::from_str_radix(&s[i..i + 2], 16).unwrap()).collect()
    }

    fn vector_json(extra: &str) -> String {
        format!(r#"{{"v":2,"blob":"{VECTOR_BLOB}","size":29,"key":"{VECTOR_KEY}","nonce":"{VECTOR_NONCE}","mime":"image/png","name":"사진.png"{extra}}}"#)
    }

    #[test]
    fn web_vector_opens_and_never_shows_the_key() {
        let d = parse_descriptor(vector_json("").as_bytes()).unwrap();
        assert_eq!((d.size, d.mime.as_deref(), d.name.as_deref()), (29, Some("image/png"), Some("사진.png")));
        let plain = open(&unhex(VECTOR_CT_HEX), &d).unwrap();
        assert_eq!(plain.as_slice(), unhex(VECTOR_PLAIN_HEX).as_slice());
        assert_eq!(sniff_mime(&plain), "image/png");
        let shown = format!("{d:?}");
        assert!(!shown.contains(VECTOR_KEY) && !shown.contains("AQID"), "{shown}");
    }

    #[test]
    fn seal_with_the_vector_key_reproduces_the_web_ciphertext() {
        let key: [u8; 32] = b64url_decode(VECTOR_KEY).unwrap().try_into().unwrap();
        let nonce: [u8; 12] = b64url_decode(VECTOR_NONCE).unwrap().try_into().unwrap();
        let sealed = seal_with(&unhex(VECTOR_PLAIN_HEX), &key, &nonce, "image/png", Some("사진.png")).unwrap();
        assert_eq!(sealed.ciphertext, unhex(VECTOR_CT_HEX));
        assert_eq!(sealed.blob, VECTOR_BLOB);
        assert_eq!(std::str::from_utf8(&sealed.descriptor).unwrap(), vector_json(""));
        assert!(!format!("{sealed:?}").contains(VECTOR_KEY));
        assert_eq!(seal_with(b"", &key, &nonce, "image/png", None).unwrap_err(), "size");
        assert_eq!(seal_with(b"x", &key, &nonce, "image", None).unwrap_err(), "mime");
        assert_eq!(seal_with(b"x", &key, &nonce, "text/plain", Some("")).unwrap_err(), "name");
    }

    #[test]
    fn seal_uses_a_fresh_key_and_round_trips() {
        let a = seal(b"%PDF-1.7 doc", "application/pdf", Some("r.pdf")).unwrap();
        let b = seal(b"%PDF-1.7 doc", "application/pdf", Some("r.pdf")).unwrap();
        assert_ne!(a.ciphertext, b.ciphertext);
        let d = parse_descriptor(&a.descriptor).unwrap();
        assert_eq!(open(&a.ciphertext, &d).unwrap().as_slice(), b"%PDF-1.7 doc");
    }

    #[test]
    fn tampered_or_mismatched_ciphertext_is_integrity() {
        let d = parse_descriptor(vector_json("").as_bytes()).unwrap();
        let mut ct = unhex(VECTOR_CT_HEX);
        ct[3] ^= 1;
        assert_eq!(open(&ct, &d).unwrap_err(), "integrity");
        assert_eq!(open(&ct[..ct.len() - 1], &d).unwrap_err(), "integrity");
        let forged = format!(r#"{{"v":2,"blob":"{}","size":29,"key":"{VECTOR_KEY}","nonce":"{VECTOR_NONCE}"}}"#, sha256_hex(&ct));
        assert_eq!(open(&ct, &parse_descriptor(forged.as_bytes()).unwrap()).unwrap_err(), "integrity");
    }

    #[test]
    fn new_client_ids_are_canonical_and_fresh() {
        let a = new_client_id();
        let b = new_client_id();
        assert!(is_client_id(&a) && is_client_id(&b), "{a} {b}");
        assert_ne!(a, b);
        assert_eq!(classify(&a, b"not a descriptor"), Classified::Undecryptable, "never text");
    }

    #[test]
    fn sniffing_kind_and_names() {
        assert_eq!(sniff_mime(&[0xff, 0xd8, 0xff, 0xe0]), "image/jpeg");
        assert_eq!(sniff_mime(b"\0\0\0\x18ftypheic\0\0\0\0"), "image/heic");
        assert_eq!(sniff_mime(b"\x00\x01\x02"), "application/octet-stream");
        assert_eq!(kind_for("image/png"), "image");
        assert_eq!(kind_for("application/pdf"), "file");
        assert_eq!(display_name(Some("photo\u{202e}gpj.exe")), None);
        assert_eq!(display_name(Some("사진.jpg")).as_deref(), Some("사진.jpg"));
    }

    /// The shared conformance vectors (also run by the web and Android tests).
    #[test]
    fn shared_vectors() {
        let path = concat!(env!("CARGO_MANIFEST_DIR"), "/../tests/fixtures/file-v2-vectors.json");
        let doc: Value = serde_json::from_str(&std::fs::read_to_string(path).unwrap()).unwrap();
        let mut n = 0;
        for case in doc["descriptors"].as_array().unwrap() {
            let name = case["name"].as_str().unwrap();
            let bytes = match case["hex"].as_str() {
                Some(hex) => unhex(hex),
                None => case["text"].as_str().unwrap().as_bytes().to_vec(),
            };
            let got = parse_descriptor(&bytes);
            match case["expect"].as_str().unwrap() {
                "accept" => {
                    let d = got.unwrap_or_else(|e| panic!("{name}: rejected {e}"));
                    assert_eq!(d.size, case["size"].as_u64().unwrap(), "{name}");
                }
                "reject" => {
                    let e = got.err().unwrap_or_else(|| panic!("{name}: accepted"));
                    if let Some(reason) = case["reason"].as_str() {
                        assert_eq!(e, reason, "{name}");
                    }
                }
                other => panic!("{name}: expect {other}"),
            }
            n += 1;
        }
        for case in doc["classify"].as_array().unwrap() {
            let name = case["name"].as_str().unwrap();
            let got = classify(case["client_id"].as_str().unwrap(), case["plaintext"].as_str().unwrap().as_bytes());
            let want = match case["kind"].as_str().unwrap() {
                "status" => Classified::Status,
                "file-v1" => Classified::FileV1,
                "file-v2" => Classified::FileV2 { size: case["size"].as_u64().unwrap() },
                "undecryptable" => Classified::Undecryptable,
                "text" => Classified::Text,
                other => panic!("{name}: kind {other}"),
            };
            assert_eq!(got, want, "{name}");
            n += 1;
        }
        let ct = &doc["ciphertext"];
        let d = parse_descriptor(ct["descriptor"].as_str().unwrap().as_bytes()).unwrap();
        assert_eq!(open(&unhex(ct["ciphertext_hex"].as_str().unwrap()), &d).unwrap().as_slice(), unhex(ct["plaintext_hex"].as_str().unwrap()).as_slice());
        assert!(n >= 60, "only {n} vectors");
    }
}
