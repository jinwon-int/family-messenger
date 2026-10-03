//! Typed client for the native-mls v2 relay (`archive/native-mls/server`).
//! Wire shapes mirror the Go structs' json tags exactly: byte fields cross the
//! wire as standard-alphabet base64 **strings** (Go `[]byte`), refs are
//! caller-chosen opaque strings (the bot pins sha256 hex).

use serde::{Deserialize, Deserializer, Serialize, Serializer};

use crate::b64;
use crate::http::{self, HttpError};

/// serde adapter for the relay's base64-string byte fields.
mod wire_bytes {
    use super::{b64, Deserialize, Deserializer, Serializer};

    pub fn serialize<S: Serializer>(value: &Vec<u8>, serializer: S) -> Result<S::Ok, S::Error> {
        serializer.serialize_str(&b64::encode(value))
    }

    pub fn deserialize<'de, D: Deserializer<'de>>(deserializer: D) -> Result<Vec<u8>, D::Error> {
        let text = String::deserialize(deserializer)?;
        b64::decode(&text).map_err(serde::de::Error::custom)
    }
}

#[derive(Debug)]
pub enum BotError {
    Http(HttpError),
    Json(serde_json::Error),
    /// Relay answered with its structured error envelope.
    Api { status: u16, code: String },
    /// Relay answered with a non-2xx but not the error envelope.
    Status { status: u16 },
    /// Local contract violation (facade rejected a local MLS op, or an OK
    /// response failed its body contract). The facade's `Rejected` carries a
    /// static reason with no `Display`, so call sites label the step.
    Local(&'static str),
    /// The caller-auth token source has nothing usable right now (file
    /// missing, unreadable or blank mid-rotation). Treated like a 401 by the
    /// session loop: wait for the refresher, do not die (review 2 B-M3).
    AccessUnavailable(&'static str),
}

impl std::fmt::Display for BotError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            BotError::Http(e) => write!(f, "{e}"),
            BotError::Json(e) => write!(f, "json: {e}"),
            BotError::Api { status, code } => write!(f, "relay error {status}: {code}"),
            BotError::Status { status } => write!(f, "relay status {status}"),
            BotError::Local(what) => write!(f, "local error: {what}"),
            BotError::AccessUnavailable(what) => write!(f, "access token unavailable: {what}"),
        }
    }
}

impl From<HttpError> for BotError {
    fn from(e: HttpError) -> Self { BotError::Http(e) }
}

/// The relay's identifier rule (`server.go` validIdentifier / roomParam):
/// `[A-Za-z0-9_-]{1,64}`. Room, device, consumer and watch-room names are
/// checked against it once at the CLI boundary, so nothing that would need
/// percent-encoding — or that could split a request line — is ever
/// interpolated into a path (review 2 L: URL not encoded).
pub fn is_identifier(s: &str) -> bool {
    !s.is_empty()
        && s.len() <= 64
        && s.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'_' || b == b'-')
}

/// `is_identifier` as a `BotError::Local` for CLI arguments.
pub fn require_identifier(what: &'static str, s: &str) -> Result<()> {
    if is_identifier(s) { Ok(()) } else { Err(BotError::Local(what)) }
}

impl From<serde_json::Error> for BotError {
    fn from(e: serde_json::Error) -> Self { BotError::Json(e) }
}

pub type Result<T> = std::result::Result<T, BotError>;

/// The relay's structured error code, when the error carries one.
pub fn error_code(err: &BotError) -> Option<&str> {
    match err {
        BotError::Api { code, .. } => Some(code.as_str()),
        _ => None,
    }
}

// ---- wire types (server.go json tags) ----

#[derive(Serialize)]
pub struct KeyPackageRef<'a> {
    pub r#ref: &'a str,
    #[serde(with = "wire_bytes")]
    pub bytes: Vec<u8>,
}

#[derive(Serialize)]
pub struct KeyPackagePost<'a> {
    pub device: &'a str,
    pub packages: Vec<KeyPackageRef<'a>>,
}

