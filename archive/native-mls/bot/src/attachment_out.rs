//! #761: files the agent made, out to the 「한데」 room as file-v2 attachments
//! (`docs/FLEET-WORKER.md` "나가는 첨부 — `attachment` 출력 프레임",
//! `archive/native-mls/FILE-V2.md` §2·§3). The mirror of `attachment.rs`:
//! the bridge writes the plaintext to `out-<32 hex>.bin` in the shared spool
//! and names it in an `attachment` frame; the bot checks the file, encrypts it
//! with a fresh key and nonce, uploads the ciphertext as a relay blob and
//! posts the descriptor (the poll loop: it owns the MLS device), then answers
//! `attachment_ack` / `attachment_nack` on the same port.
//!
//! The key, nonce, descriptor and blob id never leave this process (not in a
//! frame, not in the journal, not in `<state>.inbox.json`). The bot removes
//! the spool file in every outcome; the bridge only sweeps what is left.

use crate::attachment::{self, is_control, is_lower_hex, sha256_hex, MAX_FILE_V2};
use native_mls_host::file_v2;
use std::fmt;
use std::io::Read;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use zeroize::Zeroizing;

/// Contract: `attachment` frames one turn may post (`limit` past it).
pub const DEFAULT_ATTACHMENT_OUT_MAX: usize = 4;
/// Frame contract version (`attachment.v`).
pub const FRAME_VERSION: u64 = 1;
/// Contract: the `attachment` JSON stays within 2 KiB.
const MAX_OBJECT_BYTES: usize = 2048;

/// The responder settings for outbound attachments (`None` = off, the default).
#[derive(Clone, Debug)]
pub struct OutConfig {
    /// The same absolute spool as inbound attachments (`NATIVE_MLS_BOT_ATTACHMENT_SPOOL`).
    pub spool_dir: PathBuf,
    /// The same cap as inbound attachments (`NATIVE_MLS_BOT_ATTACHMENT_MAX_BYTES`).
    pub max_bytes: u64,
    /// `DEFAULT_ATTACHMENT_OUT_MAX`.
    pub per_turn: usize,
}

/// `(room, ciphertext) → blob id`. The poll loop installs one bound to its
/// relay client settings (`Client::post_blob`); tests install a fake.
pub type Uploader = Arc<dyn Fn(&str, &[u8]) -> Result<String, String> + Send + Sync>;

/// A shape-checked `attachment` object (the path already obeys the spool rule).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Request {
    pub path: PathBuf,
    pub size: u64,
    pub sha256: String,
    /// Display name for the descriptor (last path piece; dropped when it
    /// carries a bidirectional control).
    pub name: Option<String>,
}

/// The upload is done; what the poll loop needs to post the descriptor.
/// `Debug` never prints the descriptor (it carries the file key).
pub struct Sealed {
    pub descriptor: Zeroizing<Vec<u8>>,
    pub kind: &'static str,
    pub mime: &'static str,
    pub size: u64,
}

impl fmt::Debug for Sealed {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("Sealed").field("kind", &self.kind).field("mime", &self.mime).field("size", &self.size).finish_non_exhaustive()
    }
}

/// `out-<32 lowercase hex>.bin` — the names the bridge writes (inbound files
/// are `<32 hex>.bin`, so the two never collide).
pub fn is_out_name(name: &str) -> bool {
    name.len() == 40 && name.starts_with("out-") && name.ends_with(".bin") && is_lower_hex(&name[4..36], 32)
}

/// The spool file a frame names, if `path` follows the rule (absolute, a
/// direct child of `dir`, an `out-…bin` name). This is the only kind of path
/// the bot ever opens or removes for an outbound frame.
pub fn spool_child(dir: &Path, path: &str) -> Option<PathBuf> {
    let path = Path::new(path);
    if !path.is_absolute() || path.parent()? != dir {
        return None;
    }
    let name = path.file_name()?.to_str()?;
    is_out_name(name).then(|| dir.join(name))
}

/// The plaintext sha256 prefix an answer carries: the frame's own value when
/// it is well-formed (64 lowercase hex), else empty.
pub fn sha12(attachment: Option<&serde_json::Value>) -> String {
    attachment
        .and_then(|a| a.get("sha256"))
        .and_then(|v| v.as_str())
        .filter(|s| is_lower_hex(s, 64))
        .map(|s| s[..12].to_string())
        .unwrap_or_default()
}

