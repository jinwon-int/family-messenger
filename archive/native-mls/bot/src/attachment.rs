//! #636: 「한데」 attachments as agent turns (`docs/FLEET-WORKER.md` "첨부 turn —
//! `attachment`", `archive/native-mls/FILE-V2.md` §4).
//!
//! The bot is the only party that holds both the MLS plaintext (the file-v2
//! descriptor with the per-file key) and the relay credentials, so it fetches,
//! verifies and decrypts here and hands the worker a **path**: the plaintext
//! goes to a 0600 file in the spool directory, and the `turn` frame names it.
//! The key, nonce and blob id never leave this process (not in a frame, not in
//! the journal, not in `<state>.inbox.json`).
//!
//! Ownership: the bridge takes the spool file over by renaming it; whatever is
//! still there when the turn ends (bridge knob off, refused, old worker) is
//! removed by the responder, and the spool is emptied at start-up.

use aes_gcm::aead::{Aead, KeyInit, Payload};
use aes_gcm::{Aes256Gcm, Nonce};
use native_mls_host::b64;
use sha2::{Digest, Sha256};
use std::fmt;
use std::io::{Read, Write};
use std::path::{Path, PathBuf};
use std::sync::Arc;
use zeroize::Zeroizing;

/// FILE-V2 §2: 1 ~ 50 MiB plaintext.
pub const MAX_FILE_V2: u64 = 50 * 1024 * 1024;
pub const MAX_DESCRIPTOR_BYTES: usize = 4096;
pub const FILE_V2_AAD: &[u8] = b"hande-file-v2";
/// Matches the ccc-node default (`max_document_size_mb` = 10, decimal MB).
pub const DEFAULT_MAX_BYTES: u64 = 10_000_000;
const GCM_TAG_BYTES: u64 = 16;
const MAX_DIMENSION: u64 = 20_000;
/// #636 stage 2: how long an owner attachment waits for the sender's next
/// plain text, which then rides along as `attachment.caption` (0 = never wait).
pub const DEFAULT_CAPTION_SECS: u64 = 10;
pub const MAX_CAPTION_SECS: u64 = 120;
/// ccc-node `MAX_CAPTION_BYTES` is 8 KiB; stay under it.
pub const MAX_CAPTION_BYTES: usize = 8000;
/// Frame contract version (`attachment.v`).
pub const FRAME_VERSION: u64 = 1;

/// ccc-node `core/matrix/media.py` `IMAGE_EXTENSIONS` (minus the `image/jpg`
/// alias): the bridge stages exactly these as images, so `kind` follows them.
const IMAGE_MIMES: &[&str] = &[
    "image/jpeg", "image/png", "image/gif", "image/webp", "image/heic", "image/heif", "image/bmp", "image/tiff",
];

/// The responder settings for attachment turns (`None` = off, the default).
#[derive(Clone, Debug)]
pub struct AttachmentConfig {
    /// Absolute path; the bridge's `attachment_spool_dir` must be the same string.
    pub spool_dir: PathBuf,
    pub max_bytes: u64,
    /// Stage 2 caption window in seconds (0 = off): see `DEFAULT_CAPTION_SECS`.
    pub caption_secs: u64,
}

/// `(room, blob id) → ciphertext`. The poll loop installs one bound to its
/// relay client settings; tests install a fake.
pub type Fetcher = Arc<dyn Fn(&str, &str) -> Result<Vec<u8>, String> + Send + Sync>;

/// A validated file-v2 descriptor. `Debug` never prints the key or nonce.
#[derive(Clone)]
pub struct Descriptor {
    pub blob: String,
    pub size: u64,
    key: Zeroizing<[u8; 32]>,
    nonce: [u8; 12],
    pub name: Option<String>,
}

impl fmt::Debug for Descriptor {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("Descriptor").field("size", &self.size).finish_non_exhaustive()
    }
}

/// What a queued attachment turn carries until it starts (memory only).
#[derive(Clone)]
pub enum Source {
    /// file-v1: the MLS plaintext is the file itself (≤ 5 MiB, legacy).
    V1(Zeroizing<Vec<u8>>),
    /// file-v2: fetch the blob when the turn starts.
    V2(Descriptor),
}

impl Source {
    /// The size the sender declared (v1: the bytes we already hold).
    pub fn size(&self) -> u64 {
        match self {
            Source::V1(bytes) => bytes.len() as u64,
            Source::V2(descriptor) => descriptor.size,
        }
    }
}