#[derive(Deserialize)]
pub struct StoredKeyPackage {
    #[serde(rename = "ref")]
    pub key_ref: String,
    #[serde(with = "wire_bytes")]
    pub bytes: Vec<u8>,
    pub expires_at: i64,
}

#[derive(Serialize)]
pub struct MemberWire<'a> {
    pub device: &'a str,
    pub actor: &'a str,
}

#[derive(Serialize)]
pub struct EventPost<'a> {
    pub device: &'a str,
    pub client_id: &'a str,
    pub kind: &'a str, // commit | welcome | application
    pub epoch: i64,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub revision: Option<i64>,
    pub group_id: &'a str,
    #[serde(skip_serializing_if = "Vec::is_empty")]
    pub targets: Vec<String>,
    #[serde(skip_serializing_if = "Vec::is_empty")]
    pub members: Vec<MemberWire<'a>>,
    #[serde(with = "wire_bytes")]
    pub bytes: Vec<u8>,
}

/// Wire mirror of the relay's event response; `revision` is carried for
/// parity with the Go struct even though the bot only acts on seq/epoch.
#[derive(Deserialize, Debug)]
#[allow(dead_code)]
pub struct EventResponse {
    pub seq: i64,
    pub epoch: i64,
    pub revision: i64,
    pub duplicate: bool,
}

/// Wire mirror of one stored event; `sha256`/`created_at` are decoded for
/// parity and surfaced in logs only.
#[derive(Deserialize, Clone, Debug)]
#[allow(dead_code)]
pub struct StoredRow {
    pub seq: i64,
    pub device: String,
    pub client_id: String,
    pub kind: String,
    pub epoch: i64,
    #[serde(with = "wire_bytes")]
    pub bytes: Vec<u8>,
    pub sha256: String,
    pub created_at: i64,
}

/// One tracked member as the relay reports it (#261 GET events `members`).
#[derive(Deserialize, Clone, Debug)]
#[allow(dead_code)]
pub struct MemberOwned {
    pub device: String,
    pub actor: String,
}

/// Wire mirror of one events page; `revision` rides along for parity.
/// `members` is the relay's tracked (outer) roster as of the same
/// transaction (#261); absent on relays older than that — then the bot
/// only runs its inner checks (`policy::check_commit` with `outer = None`).
#[derive(Deserialize, Clone, Debug)]
#[allow(dead_code)]
pub struct EventsResponse {
    pub epoch: i64,
    pub revision: i64,
    pub events: Vec<StoredRow>,
    #[serde(default)]
    pub members: Option<Vec<MemberOwned>>,
}

#[derive(Deserialize)]
pub struct ApiErrorBody {
    pub error: String,
}

pub struct Client {
    base: String,
    access: Access,
}

/// Caller authentication source (relay `-access-mode required`, review C1).
/// The JWT must carry `sub` equal to the device-policy subject of the device
/// each request acts as; the relay verifies iss/aud/exp/nbf against the
/// operator's JWKS. CF Access assertions are short-lived, so the file source
/// is re-read before every request — an external refresher (service token
/// cron, operator script) rotates the token without restarting the bot.
#[derive(Clone, Debug, Default)]
pub enum Access {
    #[default]
    None,
    /// One fixed JWT (env `NATIVE_MLS_BOT_ACCESS_JWT`) — dev/test only.
    Static(String),
    /// Path to a file holding the current JWT (`--access-jwt-file`,
    /// env `NATIVE_MLS_BOT_ACCESS_JWT_FILE`).
    File(std::path::PathBuf),
}

impl Access {
    /// Resolve the header value; `None` when authentication is off.
    fn token(&self) -> Result<Option<String>> {
        match self {
            Access::None => Ok(None),
            Access::Static(raw) => {
                let token = raw.trim();
                if token.is_empty() {
                    Err(BotError::Local("access token (env) is empty"))
                } else {
                    Ok(Some(token.to_string()))
                }
            }
            Access::File(path) => {
                let raw = std::fs::read_to_string(path)
                    .map_err(|_| BotError::AccessUnavailable("access token file unreadable"))?;
                let token = raw.trim();
                if token.is_empty() {
                    Err(BotError::AccessUnavailable("access token file is empty"))
                } else {
                    Ok(Some(token.to_string()))
                }
            }
        }
    }
}

