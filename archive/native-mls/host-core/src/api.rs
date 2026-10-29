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
pub enum RelayError {
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
    /// `Local` with an owned message, for the few operator-facing errors that
    /// must name the device/room (#380 P5 invite: no key package anywhere).
    Detail(String),
    /// The caller-auth token source has nothing usable right now (file
    /// missing, unreadable or blank mid-rotation). Treated like a 401 by the
    /// session loop: wait for the refresher, do not die (review 2 B-M3).
    AccessUnavailable(&'static str),
}

impl std::fmt::Display for RelayError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            RelayError::Http(e) => write!(f, "{e}"),
            RelayError::Json(e) => write!(f, "json: {e}"),
            RelayError::Api { status, code } => write!(f, "relay error {status}: {code}"),
            RelayError::Status { status } => write!(f, "relay status {status}"),
            RelayError::Local(what) => write!(f, "local error: {what}"),
            RelayError::Detail(what) => write!(f, "local error: {what}"),
            RelayError::AccessUnavailable(what) => write!(f, "access token unavailable: {what}"),
        }
    }
}

impl From<HttpError> for RelayError {
    fn from(e: HttpError) -> Self { RelayError::Http(e) }
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

/// `is_identifier` as a `RelayError::Local` for CLI arguments.
pub fn require_identifier(what: &'static str, s: &str) -> Result<()> {
    if is_identifier(s) { Ok(()) } else { Err(RelayError::Local(what)) }
}

impl From<serde_json::Error> for RelayError {
    fn from(e: serde_json::Error) -> Self { RelayError::Json(e) }
}

pub type Result<T> = std::result::Result<T, RelayError>;

/// The relay's structured error code, when the error carries one.
pub fn error_code(err: &RelayError) -> Option<&str> {
    match err {
        RelayError::Api { code, .. } => Some(code.as_str()),
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
    /// Lowest seq the room still holds (#242; 0 = empty room, or a relay that
    /// predates the field). A joined reader whose `after` lies below
    /// `first_seq - 1` lost history to pruning (#268).
    #[serde(default)]
    pub first_seq: i64,
    /// The caller's **actor-wide** read position (#571 B, `server/read.go`):
    /// the highest seq any device of the same person has posted through
    /// [`Client::post_read`]. 0 = nothing read yet, or a relay that predates
    /// the field. Unread indicators compare the last foreign message's seq
    /// against `max(local, read_seq)`; the bot ignores it.
    #[serde(default)]
    pub read_seq: i64,
}

#[derive(Deserialize)]
pub struct ApiErrorBody {
    pub error: String,
}

/// `POST /v2/rooms/<room>/read` body (read.go `readPost`). The relay parses it
/// strictly — exactly these two fields, nothing else.
#[derive(Serialize)]
struct ReadPost<'a> {
    device: &'a str,
    seq: i64,
}

/// `POST /v2/rooms/<room>/read` answer (read.go `readResponse`): the actor's
/// read position after the request — the posted seq, or the higher value
/// another device of the same actor had already set.
#[derive(Deserialize)]
struct ReadResponse {
    read_seq: i64,
}

// ---- #366 3c: device-level routes (lobby · rooms · push) — server.go/lobby.go/rooms.go/push.go json tags ----

/// `POST /v2/rooms/<room>/keypackages` · `POST /v2/lobby/keypackages` response
/// (server.go `keyPackagesResponse`): `stored` newly inserted, `duplicates`
/// byte-identical replays accepted idempotently, `live` unconsumed after the
/// insert.
#[derive(Deserialize, Clone, Debug, PartialEq, Eq)]
pub struct KeyPackagesStored {
    pub stored: u64,
    #[serde(default)]
    pub duplicates: u64,
    #[serde(default)]
    pub live: u64,
}

/// `GET /v2/lobby/status?device=` (lobby.go `lobbyStatusResponse`, #380 P5):
/// the device's live lobby count against the relay policy bounds.
#[derive(Deserialize, Clone, Debug, PartialEq, Eq)]
pub struct LobbyStatus {
    pub device: String,
    pub live: u64,
    pub max: u64,
    pub ttl_seconds: i64,
}

/// One room holding a Welcome the device has not read past
/// (`GET /v2/lobby/welcomes?device=`, lobby.go `pendingWelcome`).
#[derive(Deserialize, Clone, Debug, PartialEq, Eq)]
pub struct PendingWelcome {
    pub room: String,
    pub seq: i64,
    pub epoch: i64,
    pub created_at: i64,
}

#[derive(Deserialize)]
struct WelcomesResponse {
    welcomes: Vec<PendingWelcome>,
}

#[derive(Deserialize)]
struct LobbyDeleteResponse {
    deleted: u64,
}

/// One room the device takes part in (`GET /v2/rooms?device=`, rooms.go
/// `roomListing`): public fields only — no events, rosters or key material.
#[derive(Deserialize, Clone, Debug, PartialEq, Eq)]
pub struct RoomListing {
    pub room: String,
    pub epoch: i64,
    pub revision: i64,
    pub member: bool,
    pub keypackages_outstanding: u64,
    pub closed: bool,
}

#[derive(Deserialize)]
struct RoomsResponse {
    rooms: Vec<RoomListing>,
}

/// `POST /v2/push/devices` body (push.go `pushRegistration`). The token field
/// is spelled `apns_token` on today's wire whatever the platform; the FCM
/// generalisation is a relay change (#338 G3), not a client one.
#[derive(Serialize)]
struct PushRegistration<'a> {
    device: &'a str,
    #[serde(with = "wire_bytes")]
    apns_token: Vec<u8>,
    topic: &'a str,
}