impl fmt::Debug for Source {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Source::V1(bytes) => write!(f, "V1({} B)", bytes.len()),
            Source::V2(descriptor) => write!(f, "V2({} B)", descriptor.size),
        }
    }
}

fn is_lower_hex(s: &str, len: usize) -> bool {
    s.len() == len && s.bytes().all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
}

/// RFC 4648 §5 without padding, canonical only (re-encodes to the same text),
/// like the web `base64urlDecode`.
fn b64url_decode(text: &str) -> Option<Vec<u8>> {
    if !text.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_') || text.len() % 4 == 1 {
        return None;
    }
    let mut standard: String = text.chars().map(|c| match c { '-' => '+', '_' => '/', other => other }).collect();
    while standard.len() % 4 != 0 {
        standard.push('=');
    }
    let bytes = b64::decode(&standard).ok()?;
    let again: String = b64::encode(&bytes).trim_end_matches('=').chars().map(|c| match c { '+' => '-', '/' => '_', other => other }).collect();
    (again == text).then_some(bytes)
}

fn is_control(c: char) -> bool {
    matches!(c as u32, 0x00..=0x1f | 0x7f..=0x9f)
}

fn mime_part_ok(part: &str) -> bool {
    let bytes = part.as_bytes();
    !bytes.is_empty()
        && bytes.len() <= 64
        && bytes[0].is_ascii_alphanumeric()
        && bytes.iter().all(|b| b.is_ascii_alphanumeric() || b"!#$&^_.+-".contains(b))
}

/// FILE-V2 §1 strict validation (the web `parseDescriptor` rules). Any error
/// means the message is an unopenable attachment — never a text turn.
pub fn parse_descriptor(plaintext: &[u8]) -> Result<Descriptor, &'static str> {
    if plaintext.len() > MAX_DESCRIPTOR_BYTES {
        return Err("too large");
    }
    let text = std::str::from_utf8(plaintext).map_err(|_| "not utf-8")?;
    let raw: serde_json::Value = serde_json::from_str(text).map_err(|_| "not json")?;
    let object = raw.as_object().ok_or("not an object")?;
    const ALLOWED: &[&str] = &["blob", "key", "nonce", "size", "v", "h", "mime", "name", "w"];
    if object.keys().any(|k| !ALLOWED.contains(&k.as_str())) {
        return Err("unknown key");
    }
    if object.get("v").and_then(|v| v.as_u64()) != Some(2) {
        return Err("version");
    }
    let blob = object.get("blob").and_then(|v| v.as_str()).filter(|b| is_lower_hex(b, 64)).ok_or("blob")?;
    let size = object.get("size").and_then(|v| v.as_u64()).filter(|s| (1..=MAX_FILE_V2).contains(s)).ok_or("size")?;
    let key_bytes = Zeroizing::new(
        object.get("key").and_then(|v| v.as_str()).and_then(b64url_decode).filter(|k| k.len() == 32).ok_or("key")?,
    );
    let nonce_bytes = object.get("nonce").and_then(|v| v.as_str()).and_then(b64url_decode).filter(|n| n.len() == 12).ok_or("nonce")?;
    if let Some(mime) = object.get("mime") {
        let mime = mime.as_str().ok_or("mime")?;
        let valid = mime.len() <= 100 && mime.split_once('/').is_some_and(|(t, s)| mime_part_ok(t) && mime_part_ok(s));
        if !valid {
            return Err("mime");
        }
    }
    let name = match object.get("name") {
        None => None,
        Some(value) => {
            let name = value.as_str().ok_or("name")?;
            let chars = name.chars().count();
            if !(1..=255).contains(&chars) || name.chars().any(is_control) {
                return Err("name");
            }
            Some(name.to_string())
        }
    };
    for k in ["w", "h"] {
        if let Some(value) = object.get(k) {
            if !value.as_u64().is_some_and(|d| (1..=MAX_DIMENSION).contains(&d)) {
                return Err("dimension");
            }
        }
    }
    let mut key = Zeroizing::new([0u8; 32]);
    key.copy_from_slice(&key_bytes);
    let mut nonce = [0u8; 12];
    nonce.copy_from_slice(&nonce_bytes);
    Ok(Descriptor { blob: blob.to_string(), size, key, nonce, name })
}