impl Client {
    pub fn with_access(base: &str, access: Access) -> Client {
        Client { base: base.trim_end_matches('/').to_string(), access }
    }

    /// Every contract route carries the CF Access assertion when caller auth
    /// is configured; the relay accepts it on the production header name.
    fn send(&self, method: &str, path_qs: &str, body: Option<&[u8]>) -> Result<http::Response> {
        let mut headers: Vec<(&str, String)> = Vec::new();
        if let Some(token) = self.access.token()? {
            headers.push(("Cf-Access-Jwt-Assertion", token));
        }
        let refs: Vec<(&str, &str)> = headers.iter().map(|(name, value)| (*name, value.as_str())).collect();
        Ok(http::request(&self.base, method, path_qs, body, &refs)?)
    }

    pub fn health(&self) -> Result<bool> {
        let resp = self.send("GET", "/v2/health", None)?;
        let body: serde_json::Value = serde_json::from_slice(&resp.body)?;
        Ok(resp.status == 200 && body["ok"] == serde_json::Value::Bool(true))
    }

    pub fn post_key_packages(&self, room: &str, device: &str, refs: &[(&str, Vec<u8>)]) -> Result<u64> {
        let post = KeyPackagePost {
            device,
            packages: refs
                .iter()
                .map(|(r, bytes)| KeyPackageRef { r#ref: r, bytes: bytes.clone() })
                .collect(),
        };
        let resp = self.send(
            "POST",
            &format!("/v2/rooms/{room}/keypackages"),
            Some(serde_json::to_vec(&post)?.as_slice()),
        )?;
        let stored: serde_json::Value = self.decode(resp)?;
        Ok(stored["stored"].as_u64().unwrap_or(0))
    }

    /// Consume one live key package of `device` (the server hands each package
    /// out once per consumer — that is what keeps invites single-use).
    pub fn consume_key_package(&self, room: &str, device: &str, consumer: &str) -> Result<Option<StoredKeyPackage>> {
        let resp = self.send(
            "GET",
            &format!("/v2/rooms/{room}/keypackages?device={device}&consumer={consumer}"),
            None,
        )?;
        if resp.status == 404 {
            let body: serde_json::Value = serde_json::from_slice(&resp.body)?;
            if body["error"] == serde_json::Value::String("no_live_key_package".into())
                || body["error"] == serde_json::Value::String("no_such_room".into())
            {
                return Ok(None);
            }
            return Err(BotError::Api { status: 404, code: body["error"].as_str().unwrap_or("?").into() });
        }
        let pkg: StoredKeyPackage = serde_json::from_slice(self.checked(resp)?.as_slice())?;
        Ok(Some(pkg))
    }

    pub fn post_event(&self, room: &str, post: &EventPost) -> Result<EventResponse> {
        let resp = self.send(
            "POST",
            &format!("/v2/rooms/{room}/events"),
            Some(serde_json::to_vec(post)?.as_slice()),
        )?;
        let event: EventResponse = serde_json::from_slice(self.checked(resp)?.as_slice())?;
        Ok(event)
    }

    /// One page after `after`; `ack` (review 2 B-H4) tells the relay the
    /// device has durably processed everything up to that seq — the only
    /// thing that moves its pruning cursor (DEVICES-V4.md "커서 = ack").
    pub fn get_events(&self, room: &str, device: &str, after: i64, ack: Option<i64>) -> Result<EventsResponse> {
        let mut path = format!("/v2/rooms/{room}/events?device={device}&after={after}");
        if let Some(ack) = ack {
            path.push_str(&format!("&ack={ack}"));
        }
        let resp = self.send("GET", &path, None)?;
        let events: EventsResponse = serde_json::from_slice(self.checked(resp)?.as_slice())?;
        Ok(events)
    }

    fn checked(&self, resp: http::Response) -> Result<Vec<u8>> {
        if resp.status < 200 || resp.status >= 300 {
            return Err(self.envelope(resp.status, resp.body));
        }
        Ok(resp.body)
    }

    fn decode(&self, resp: http::Response) -> Result<serde_json::Value> {
        let body = self.checked(resp)?;
        Ok(serde_json::from_slice(&body)?)
    }

    fn envelope(&self, status: u16, body: Vec<u8>) -> BotError {
        match serde_json::from_slice::<ApiErrorBody>(&body) {
            Ok(parsed) => BotError::Api { status, code: parsed.error },
            Err(_) => BotError::Status { status },
        }
    }
}

/// sha256-hex ref for a key package (caller-chosen opaque per the relay).
pub fn ref_hex(bytes: &[u8]) -> String {
    use sha2::{Digest, Sha256};
    let digest = Sha256::digest(bytes);
    let mut out = String::with_capacity(64);
    for b in digest { out.push_str(&format!("{b:02x}")); }
    out
}

#[cfg(test)]
mod identifier_tests {
    use super::is_identifier;

    #[test]
    fn identifier_rule_matches_the_relay() {
        for ok in ["family-private", "bot-1", "a", "A_Z-09", &"x".repeat(64)] {
            assert!(is_identifier(ok), "{ok:?}");
        }
        for bad in ["", "a b", "a/b", "a?x", "a&b=1", "a\r\n", "한글", ".", &"x".repeat(65)] {
            assert!(!is_identifier(bad), "{bad:?}");
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::{Read, Write};

    /// The file source resolves the current content on every call, so an
    /// external refresher can rotate short-lived tokens; missing and empty
    /// files fail closed.
    #[test]
    fn token_file_rotates_and_fails_closed() {
        let dir = std::env::temp_dir().join(format!("native-mls-bot-access-{}", std::process::id()));
        std::fs::create_dir_all(&dir).expect("tmp dir");
        let path = dir.join("token");
        let access = Access::File(path.clone());

        assert!(matches!(access.token(), Err(BotError::AccessUnavailable("access token file unreadable"))));

        std::fs::write(&path, "tok-1\n").expect("write");
        assert_eq!(access.token().expect("token").as_deref(), Some("tok-1"));

        // Rotation: the next call must see the new content.
        std::fs::write(&path, "tok-2").expect("rewrite");
        assert_eq!(access.token().expect("token").as_deref(), Some("tok-2"));

        // Whitespace-only fails closed.
        std::fs::write(&path, "  \n").expect("blank");
        assert!(matches!(access.token(), Err(BotError::AccessUnavailable("access token file is empty"))));

        std::fs::remove_dir_all(&dir).ok();
    }

    /// With auth configured, every request carries the production header
    /// name; with auth off, none does.
    #[test]
    fn send_carries_assertion_only_when_configured() {
        let listener = std::net::TcpListener::bind(("127.0.0.1", 0)).expect("bind");
        let addr = listener.local_addr().expect("addr");
        let server = std::thread::spawn(move || {
            for authed in [true, false] {
                let (mut stream, _) = listener.accept().expect("accept");
                let mut raw = Vec::new();
                let mut buf = [0u8; 1024];
                while !raw.windows(4).any(|w| w == b"\r\n\r\n") {
                    let n = stream.read(&mut buf).expect("read request");
                    assert!(n > 0, "eof before header terminator");
                    raw.extend_from_slice(&buf[..n]);
                }
                let text = String::from_utf8(raw).expect("utf8");
                assert_eq!(text.contains("Cf-Access-Jwt-Assertion:"), authed, "{text}");
                stream
                    .write_all(b"HTTP/1.1 200 OK\r\nContent-Length: 11\r\n\r\n{\"ok\":true}")
                    .expect("write response");
            }
        });
        let base = format!("http://127.0.0.1:{}", addr.port());
        let authed = Client::with_access(&base, Access::Static("jwt-1".into()));
        assert!(authed.health().expect("authed health"));
        let plain = Client::with_access(&base, Access::None);
        assert!(plain.health().expect("plain health"));
        server.join().expect("server thread");
    }
}
