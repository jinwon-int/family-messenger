//! Host-neutral pieces of the native-mls v2 client (#366), moved unchanged out of
//! `native-mls-bot` so every Rust host — the bot today, the Android app (#338) next —
//! runs one implementation instead of a port per host.
//!
//! - [`api`]: typed client and wire types for the v2 relay (`archive/native-mls/server`).
//! - [`http`]: minimal HTTP/1.1 over `TcpStream` (plain HTTP; the bot reaches the relay over the
//!   tailnet). A TLS transport for hosts on the public internet is not here yet.
//! - [`b64`]: standard-alphabet base64 for the relay's byte fields.
//! - [`policy`]: client-side commit policy (#263), run against
//!   `archive/native-mls/tests/fixtures/commit-policy-vectors.json` like `web/commit-policy.js`.
//!
//! This crate does not link the MLS facade: hosts pass it framed bytes and reports.
pub mod api;
pub mod b64;
pub mod http;
pub mod policy;