pub fn sha256_hex(bytes: &[u8]) -> String {
    Sha256::digest(bytes).iter().map(|b| format!("{b:02x}")).collect()
}

/// FILE-V2 §4.3: length `size + 16` → sha256 = `blob` → AES-256-GCM with the
/// file-v2 AAD → plaintext length = `size`. Every mismatch is `integrity`.
pub fn open_v2(ciphertext: &[u8], descriptor: &Descriptor) -> Result<Zeroizing<Vec<u8>>, &'static str> {
    if ciphertext.len() as u64 != descriptor.size + GCM_TAG_BYTES {
        return Err("integrity");
    }
    if sha256_hex(ciphertext) != descriptor.blob {
        return Err("integrity");
    }
    let cipher = Aes256Gcm::new_from_slice(descriptor.key.as_slice()).map_err(|_| "integrity")?;
    let plaintext = cipher
        .decrypt(Nonce::from_slice(&descriptor.nonce), Payload { msg: ciphertext, aad: FILE_V2_AAD })
        .map_err(|_| "integrity")?;
    let plaintext = Zeroizing::new(plaintext);
    if plaintext.len() as u64 != descriptor.size {
        return Err("integrity");
    }
    Ok(plaintext)
}

/// FILE-V2 §4.4: the MIME comes from the content (magic bytes), never from the
/// descriptor hint.
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

pub fn kind_for(mime: &str) -> &'static str {
    if IMAGE_MIMES.contains(&mime) { "image" } else { "file" }
}

/// FILE-V2 saved-name rule: a name carrying a bidirectional control is not
/// used (it can disguise an extension); the key is then left out.
pub fn display_name(name: Option<&str>) -> Option<String> {
    let name = name?;
    let bidi = |c: char| matches!(c as u32, 0x061c | 0x200e | 0x200f | 0x202a..=0x202e | 0x2066..=0x2069);
    (!name.chars().any(bidi)).then(|| name.to_string())
}

/// One plaintext file left in the spool for the active turn.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Spooled {
    pub path: PathBuf,
    pub kind: &'static str,
    pub mime: &'static str,
    pub name: Option<String>,
    pub size: u64,
    pub sha256: String,
}

fn is_spool_name(name: &str) -> bool {
    name.is_ascii() && name.len() == 36 && name.ends_with(".bin") && is_lower_hex(&name[..32], 32)
}

fn random_hex() -> Result<String, &'static str> {
    let mut bytes = [0u8; 16];
    std::fs::File::open("/dev/urandom").and_then(|mut f| f.read_exact(&mut bytes)).map_err(|_| "storage")?;
    Ok(bytes.iter().map(|b| format!("{b:02x}")).collect())
}

/// The spool must be a real directory (not a symlink); created 0700 if missing.
fn ensure_spool(dir: &Path) -> Result<(), &'static str> {
    if !dir.is_absolute() {
        return Err("storage");
    }
    if std::fs::symlink_metadata(dir).is_err() {
        let mut builder = std::fs::DirBuilder::new();
        builder.recursive(true);
        #[cfg(unix)]
        {
            use std::os::unix::fs::DirBuilderExt;
            builder.mode(0o700);
        }
        builder.create(dir).map_err(|_| "storage")?;
    }
    let meta = std::fs::symlink_metadata(dir).map_err(|_| "storage")?;
    if meta.file_type().is_symlink() || !meta.is_dir() {
        return Err("storage");
    }
    Ok(())
}

/// The spool file mode follows the directory: a directory its group may
/// **write** (the Linux layout — bot-owned, group `native-relay-bot`, 2770, so
/// a non-root bridge in that group can read and rename) gets 0640 files; any
/// other (Termux 0700, an ordinary 0755) gets 0600. No setting to forget.
pub fn spool_file_mode(dir: &Path) -> u32 {
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        if std::fs::metadata(dir).is_ok_and(|m| m.permissions().mode() & 0o020 != 0) {
            return 0o640;
        }
    }
    0o600
}