/// How requests reach the relay (#366 3a). The bot uses [`TcpTransport`]
/// (plain HTTP/1.1 over the tailnet); a mobile host plugs in its platform
/// client (TLS stays there — no TLS dependency in this crate). Paths, query
/// strings, JSON bodies and the error envelope are built and read here,
/// whatever the transport.
pub trait Transport: Send + Sync {
    /// `extra_headers` are already resolved (the CF Access assertion when
    /// configured). Return `Err` only when no HTTP response was obtained —
    /// a response with an error status is a normal `Response`.
    fn send(
        &self, base: &str, method: &str, path_qs: &str, body: Option<&[u8]>, extra_headers: &[(&str, &str)],
    ) -> Result<http::Response>;
}

/// The crate's own HTTP/1.1 client ([`http::request`]).
pub struct TcpTransport;

impl Transport for TcpTransport {
    fn send(
        &self, base: &str, method: &str, path_qs: &str, body: Option<&[u8]>, extra_headers: &[(&str, &str)],
    ) -> Result<http::Response> {
        Ok(http::request(base, method, path_qs, body, extra_headers)?)
    }
}

pub struct Client {
    base: String,
    access: Access,
    transport: Box<dyn Transport>,
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
                    Err(RelayError::Local("access token (env) is empty"))
                } else {
                    Ok(Some(token.to_string()))
                }
            }
            Access::File(path) => {
                let raw = std::fs::read_to_string(path)
                    .map_err(|_| RelayError::AccessUnavailable("access token file unreadable"))?;
                let token = raw.trim();
                if token.is_empty() {
                    Err(RelayError::AccessUnavailable("access token file is empty"))
                } else {
                    Ok(Some(token.to_string()))
                }
            }
        }
    }
}

impl Client {
    pub fn with_access(base: &str, access: Access) -> Client {
        Client::with_transport(base, access, Box::new(TcpTransport))
    }

    /// Same client over a host-provided transport (#366 3a: Android OkHttp).
    pub fn with_transport(base: &str, access: Access, transport: Box<dyn Transport>) -> Client {
        Client { base: base.trim_end_matches('/').to_string(), access, transport }
    }

    /// Replace the caller-auth source (a mobile host rotates its CF Access
    /// token without rebuilding the client).
    pub fn set_access(&mut self, access: Access) {
        self.access = access;
    }