/// Contract shape check. `bad_version` for a `v` other than 1, `bad_frame`
/// for anything else that is malformed (including the path rule). Size and
/// file checks come later (`oversize`, `file`).
pub fn parse_request(attachment: &serde_json::Value, spool_dir: &Path) -> Result<Request, &'static str> {
    let object = attachment.as_object().ok_or("bad_frame")?;
    if attachment.to_string().len() > MAX_OBJECT_BYTES {
        return Err("bad_frame");
    }
    match object.get("v") {
        None => return Err("bad_frame"),
        Some(v) if v.as_u64() != Some(FRAME_VERSION) => return Err("bad_version"),
        Some(_) => {}
    }
    let path = object.get("path").and_then(|v| v.as_str()).and_then(|p| spool_child(spool_dir, p)).ok_or("bad_frame")?;
    // `kind` and `mime` are the bridge's hints: shape-checked, then replaced
    // by the bot's own sniffing.
    if !matches!(object.get("kind").and_then(|v| v.as_str()), Some("image" | "file")) {
        return Err("bad_frame");
    }
    if !object.get("mime").and_then(|v| v.as_str()).is_some_and(attachment::is_mime) {
        return Err("bad_frame");
    }
    let size = object.get("size").and_then(|v| v.as_u64()).filter(|s| *s >= 1).ok_or("bad_frame")?;
    let sha256 = object.get("sha256").and_then(|v| v.as_str()).filter(|s| is_lower_hex(s, 64)).ok_or("bad_frame")?;
    let name = match object.get("name") {
        None => None,
        Some(value) => {
            let name = value.as_str().ok_or("bad_frame")?;
            if !(1..=255).contains(&name.chars().count()) || name.chars().any(is_control) {
                return Err("bad_frame");
            }
            // FILE-V2 `name`: only the last path piece is ever a name.
            let last = name.rsplit(['/', '\\']).next().unwrap_or("");
            if last.is_empty() { None } else { attachment::display_name(Some(last)) }
        }
    };
    Ok(Request { path, size, sha256: sha256.to_string(), name })
}

/// Read the spool file the way the contract asks: `O_NOFOLLOW` (a symlink
/// fails to open; `O_NONBLOCK` keeps a FIFO from hanging the thread), a
/// regular file, not writable by *other*, length = `size`, sha256 = `sha256`.
pub fn read_spooled(request: &Request, max_bytes: u64) -> Result<Zeroizing<Vec<u8>>, &'static str> {
    use std::os::unix::fs::{OpenOptionsExt, PermissionsExt};
    if request.size > max_bytes.min(MAX_FILE_V2) {
        return Err("oversize");
    }
    let file = std::fs::OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK)
        .open(&request.path)
        .map_err(|_| "file")?;
    let meta = file.metadata().map_err(|_| "file")?;
    if !meta.is_file() || meta.permissions().mode() & 0o002 != 0 || meta.len() != request.size {
        return Err("file");
    }
    let mut bytes = Zeroizing::new(Vec::with_capacity(request.size as usize + 1));
    file.take(request.size + 1).read_to_end(&mut bytes).map_err(|_| "file")?;
    if bytes.len() as u64 != request.size || sha256_hex(&bytes) != request.sha256 {
        return Err("file");
    }
    Ok(bytes)
}

/// FILE-V2 §2: AES-256-GCM with a fresh random key and nonce, AAD `hande-file-v2` (host-core
/// `file_v2::seal`, #366 3d). Returns the ciphertext and the §1 descriptor for it. Errors keep
/// this module's codes: `bad_frame` (descriptor over 4 KiB, bad name), else `upload`.
pub fn seal(plaintext: &[u8], mime: &str, name: Option<&str>) -> Result<(Vec<u8>, Zeroizing<Vec<u8>>), &'static str> {
    match file_v2::seal(plaintext, mime, name) {
        Ok(sealed) => Ok((sealed.ciphertext, sealed.descriptor)),
        Err("too large" | "name") => Err("bad_frame"),
        Err(_) => Err("upload"),
    }
}