/// Write `bytes` to a fresh `<32 hex>.bin` (create-new, 0600 or 0640 per
/// `spool_file_mode`, fsync).
pub fn spool(dir: &Path, bytes: &[u8], name: Option<String>) -> Result<Spooled, &'static str> {
    ensure_spool(dir)?;
    let path = dir.join(format!("{}.bin", random_hex()?));
    let mut options = std::fs::OpenOptions::new();
    options.write(true).create_new(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.mode(spool_file_mode(dir));
    }
    let mut file = options.open(&path).map_err(|_| "storage")?;
    if file.write_all(bytes).and_then(|()| file.sync_all()).is_err() {
        drop(file);
        let _ = std::fs::remove_file(&path);
        return Err("storage");
    }
    let mime = sniff_mime(bytes);
    Ok(Spooled { path, kind: kind_for(mime), mime, name, size: bytes.len() as u64, sha256: sha256_hex(bytes) })
}

/// Start-up: remove every spool file a previous run left behind (only names
/// this module writes; `remove_file` never follows a symlink).
pub fn sweep_spool(dir: &Path) -> usize {
    let Ok(entries) = std::fs::read_dir(dir) else { return 0 };
    let mut removed = 0;
    for entry in entries.flatten() {
        if entry.file_name().to_str().is_some_and(is_spool_name) && std::fs::remove_file(entry.path()).is_ok() {
            removed += 1;
        }
    }
    removed
}

pub fn remove_spooled(path: &Path) {
    let _ = std::fs::remove_file(path);
}

/// Fetch (v2) or take (v1), verify, decrypt and spool one attachment.
/// Errors: `oversize`, `download`, `integrity`, `storage`.
pub fn prepare(source: &Source, room: &str, config: &AttachmentConfig, fetch: Option<&Fetcher>) -> Result<Spooled, &'static str> {
    if source.size() == 0 {
        return Err("integrity");
    }
    if source.size() > config.max_bytes {
        return Err("oversize");
    }
    match source {
        Source::V1(bytes) => spool(&config.spool_dir, bytes, None),
        Source::V2(descriptor) => {
            let fetch = fetch.ok_or("download")?;
            let ciphertext = fetch(room, &descriptor.blob).map_err(|_| "download")?;
            let plaintext = open_v2(&ciphertext, descriptor)?;
            spool(&config.spool_dir, &plaintext, display_name(descriptor.name.as_deref()))
        }
    }
}

/// `turn.prompt` for an attachment turn: what a worker that ignores
/// `attachment` (an older `fleet_worker.py` / `native-responder` / ccc-node, or
/// the bridge knob off) runs on — it then says the file could not be opened,
/// and still sees the caption (the person's question) after it.
pub fn fallback_prompt(spooled: &Spooled, caption: &str) -> String {
    let what = if spooled.kind == "image" { "사진 1개" } else { "파일 1개" };
    let line = format!(
        "[첨부: {what}({}, {} B) — 이 실행부는 첨부를 열 수 없습니다. 받았지만 볼 수 없다고 답하세요.]",
        spooled.mime, spooled.size
    );
    if caption.is_empty() { line } else { format!("{line}\n{caption}") }
}

/// Stage 2: may this text become an attachment's caption? Commands (`/…`)
/// never do — they keep their own meaning (approval replies and `/stop` are
/// routed before any offer, so they never get here).
pub fn is_caption_text(text: &str) -> bool {
    let text = text.trim();
    !text.is_empty() && !text.starts_with('/')
}

/// The `turn.attachment` object (FLEET-WORKER contract v1). `caption` is the
/// sender's next plain text when the stage-2 window merged one, else empty.
pub fn frame_object(spooled: &Spooled, caption: &str) -> serde_json::Value {
    let mut object = serde_json::json!({
        "v": FRAME_VERSION,
        "path": spooled.path.to_string_lossy(),
        "kind": spooled.kind,
        "mime": spooled.mime,
        "size": spooled.size,
        "sha256": spooled.sha256,
        "caption": caption,
    });
    if let Some(name) = &spooled.name {
        object["name"] = serde_json::Value::String(name.clone());
    }
    object
}