    /// Every contract route carries the CF Access assertion when caller auth
    /// is configured; the relay accepts it on the production header name.
    fn send(&self, method: &str, path_qs: &str, body: Option<&[u8]>) -> Result<http::Response> {
        let mut headers: Vec<(&str, String)> = Vec::new();
        if let Some(token) = self.access.token()? {
            headers.push(("Cf-Access-Jwt-Assertion", token));
        }
        let refs: Vec<(&str, &str)> = headers.iter().map(|(name, value)| (*name, value.as_str())).collect();
        self.transport.send(&self.base, method, path_qs, body, &refs)
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
        let resp = self.send("GET", &room_consume_path(room, device, consumer), None)?;
        self.consumed(resp)
    }

    /// Consume one live **lobby** key package of `device` — the relay's
    /// room-independent pool human apps top up (#380 P5). `room` names the
    /// room the package is consumed for (the relay checks the consumer is a
    /// tracked member, or that the room does not exist yet). `None` when the
    /// device has nothing live in the lobby.
    pub fn consume_lobby_key_package(&self, room: &str, device: &str, consumer: &str) -> Result<Option<StoredKeyPackage>> {
        let resp = self.send("GET", &lobby_consume_path(room, device, consumer), None)?;
        self.consumed(resp)
    }

    /// Shared tail of both consumes: 404 `no_live_key_package` / `no_such_room`
    /// is "nothing to hand out" (`None`); any other status is the envelope.
    fn consumed(&self, resp: http::Response) -> Result<Option<StoredKeyPackage>> {
        if resp.status == 404 {
            let body: serde_json::Value = serde_json::from_slice(&resp.body)?;
            if body["error"] == serde_json::Value::String("no_live_key_package".into())
                || body["error"] == serde_json::Value::String("no_such_room".into())
            {
                return Ok(None);
            }
            return Err(RelayError::Api { status: 404, code: body["error"].as_str().unwrap_or("?").into() });
        }
        let pkg: StoredKeyPackage = serde_json::from_slice(self.checked(resp)?.as_slice())?;
        Ok(Some(pkg))
    }