/// The whole off-loop step for one frame: read and check the spool file,
/// remove it (whatever happens next), sniff, seal, upload, check the id.
/// Errors: `file`, `oversize`, `upload`.
pub fn send(request: &Request, room: &str, max_bytes: u64, upload: Option<&Uploader>) -> Result<Sealed, &'static str> {
    let read = read_spooled(request, max_bytes);
    remove_out(&request.path);
    let plaintext = read?;
    let mime = attachment::sniff_mime(&plaintext);
    let kind = attachment::kind_for(mime);
    let (ciphertext, descriptor) = seal(&plaintext, mime, request.name.as_deref())?;
    let upload = upload.ok_or("upload")?;
    let id = upload(room, &ciphertext).map_err(|_| "upload")?;
    if id != sha256_hex(&ciphertext) {
        return Err("upload");
    }
    Ok(Sealed { descriptor, kind, mime, size: plaintext.len() as u64 })
}

/// Remove one outbound spool file (`ENOENT` is fine; never follows a link).
pub fn remove_out(path: &Path) {
    let _ = std::fs::remove_file(path);
}

/// Start-up: remove every `out-*.bin` a previous run left behind.
pub fn sweep_out(dir: &Path) -> usize {
    let Ok(entries) = std::fs::read_dir(dir) else { return 0 };
    let mut removed = 0;
    for entry in entries.flatten() {
        if entry.file_name().to_str().is_some_and(is_out_name) && std::fs::remove_file(entry.path()).is_ok() {
            removed += 1;
        }
    }
    removed
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;
    use std::os::unix::fs::PermissionsExt;

    pub(crate) fn temp_dir(tag: &str) -> PathBuf {
        let mut bytes = [0u8; 8];
        std::fs::File::open("/dev/urandom").unwrap().read_exact(&mut bytes).unwrap();
        let dir = std::env::temp_dir().join(format!("nmls-out-{tag}-{}", bytes.iter().map(|b| format!("{b:02x}")).collect::<String>()));
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    /// The bridge's side: `out-<32 hex>.bin`, 0600, plus the frame object.
    pub(crate) fn bridge_file(dir: &Path, bytes: &[u8]) -> (PathBuf, serde_json::Value) {
        let mut raw = [0u8; 16];
        std::fs::File::open("/dev/urandom").unwrap().read_exact(&mut raw).unwrap();
        let path = dir.join(format!("out-{}.bin", raw.iter().map(|b| format!("{b:02x}")).collect::<String>()));
        std::fs::write(&path, bytes).unwrap();
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o600)).unwrap();
        let object = serde_json::json!({
            "v": 1, "path": path.to_string_lossy(), "kind": "image", "mime": "image/png",
            "name": "captcha.png", "size": bytes.len(), "sha256": sha256_hex(bytes),
        });
        (path, object)
    }

    pub(crate) const PNG: &[u8] = b"\x89PNG\r\n\x1a\n outbound vector";

    #[test]
    fn spool_names_and_paths_follow_the_rule() {
        let dir = Path::new("/var/lib/bot/attachments");
        let hex = "0123456789abcdef".repeat(2);
        assert!(is_out_name(&format!("out-{hex}.bin")));
        for bad in [format!("{hex}.bin"), format!("out-{}.bin", hex.to_uppercase()), format!("out-{hex}.png"), format!("out-{}.bin", &hex[1..]), "out-.bin".into()] {
            assert!(!is_out_name(&bad), "{bad}");
        }
        let good = format!("/var/lib/bot/attachments/out-{hex}.bin");
        assert_eq!(spool_child(dir, &good), Some(dir.join(format!("out-{hex}.bin"))));
        for bad in [
            format!("var/lib/bot/attachments/out-{hex}.bin"),
            format!("/var/lib/bot/attachments/sub/out-{hex}.bin"),
            format!("/var/lib/bot/attachments/../attachments/out-{hex}.bin"),
            format!("/tmp/out-{hex}.bin"),
            format!("/var/lib/bot/attachments/{hex}.bin"),
            "/var/lib/bot/attachments".to_string(),
        ] {
            assert_eq!(spool_child(dir, &bad), None, "{bad}");
        }
    }

    #[test]
    fn frame_shape_maps_to_the_contract_reasons() {
        let dir = temp_dir("shape");
        let (path, good) = bridge_file(&dir, PNG);
        let request = parse_request(&good, &dir).unwrap();
        assert_eq!((request.path.clone(), request.size, request.name.as_deref()), (path, PNG.len() as u64, Some("captcha.png")));
        assert_eq!(sha12(Some(&good)), sha256_hex(PNG)[..12]);
        let with = |key: &str, value: serde_json::Value| {
            let mut object = good.clone();
            object[key] = value;
            object
        };
        let without = |key: &str| {
            let mut object = good.clone();
            object.as_object_mut().unwrap().remove(key);
            object
        };
        assert_eq!(parse_request(&with("v", 2.into()), &dir), Err("bad_version"));
        assert_eq!(parse_request(&with("v", "1".into()), &dir), Err("bad_version"));
        for (what, object) in [
            ("no v", without("v")),
            ("not an object", serde_json::json!([1])),
            ("relative path", with("path", "out-x.bin".into())),
            ("outside the spool", with("path", "/etc/passwd".into())),
            ("kind", with("kind", "video".into())),
            ("mime", with("mime", "png".into())),
            ("no mime", without("mime")),
            ("size 0", with("size", 0.into())),
            ("size text", with("size", "29".into())),
            ("sha upper", with("sha256", sha256_hex(PNG).to_uppercase().into())),
            ("no sha", without("sha256")),
            ("name empty", with("name", "".into())),
            ("name control", with("name", "a\u{7}b".into())),
            ("name long", with("name", "가".repeat(256).into())),
            ("name not text", with("name", 5.into())),
            ("too large", with("pad", "x".repeat(MAX_OBJECT_BYTES).into())),
        ] {
            assert_eq!(parse_request(&object, &dir), Err("bad_frame"), "{what}");
        }
        assert_eq!(sha12(Some(&with("sha256", "zz".into()))), "");
        assert_eq!(sha12(None), "");
        // Names: last path piece only; a bidi control drops the key.
        assert_eq!(parse_request(&with("name", "../../etc/사진.png".into()), &dir).unwrap().name.as_deref(), Some("사진.png"));
        assert_eq!(parse_request(&with("name", "C:\\x\\r.pdf".into()), &dir).unwrap().name.as_deref(), Some("r.pdf"));
        assert_eq!(parse_request(&with("name", "dir/".into()), &dir).unwrap().name, None);
        assert_eq!(parse_request(&with("name", "photo\u{202e}gpj.exe".into()), &dir).unwrap().name, None);
        assert_eq!(parse_request(&without("name"), &dir).unwrap().name, None);
        // Unknown keys are ignored.
        assert!(parse_request(&with("future", true.into()), &dir).is_ok());
        std::fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn sealed_descriptor_opens_with_the_inbound_parser() {
        let (ciphertext, descriptor) = seal(PNG, "image/png", Some("사진 \"1\".png")).unwrap();
        assert_eq!(ciphertext.len(), PNG.len() + 16);
        let parsed = attachment::parse_descriptor(&descriptor).unwrap();
        assert_eq!(parsed.blob, sha256_hex(&ciphertext));
        assert_eq!(parsed.name.as_deref(), Some("사진 \"1\".png"));
        assert_eq!(attachment::open_v2(&ciphertext, &parsed).unwrap().as_slice(), PNG);
        let shown: serde_json::Value = serde_json::from_slice(&descriptor).unwrap();
        assert_eq!((shown["v"].as_u64(), shown["mime"].as_str(), shown["size"].as_u64()), (Some(2), Some("image/png"), Some(PNG.len() as u64)));
        // A fresh key and nonce every time.
        let (again, descriptor2) = seal(PNG, "image/png", None).unwrap();
        assert_ne!(again, ciphertext);
        let other: serde_json::Value = serde_json::from_slice(&descriptor2).unwrap();
        assert_ne!(other["key"], shown["key"]);
        assert_ne!(other["nonce"], shown["nonce"]);
        assert!(other.get("name").is_none());
        let shown = format!("{:?}", Sealed { descriptor, kind: "image", mime: "image/png", size: 1 });
        assert!(!shown.contains("key") && !shown.contains("blob"), "{shown}");
    }

    #[test]
    fn send_checks_the_file_removes_it_and_uploads_once() {
        use std::sync::Mutex;
        let dir = temp_dir("send");
        type Seen = Arc<Mutex<Vec<(String, Vec<u8>)>>>;
        let uploads: Seen = Arc::default();
        let seen = uploads.clone();
        let uploader: Uploader = Arc::new(move |room, ct| {
            seen.lock().unwrap().push((room.to_string(), ct.to_vec()));
            Ok(sha256_hex(ct))
        });
        let (path, object) = bridge_file(&dir, PNG);
        let request = parse_request(&object, &dir).unwrap();
        let sealed = send(&request, "agent", 1_000, Some(&uploader)).unwrap();
        assert!(!path.exists(), "removed after reading");
        assert_eq!((sealed.kind, sealed.mime, sealed.size), ("image", "image/png", PNG.len() as u64));
        let (room, ct) = uploads.lock().unwrap()[0].clone();
        assert_eq!(room, "agent");
        let parsed = attachment::parse_descriptor(&sealed.descriptor).unwrap();
        assert_eq!(attachment::open_v2(&ct, &parsed).unwrap().as_slice(), PNG);

        // The bot's sniffing wins over the bridge's hint.
        let (_, mut object) = bridge_file(&dir, b"%PDF-1.7 report");
        object["kind"] = "image".into();
        object["mime"] = "image/png".into();
        let sealed = send(&parse_request(&object, &dir).unwrap(), "agent", 1_000, Some(&uploader)).unwrap();
        assert_eq!((sealed.kind, sealed.mime), ("file", "application/pdf"));

        // File failures; each file is gone afterwards.
        let fails = |bytes: &[u8], tweak: &dyn Fn(&Path, &mut serde_json::Value)| {
            let (path, mut object) = bridge_file(&dir, bytes);
            tweak(&path, &mut object);
            let got = send(&parse_request(&object, &dir).unwrap(), "agent", 1_000, Some(&uploader)).map(|_| ());
            assert!(std::fs::symlink_metadata(&path).is_err(), "{path:?} left behind");
            got
        };
        assert_eq!(fails(PNG, &|_, o| o["sha256"] = sha256_hex(b"other").into()), Err("file"));
        assert_eq!(fails(PNG, &|_, o| o["size"] = (PNG.len() + 1).into()), Err("file"));
        assert_eq!(fails(PNG, &|p, _| std::fs::set_permissions(p, std::fs::Permissions::from_mode(0o666)).unwrap()), Err("file"));
        assert_eq!(fails(PNG, &|p, _| std::fs::remove_file(p).unwrap()), Err("file"));
        let target = dir.join("target.png");
        std::fs::write(&target, PNG).unwrap();
        assert_eq!(fails(PNG, &|p, _| { std::fs::remove_file(p).unwrap(); std::os::unix::fs::symlink(&target, p).unwrap(); }), Err("file"));
        assert!(target.exists(), "the link's target is never touched");
        // Not a regular file (a directory under the name): refused, never removed recursively.
        let (path, object) = bridge_file(&dir, PNG);
        std::fs::remove_file(&path).unwrap();
        std::fs::create_dir(&path).unwrap();
        assert_eq!(send(&parse_request(&object, &dir).unwrap(), "agent", 1_000, Some(&uploader)).map(|_| ()), Err("file"));
        std::fs::remove_dir(&path).unwrap();
        // 0640 (the Linux group layout) is fine.
        assert!(fails(PNG, &|p, _| std::fs::set_permissions(p, std::fs::Permissions::from_mode(0o640)).unwrap()).is_ok());
        // Over the cap: refused before reading, file still removed.
        let (path, object) = bridge_file(&dir, PNG);
        assert_eq!(send(&parse_request(&object, &dir).unwrap(), "agent", 10, Some(&uploader)).map(|_| ()), Err("oversize"));
        assert!(!path.exists());
        // Upload failures: relay error, a wrong id, no uploader.
        let refusing: Uploader = Arc::new(|_, _| Err("relay error 403: not_a_member".into()));
        let lying: Uploader = Arc::new(|_, _| Ok("00".repeat(32)));
        for uploader in [Some(&refusing), Some(&lying), None] {
            let (path, object) = bridge_file(&dir, PNG);
            assert_eq!(send(&parse_request(&object, &dir).unwrap(), "agent", 1_000, uploader).map(|_| ()), Err("upload"));
            assert!(!path.exists());
        }
        std::fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn sweep_removes_only_outbound_files() {
        let dir = temp_dir("sweep");
        let (path, _) = bridge_file(&dir, b"x");
        let inbound = dir.join(format!("{}.bin", "ab".repeat(16)));
        let other = dir.join("keep.txt");
        std::fs::write(&inbound, b"x").unwrap();
        std::fs::write(&other, b"x").unwrap();
        assert_eq!(sweep_out(&dir), 1);
        assert!(!path.exists() && inbound.exists() && other.exists());
        std::fs::remove_dir_all(&dir).unwrap();
    }
}