/// The one room line for an attachment that could not be prepared (no turn
/// runs). Same wording as the ccc-node Matrix `ATTACHMENT_FAILED`.
pub fn failure_text(reason: &str) -> &'static str {
    match reason {
        "oversize" => "❌ 첨부가 허용 크기를 넘어 열지 않았습니다. 더 작은 파일(또는 해상도를 낮춘 사진)로 보내 주세요.",
        "integrity" => "❌ 첨부의 무결성 확인에 실패해 열지 않았습니다. 다시 보내 주세요.",
        "download" => "❌ 첨부를 내려받지 못했습니다. 잠시 후 다시 보내 주세요.",
        _ => "❌ 첨부를 열 수 없었습니다. 잠시 후 다시 보내 주세요.",
    }
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;

    /// Produced by WebCrypto exactly as the web `encryptFile` does (AES-GCM,
    /// 128-bit tag, AAD `hande-file-v2`) with a fixed key and nonce.
    pub(crate) const VECTOR_PLAIN_HEX: &str = "89504e470d0a1a0a2068616e64652066696c652d763220766563746f72";
    pub(crate) const VECTOR_CT_HEX: &str = "30817321f0bf400e5f66c30595e000e23ebbd5342e5a40f24238a192208844c4010d71ace6fbebaf73a07149cb";
    pub(crate) const VECTOR_BLOB: &str = "85ccb62b89f2866df3a2a31af621056988905cda26061dd4978c6795a545f317";
    pub(crate) const VECTOR_KEY: &str = "AQIDBAUGBwgJCgsMDQ4PEBESExQVFhcYGRobHB0eHyA";
    pub(crate) const VECTOR_NONCE: &str = "oKGio6Slpqeoqaqr";

    pub(crate) fn unhex(s: &str) -> Vec<u8> {
        (0..s.len()).step_by(2).map(|i| u8::from_str_radix(&s[i..i + 2], 16).unwrap()).collect()
    }

    pub(crate) fn vector_descriptor_json(extra: &str) -> String {
        format!(r#"{{"v":2,"blob":"{VECTOR_BLOB}","size":29,"key":"{VECTOR_KEY}","nonce":"{VECTOR_NONCE}","mime":"image/png","name":"사진.png"{extra}}}"#)
    }

    fn temp_dir(tag: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!("nmls-att-{tag}-{}", random_hex().unwrap()));
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    #[test]
    fn web_vector_opens_and_sniffs_as_png() {
        let descriptor = parse_descriptor(vector_descriptor_json("").as_bytes()).unwrap();
        assert_eq!(descriptor.size, 29);
        assert_eq!(descriptor.name.as_deref(), Some("사진.png"));
        let plain = open_v2(&unhex(VECTOR_CT_HEX), &descriptor).unwrap();
        assert_eq!(plain.as_slice(), unhex(VECTOR_PLAIN_HEX).as_slice());
        assert_eq!(sniff_mime(&plain), "image/png");
        // Debug never shows key material.
        let shown = format!("{descriptor:?} {:?}", Source::V2(descriptor.clone()));
        assert!(!shown.contains(VECTOR_KEY) && !shown.contains("AQID"), "{shown}");
    }

    #[test]
    fn tampered_or_mismatched_ciphertext_is_integrity() {
        let descriptor = parse_descriptor(vector_descriptor_json("").as_bytes()).unwrap();
        let mut ct = unhex(VECTOR_CT_HEX);
        ct[3] ^= 1;
        assert_eq!(open_v2(&ct, &descriptor).unwrap_err(), "integrity"); // sha256 no longer = blob
        assert_eq!(open_v2(&ct[..ct.len() - 1], &descriptor).unwrap_err(), "integrity");
        // Right blob hash but wrong AAD/key would fail GCM: forge a descriptor
        // whose blob matches tampered bytes.
        let forged = format!(r#"{{"v":2,"blob":"{}","size":29,"key":"{VECTOR_KEY}","nonce":"{VECTOR_NONCE}"}}"#, sha256_hex(&ct));
        let forged = parse_descriptor(forged.as_bytes()).unwrap();
        assert_eq!(open_v2(&ct, &forged).unwrap_err(), "integrity");
    }

    #[test]
    fn descriptor_rules_match_the_web_parser() {
        assert!(parse_descriptor(vector_descriptor_json(r#","w":4032,"h":3024"#).as_bytes()).is_ok());
        let bad = [
            vector_descriptor_json(r#","extra":1"#),
            vector_descriptor_json(r#","w":0"#),
            vector_descriptor_json(r#","w":20001"#),
            r#"{"v":1}"#.to_string(),
            format!(r#"{{"v":2,"blob":"{}","size":29,"key":"{VECTOR_KEY}","nonce":"{VECTOR_NONCE}"}}"#, VECTOR_BLOB.to_uppercase()),
            format!(r#"{{"v":2,"blob":"{VECTOR_BLOB}","size":0,"key":"{VECTOR_KEY}","nonce":"{VECTOR_NONCE}"}}"#),
            format!(r#"{{"v":2,"blob":"{VECTOR_BLOB}","size":52428801,"key":"{VECTOR_KEY}","nonce":"{VECTOR_NONCE}"}}"#),
            format!(r#"{{"v":2,"blob":"{VECTOR_BLOB}","size":29,"key":"{VECTOR_KEY}=","nonce":"{VECTOR_NONCE}"}}"#),
            format!(r#"{{"v":2,"blob":"{VECTOR_BLOB}","size":29,"key":"AQID","nonce":"{VECTOR_NONCE}"}}"#),
            // 32 B → 43 chars: the last char's two spare bits must be zero.
            format!(r#"{{"v":2,"blob":"{VECTOR_BLOB}","size":29,"key":"AQIDBAUGBwgJCgsMDQ4PEBESExQVFhcYGRobHB0eHyB","nonce":"{VECTOR_NONCE}"}}"#),
            format!(r#"{{"v":2,"blob":"{VECTOR_BLOB}","size":29,"key":"{VECTOR_KEY}","nonce":"{VECTOR_NONCE}","mime":"image"}}"#),
            format!(r#"{{"v":2,"blob":"{VECTOR_BLOB}","size":29,"key":"{VECTOR_KEY}","nonce":"{VECTOR_NONCE}","name":"a\u0007b"}}"#),
            format!(r#"{{"v":2,"blob":"{VECTOR_BLOB}","size":29,"key":"{VECTOR_KEY}","nonce":"{VECTOR_NONCE}","name":""}}"#),
            "[]".to_string(),
            "not json".to_string(),
        ];
        for text in bad {
            assert!(parse_descriptor(text.as_bytes()).is_err(), "{text}");
        }
        assert!(parse_descriptor(&vec![b' '; MAX_DESCRIPTOR_BYTES + 1]).is_err());
        assert!(parse_descriptor(b"\xff\xfe").is_err());
    }

    #[test]
    fn sniffing_follows_content_and_kind_follows_the_bridge() {
        assert_eq!(sniff_mime(&[0xff, 0xd8, 0xff, 0xe0]), "image/jpeg");
        assert_eq!(sniff_mime(b"GIF89a..."), "image/gif");
        assert_eq!(sniff_mime(b"RIFF\0\0\0\0WEBPVP8 "), "image/webp");
        assert_eq!(sniff_mime(b"\0\0\0\x18ftypheic\0\0\0\0"), "image/heic");
        assert_eq!(sniff_mime(b"\0\0\0\x18ftypmif1\0\0\0\0"), "image/heif");
        assert_eq!(sniff_mime(b"%PDF-1.7"), "application/pdf");
        assert_eq!(sniff_mime(b"PK\x03\x04rest"), "application/zip");
        assert_eq!(sniff_mime("안녕 plain".as_bytes()), "text/plain");
        assert_eq!(sniff_mime(b"\x00\x01\x02"), "application/octet-stream");
        assert_eq!(kind_for("image/png"), "image");
        assert_eq!(kind_for("application/pdf"), "file");
        assert_eq!(display_name(Some("photo\u{202e}gpj.exe")), None);
        assert_eq!(display_name(Some("사진.jpg")).as_deref(), Some("사진.jpg"));
    }

    #[test]
    fn spool_writes_private_files_and_sweep_removes_only_ours() {
        let dir = temp_dir("spool");
        let spooled = spool(&dir, b"%PDF-1.7 doc", Some("r.pdf".into())).unwrap();
        assert_eq!(spooled.path.parent(), Some(dir.as_path()));
        assert!(is_spool_name(spooled.path.file_name().unwrap().to_str().unwrap()));
        assert_eq!((spooled.kind, spooled.mime, spooled.size), ("file", "application/pdf", 12));
        assert_eq!(spooled.sha256, sha256_hex(b"%PDF-1.7 doc"));
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            assert_eq!(std::fs::metadata(&spooled.path).unwrap().permissions().mode() & 0o777, 0o600);
        }
        let other = dir.join("keep.txt");
        std::fs::write(&other, b"x").unwrap();
        assert_eq!(sweep_spool(&dir), 1);
        assert!(!spooled.path.exists() && other.exists());
        std::fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn spool_file_mode_follows_the_directory() {
        use std::os::unix::fs::PermissionsExt;
        let dir = temp_dir("mode");
        std::fs::set_permissions(&dir, std::fs::Permissions::from_mode(0o700)).unwrap();
        let private = spool(&dir, b"x", None).unwrap();
        assert_eq!(std::fs::metadata(&private.path).unwrap().permissions().mode() & 0o777, 0o600);
        // An ordinary umask-022 directory is not a shared spool.
        std::fs::set_permissions(&dir, std::fs::Permissions::from_mode(0o755)).unwrap();
        assert_eq!(spool_file_mode(&dir), 0o600);
        std::fs::set_permissions(&dir, std::fs::Permissions::from_mode(0o2770)).unwrap();
        assert_eq!(spool_file_mode(&dir), 0o640);
        let shared = spool(&dir, b"y", None).unwrap();
        // 0640 unless the process umask strips group read (it never adds bits).
        let mode = std::fs::metadata(&shared.path).unwrap().permissions().mode() & 0o777;
        assert!(mode == 0o640 || mode == 0o600, "{mode:o}");
        std::fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn spool_refuses_a_symlinked_or_relative_directory() {
        let dir = temp_dir("link");
        let real = dir.join("real");
        std::fs::create_dir(&real).unwrap();
        let link = dir.join("link");
        std::os::unix::fs::symlink(&real, &link).unwrap();
        assert_eq!(spool(&link, b"x", None).unwrap_err(), "storage");
        assert_eq!(spool(Path::new("relative/spool"), b"x", None).unwrap_err(), "storage");
        std::fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn prepare_v2_fetches_decrypts_and_frames() {
        let dir = temp_dir("prep");
        let config = AttachmentConfig { spool_dir: dir.clone(), max_bytes: DEFAULT_MAX_BYTES, caption_secs: 0 };
        let descriptor = parse_descriptor(vector_descriptor_json("").as_bytes()).unwrap();
        let fetch: Fetcher = Arc::new(|room, blob| {
            assert_eq!((room, blob), ("agent", VECTOR_BLOB));
            Ok(unhex(VECTOR_CT_HEX))
        });
        let spooled = prepare(&Source::V2(descriptor.clone()), "agent", &config, Some(&fetch)).unwrap();
        assert_eq!(std::fs::read(&spooled.path).unwrap(), unhex(VECTOR_PLAIN_HEX));
        let frame = frame_object(&spooled, "");
        assert_eq!(frame["v"], 1);
        assert_eq!(frame["kind"], "image");
        assert_eq!(frame["mime"], "image/png");
        assert_eq!(frame["name"], "사진.png");
        assert_eq!(frame["size"], 29);
        assert_eq!(frame["caption"], "");
        let text = frame.to_string();
        assert!(!text.contains(VECTOR_KEY) && !text.contains(VECTOR_BLOB), "no key or blob id in the frame: {text}");
        assert!(fallback_prompt(&spooled, "").starts_with("[첨부: 사진 1개(image/png, 29 B)"));
        assert!(fallback_prompt(&spooled, "이거 뭐야?").ends_with("]\n이거 뭐야?"));
        assert_eq!(frame_object(&spooled, "이거 뭐야?")["caption"], "이거 뭐야?");
        assert!(is_caption_text(" 이거 뭐야? ") && !is_caption_text("/new") && !is_caption_text("  "));
        // Failures.
        let failing: Fetcher = Arc::new(|_, _| Err("relay error 404: no_such_blob".into()));
        assert_eq!(prepare(&Source::V2(descriptor.clone()), "agent", &config, Some(&failing)).unwrap_err(), "download");
        assert_eq!(prepare(&Source::V2(descriptor.clone()), "agent", &config, None).unwrap_err(), "download");
        let small = AttachmentConfig { spool_dir: dir.clone(), max_bytes: 28, caption_secs: 0 };
        assert_eq!(prepare(&Source::V2(descriptor), "agent", &small, Some(&fetch)).unwrap_err(), "oversize");
        let v1 = prepare(&Source::V1(Zeroizing::new(b"\xff\xd8\xff\xe0jpeg".to_vec())), "agent", &config, None).unwrap();
        assert_eq!((v1.kind, v1.mime, v1.name.clone()), ("image", "image/jpeg", None));
        assert_eq!(sweep_spool(&dir), 2);
        std::fs::remove_dir_all(&dir).unwrap();
    }
}