    /// `POST /v2/rooms/<room>/close?device=` (§3.4 B1): tombstone the room —
    /// every member then reads 410 `room_closed`. `Ok(true)` = closed (also
    /// when it already was: the relay answers idempotently), `Ok(false)` =
    /// the relay has no such room (a room founded locally whose first invite
    /// never went out). Anything else — 403 `not_a_member` included — is the
    /// envelope.
    pub fn close_room(&self, room: &str, device: &str) -> Result<bool> {
        let resp = self.send("POST", &format!("/v2/rooms/{room}/close?device={device}"), None)?;
        if resp.status == 404 {
            let body: serde_json::Value = serde_json::from_slice(&resp.body)?;
            if body["error"] == serde_json::Value::String("no_such_room".into()) {
                return Ok(false);
            }
            return Err(RelayError::Api { status: 404, code: body["error"].as_str().unwrap_or("?").into() });
        }
        self.checked(resp)?;
        Ok(true)
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

    /// `POST /v2/rooms/<room>/read` `{device, seq}` (#571 B): the device has
    /// shown the room up to `seq`. The relay keeps one row per (room, actor),
    /// monotonic (`max(current, seq)`), and answers the resulting actor-wide
    /// `read_seq` — which may exceed `seq` when another device of the same
    /// person read further. Errors come back as the envelope: 404
    /// `no_such_room`, 410 `room_closed`, 403 `device_not_allowed` /
    /// `not_a_member`, 400 `bad_seq` (outside `0..last_seq`); a relay that
    /// predates the route answers a bare 404 (`RelayError::Status`). The
    /// caller decides what is ignorable — this is a courtesy signal, never
    /// the MLS cursor or ack.
    pub fn post_read(&self, room: &str, device: &str, seq: i64) -> Result<i64> {
        let post = ReadPost { device, seq };
        let resp = self.send("POST", &format!("/v2/rooms/{room}/read"), Some(serde_json::to_vec(&post)?.as_slice()))?;
        let answer: ReadResponse = serde_json::from_slice(self.checked(resp)?.as_slice())?;
        Ok(answer.read_seq)
    }

    // ---- #366 3c: device-level routes ----

    /// `POST /v2/lobby/keypackages` (#380 P5-1): publish into the device's
    /// room-independent pool, which a steward may consume for any room
    /// ([`Client::consume_lobby_key_package`]). 409 `key_package_limit` and
    /// 403 `device_not_allowed` come back as the envelope.
    pub fn post_lobby_key_packages(&self, device: &str, refs: &[(&str, Vec<u8>)]) -> Result<KeyPackagesStored> {
        let post = KeyPackagePost {
            device,
            packages: refs.iter().map(|(r, bytes)| KeyPackageRef { r#ref: r, bytes: bytes.clone() }).collect(),
        };
        let resp = self.send("POST", "/v2/lobby/keypackages", Some(serde_json::to_vec(&post)?.as_slice()))?;
        Ok(serde_json::from_slice(self.checked(resp)?.as_slice())?)
    }

    /// `GET /v2/lobby/status?device=`: live count and policy bounds — the
    /// replenish decision's input.
    pub fn lobby_status(&self, device: &str) -> Result<LobbyStatus> {
        let resp = self.send("GET", &format!("/v2/lobby/status?device={device}"), None)?;
        Ok(serde_json::from_slice(self.checked(resp)?.as_slice())?)
    }

    /// `GET /v2/lobby/welcomes?device=`: rooms holding an unread Welcome for
    /// the device (read-only; the Welcome itself is read through the room log).
    pub fn lobby_welcomes(&self, device: &str) -> Result<Vec<PendingWelcome>> {
        let resp = self.send("GET", &format!("/v2/lobby/welcomes?device={device}"), None)?;
        let body: WelcomesResponse = serde_json::from_slice(self.checked(resp)?.as_slice())?;
        Ok(body.welcomes)
    }

    /// `DELETE /v2/lobby/keypackages?device=` (#389): withdraw every unconsumed
    /// lobby package of the device. Returns how many were deleted.
    pub fn delete_lobby_key_packages(&self, device: &str) -> Result<u64> {
        let resp = self.send("DELETE", &format!("/v2/lobby/keypackages?device={device}"), None)?;
        let body: LobbyDeleteResponse = serde_json::from_slice(self.checked(resp)?.as_slice())?;
        Ok(body.deleted)
    }

    /// `GET /v2/rooms?device=` (#275 L2 ①): the rooms the device takes part in.
    pub fn list_rooms(&self, device: &str) -> Result<Vec<RoomListing>> {
        let resp = self.send("GET", &format!("/v2/rooms?device={device}"), None)?;
        let body: RoomsResponse = serde_json::from_slice(self.checked(resp)?.as_slice())?;
        Ok(body.rooms)
    }

    /// `POST /v2/push/devices` → 204: register the device's push token under
    /// `topic` (an app bundle id). Idempotent on the relay.
    pub fn register_push(&self, device: &str, token: &[u8], topic: &str) -> Result<()> {
        let body = PushRegistration { device, apns_token: token.to_vec(), topic };
        let resp = self.send("POST", "/v2/push/devices", Some(serde_json::to_vec(&body)?.as_slice()))?;
        self.checked(resp)?;
        Ok(())
    }

    /// `DELETE /v2/push/devices?device=` → 204: drop every token of the device.
    pub fn unregister_push(&self, device: &str) -> Result<()> {
        let resp = self.send("DELETE", &format!("/v2/push/devices?device={device}"), None)?;
        self.checked(resp)?;
        Ok(())
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

    fn envelope(&self, status: u16, body: Vec<u8>) -> RelayError {
        match serde_json::from_slice::<ApiErrorBody>(&body) {
            Ok(parsed) => RelayError::Api { status, code: parsed.error },
            Err(_) => RelayError::Status { status },
        }
    }
}

/// Room-scoped consume route (`GET /v2/rooms/<room>/keypackages`).
fn room_consume_path(room: &str, device: &str, consumer: &str) -> String {
    format!("/v2/rooms/{room}/keypackages?device={device}&consumer={consumer}")
}

/// Lobby consume route (`GET /v2/lobby/keypackages`, #380 P5); `room` is the
/// room the package is consumed for.
fn lobby_consume_path(room: &str, device: &str, consumer: &str) -> String {
    format!("/v2/lobby/keypackages?device={device}&consumer={consumer}&room={room}")
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
    use super::{is_identifier, lobby_consume_path, room_consume_path};

    /// #380 P5: the lobby consume carries the room as a query parameter
    /// (the pool is room-independent); the room consume keeps its path form.
    #[test]
    fn consume_paths_match_the_relay_contract() {
        assert_eq!(room_consume_path("family", "owner-pc", "bot-1"), "/v2/rooms/family/keypackages?device=owner-pc&consumer=bot-1");
        assert_eq!(lobby_consume_path("family", "owner-pc", "bot-1"), "/v2/lobby/keypackages?device=owner-pc&consumer=bot-1&room=family");
    }

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

        assert!(matches!(access.token(), Err(RelayError::AccessUnavailable("access token file unreadable"))));

        std::fs::write(&path, "tok-1\n").expect("write");
        assert_eq!(access.token().expect("token").as_deref(), Some("tok-1"));

        // Rotation: the next call must see the new content.
        std::fs::write(&path, "tok-2").expect("rewrite");
        assert_eq!(access.token().expect("token").as_deref(), Some("tok-2"));

        // Whitespace-only fails closed.
        std::fs::write(&path, "  \n").expect("blank");
        assert!(matches!(access.token(), Err(RelayError::AccessUnavailable("access token file is empty"))));

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

    /// #571 B: the read body is exactly `{device, seq}` (the relay parses it
    /// strictly) and the answer is the actor-wide value, which the relay may
    /// raise above what was posted.
    #[test]
    fn post_read_sends_the_strict_body_and_returns_the_actor_wide_value() {
        let listener = std::net::TcpListener::bind(("127.0.0.1", 0)).expect("bind");
        let addr = listener.local_addr().expect("addr");
        let server = std::thread::spawn(move || {
            let (mut stream, _) = listener.accept().expect("accept");
            let mut raw = Vec::new();
            let mut buf = [0u8; 1024];
            let body = br#"{"device":"owner-pc","seq":7}"#;
            while !raw.ends_with(body) {
                let n = stream.read(&mut buf).expect("read request");
                assert!(n > 0, "eof before body");
                raw.extend_from_slice(&buf[..n]);
            }
            let text = String::from_utf8(raw).expect("utf8");
            assert!(text.starts_with("POST /v2/rooms/family/read HTTP/1.1\r\n"), "{text}");
            stream.write_all(b"HTTP/1.1 200 OK\r\nContent-Length: 14\r\n\r\n{\"read_seq\":9}").expect("write response");
        });
        let client = Client::with_access(&format!("http://127.0.0.1:{}", addr.port()), Access::None);
        assert_eq!(client.post_read("family", "owner-pc", 7).expect("post read"), 9);
        server.join().expect("server thread");
    }

    /// A relay that predates #571 B omits `read_seq`; the page still parses
    /// and the position reads as 0 (nothing read).
    #[test]
    fn events_page_without_read_seq_reads_as_zero() {
        let page: EventsResponse =
            serde_json::from_str(r#"{"epoch":1,"revision":0,"events":[],"first_seq":0}"#).expect("old page");
        assert_eq!(page.read_seq, 0);
        let page: EventsResponse =
            serde_json::from_str(r#"{"epoch":1,"revision":0,"events":[],"first_seq":0,"read_seq":12}"#).expect("new page");
        assert_eq!(page.read_seq, 12);
    }
}
