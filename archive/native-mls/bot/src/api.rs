//! Typed client for the native-mls v2 relay (`archive/native-mls/server`).
//! Wire shapes mirror the Go structs' json tags exactly: byte fields cross the
//! wire as standard-alphabet base64 **strings** (Go `[]byte`), refs are
//! caller-chosen opaque strings (the bot pins sha256 hex).

use serde::{Deserialize, Deserializer, Serialize, Serializer};

use crate::b64;
use crate::http::{self, HttpError};

/// serde adapter for the relay's base64-string byte fields.
mod wire_bytes {
    use super::{b64, Deserialize, Deserializer, Serialize, Serializer};

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
}

impl std::fmt::Display for BotError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            BotError::Http(e) => write!(f, "{e}"),
            BotError::Json(e) => write!(f, "json: {e}"),
            BotError::Api { status, code } => write!(f, "relay error {status}: {code}"),
            BotError::Status { status } => write!(f, "relay status {status}"),
            BotError::Local(what) => write!(f, "local error: {what}"),
        }
    }
}

impl From<HttpError> for BotError {
    fn from(e: HttpError) -> Self { BotError::Http(e) }
}

impl From<serde_json::Error> for BotError {
    fn from(e: serde_json::Error) -> Self { BotError::Json(e) }
}

pub type Result<T> = std::result::Result<T, BotError>;

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

#[derive(Deserialize, Debug)]
pub struct EventResponse {
    pub seq: i64,
    pub epoch: i64,
    pub revision: i64,
    pub duplicate: bool,
}

#[derive(Deserialize, Clone, Debug)]
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

#[derive(Deserialize, Clone, Debug)]
pub struct EventsResponse {
    pub epoch: i64,
    pub revision: i64,
    pub events: Vec<StoredRow>,
}

#[derive(Deserialize)]
pub struct ApiErrorBody {
    pub error: String,
}

pub struct Client {
    base: String,
}

impl Client {
    pub fn new(base: &str) -> Client {
        Client { base: base.trim_end_matches('/').to_string() }
    }

    pub fn health(&self) -> Result<bool> {
        let resp = http::request(&self.base, "GET", "/v2/health", None)?;
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
        let resp = http::request(
            &self.base,
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
        let resp = http::request(
            &self.base,
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
        let resp = http::request(
            &self.base,
            "POST",
            &format!("/v2/rooms/{room}/events"),
            Some(serde_json::to_vec(post)?.as_slice()),
        )?;
        let event: EventResponse = serde_json::from_slice(self.checked(resp)?.as_slice())?;
        Ok(event)
    }

    pub fn get_events(&self, room: &str, device: &str, after: i64) -> Result<EventsResponse> {
        let resp = http::request(
            &self.base,
            "GET",
            &format!("/v2/rooms/{room}/events?device={device}&after={after}"),
            None,
        )?;
        let events: EventsResponse = serde_json::from_slice(self.checked(resp)?.as_slice())?;
        Ok(events)
    }

    pub fn close_room(&self, room: &str) -> Result<bool> {
        let resp = http::request(&self.base, "POST", &format!("/v2/rooms/{room}/close"), None)?;
        let body: serde_json::Value = self.decode(resp)?;
        Ok(body["closed"] == serde_json::Value::Bool(true))
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
