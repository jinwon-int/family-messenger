//! Native MLS bot (M5, #177 §7 Q3 답 1): a Rust process that speaks MLS through
//! the browser facade and the v2 relay like any other leaf.
//!
//! `health`/`publish`/`consume` prove the /v2 wire shapes (M5 step 1);
//! `session <room> <device> [<watch-room> --watch]` runs the room loop —
//! publish a key package, join on the Welcome, apply commits, and echo every
//! application message back (see `session.rs`).

/// Relay client, HTTP, base64 and commit policy live in the shared host crate (#366) so the
/// Android app runs the same code; the bot keeps its historical name for the error type.
mod api {
    pub use native_mls_host::api::RelayError as BotError;
    pub use native_mls_host::api::*;
}
use native_mls_host::policy;
/// `session.rs` tests (#380 P5 lobby fixtures) reach base64 as `crate::b64`; keep that path
/// without pulling an unused import into the release build.
#[cfg(test)]
use native_mls_host::b64;
mod responder;
mod session;

use family_mls_browser_experiment::Device;
use std::process::ExitCode;

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().skip(1).collect();
    // Caller auth (relay -access-mode required, review C1): CLI flag wins,
    // then the token-file env, then a static token env. Without any of them
    // the bot only works against -access-mode disabled relays (local dev).
    let (access, args) = match extract_flag(&args, "--access-jwt-file") {
        Some(path) => (api::Access::File(std::path::PathBuf::from(path)), strip_flag(&args, "--access-jwt-file")),
        None => match std::env::var("NATIVE_MLS_BOT_ACCESS_JWT_FILE") {
            Ok(path) if !path.trim().is_empty() => (api::Access::File(std::path::PathBuf::from(path)), args),
            _ => match std::env::var("NATIVE_MLS_BOT_ACCESS_JWT") {
                Ok(token) if !token.trim().is_empty() => (api::Access::Static(token), args),
                _ => (api::Access::None, args),
            },
        },
    };
    // Persistent identity (M5 후속): `--state-file <path>` (any position).
    let (state_file, args) = match extract_flag(&args, "--state-file") {
        Some(path) => (Some(std::path::PathBuf::from(path)), strip_flag(&args, "--state-file")),
        None => (None, args),
    };
    // Steward (#372 P2): `--identity-file <path>` (signer only) + `--rooms-dir <dir>`
    // (one `<room>.state` per room, `cmd/`+`out/` command queue).
    let (identity_file, args) = match extract_flag(&args, "--identity-file") {
        Some(path) => (Some(std::path::PathBuf::from(path)), strip_flag(&args, "--identity-file")),
        None => (std::env::var("NATIVE_MLS_BOT_IDENTITY_FILE").ok().filter(|v| !v.trim().is_empty()).map(std::path::PathBuf::from), args),
    };
    let (rooms_dir, args) = match extract_flag(&args, "--rooms-dir") {
        Some(path) => (Some(std::path::PathBuf::from(path)), strip_flag(&args, "--rooms-dir")),
        None => (std::env::var("NATIVE_MLS_BOT_ROOMS_DIR").ok().filter(|v| !v.trim().is_empty()).map(std::path::PathBuf::from), args),
    };
    // Agent mode (#354 A1): `--responder-argv-json '["python3","…/fleet_worker.py",…]'`
    // (or env NATIVE_MLS_BOT_RESPONDER_ARGV_JSON) replaces the echo with a
    // ccc-node turn per message; `--owner-actor` (env NATIVE_MLS_BOT_OWNER_ACTOR,
    // default `owner`) names the actor whose `승인 n`/`거절 n` replies resolve approvals.
    let (responder_json, args) = match extract_flag(&args, "--responder-argv-json") {
        Some(json) => (Some(json), strip_flag(&args, "--responder-argv-json")),
        None => (std::env::var("NATIVE_MLS_BOT_RESPONDER_ARGV_JSON").ok().filter(|v| !v.trim().is_empty()), args),
    };
    // `--responder-unix <socket>` (env NATIVE_MLS_BOT_RESPONDER_UNIX): connect to a
    // service-manager-owned socket instead of spawning (the worker then runs as
    // the account holding the AI credentials — see AGENT.md). Mutually exclusive.
    let (responder_unix, args) = match extract_flag(&args, "--responder-unix") {
        Some(path) => (Some(path), strip_flag(&args, "--responder-unix")),
        None => (std::env::var("NATIVE_MLS_BOT_RESPONDER_UNIX").ok().filter(|v| !v.trim().is_empty()), args),
    };
    let (owner_actor, args) = match extract_flag(&args, "--owner-actor") {
        Some(actor) => (actor, strip_flag(&args, "--owner-actor")),
        None => (std::env::var("NATIVE_MLS_BOT_OWNER_ACTOR").ok().filter(|v| !v.trim().is_empty()).unwrap_or_else(|| "owner".to_string()), args),
    };
    let owner_ok = api::require_identifier("owner actor must match [A-Za-z0-9_-]{1,64}", &owner_actor).is_ok();
    let responder = match (responder_json, responder_unix) {
        (None, None) => None,
        (Some(_), Some(_)) => {
            eprintln!("native-mls-bot: give either --responder-argv-json or --responder-unix, not both");
            return ExitCode::FAILURE;
        }
        (Some(json), None) => match serde_json::from_str::<Vec<String>>(&json) {
            Ok(argv) if !argv.is_empty() && owner_ok => Some(responder::Config::new(responder::Transport::Argv(argv), owner_actor)),
            _ => {
                eprintln!("native-mls-bot: --responder-argv-json must be a non-empty JSON string array and --owner-actor an identifier");
                return ExitCode::FAILURE;
            }
        },
        (None, Some(path)) if owner_ok => Some(responder::Config::new(responder::Transport::Unix(std::path::PathBuf::from(path)), owner_actor)),
        (None, Some(_)) => {
            eprintln!("native-mls-bot: --owner-actor must be an identifier");
            return ExitCode::FAILURE;
        }
    };
    // Review 2 L: every room/device/consumer argument must already be a relay
    // identifier — nothing that needs encoding is ever interpolated into a path.
    if let Err(e) = validate_identifiers(&args) {
        eprintln!("native-mls-bot: {e}");
        return ExitCode::FAILURE;
    }
    let result = match args.as_slice() {
        [base, cmd] if cmd == "health" => cmd_health(base, &access),
        // #372 P2 — steward: one identity, many rooms, operator commands via the queue.
        [base, cmd, device] if cmd == "steward" => match (identity_file.clone(), rooms_dir.clone()) {
            (Some(identity_file), Some(rooms_dir)) => api::require_identifier("device must match [A-Za-z0-9_-]{1,64}", device)
                .and_then(|()| session::run_steward(session::StewardOptions {
                    base: base.to_string(), device: device.to_string(), access: access.clone(),
                    identity_file, rooms_dir, responder: responder.clone(),
                })),
            _ => Err(api::BotError::Local("steward needs --identity-file and --rooms-dir")),
        },
        // One-shot migration: split the signer out of a single-room state file.
        [cmd, room, device] if cmd == "extract-identity" => match (state_file.clone(), identity_file.clone()) {
            (Some(state_file), Some(identity_file)) => api::require_identifier("room must match [A-Za-z0-9_-]{1,64}", room)
                .and_then(|()| api::require_identifier("device must match [A-Za-z0-9_-]{1,64}", device))
                .and_then(|()| session::extract_identity(&state_file, room, device, &identity_file)),
            _ => Err(api::BotError::Local("extract-identity needs --state-file and --identity-file")),
        },
        // Operator commands against a running steward (same --rooms-dir).
        [cmd, op, room, rest @ ..] if cmd == "room" && rest.len() <= 1 => match rooms_dir.clone() {
            Some(rooms_dir) => {
                let arg = rest.first().cloned().unwrap_or_default();
                let command = session::Command { op: op.to_string(), room: room.to_string(), arg };
                session::request(&rooms_dir, &command, std::time::Duration::from_secs(90)).and_then(|outcome| {
                    println!("{outcome}");
                    if outcome.get("ok").and_then(|v| v.as_bool()) == Some(true) { Ok(()) } else { Err(api::BotError::Local("command failed")) }
                })
            }
            None => Err(api::BotError::Local("room commands need --rooms-dir")),
        },
        [base, cmd, room, device] if cmd == "publish" => cmd_publish(base, room, device, &access),
        [base, cmd, room, device, consumer] if cmd == "consume" => cmd_consume(base, room, device, consumer, &access),
        [base, cmd, room, device] if cmd == "session" => {
            session::run(session::Options {
                base: base.to_string(),
                room: room.to_string(),
                device: device.to_string(),
                watch_room: None,
                access: access.clone(),
                state_file: state_file.clone(),
                responder: responder.clone(),
            })
        }
        [base, cmd, room, device, watch_room, extra] if cmd == "session" && extra == "--watch" => {
            session::run(session::Options {
                base: base.to_string(),
                room: room.to_string(),
                device: device.to_string(),
                watch_room: Some(watch_room.to_string()),
                access: access.clone(),
                state_file: state_file.clone(),
                responder: responder.clone(),
            })
        }
        _ => {
            eprintln!("usage: native-mls-bot <base-url> health");
            eprintln!("       native-mls-bot <base-url> steward <device> --identity-file <path> --rooms-dir <dir>   (#372 P2)");
            eprintln!("       native-mls-bot extract-identity <room> <device> --state-file <path> --identity-file <path>");
            eprintln!("       native-mls-bot room <create|join|invite|remove|members|mode|status> <room> [<device>|agent|silent] --rooms-dir <dir>");
            eprintln!("       native-mls-bot <base-url> publish <room> <device>");
            eprintln!("       native-mls-bot <base-url> consume <room> <device> <consumer>");
            eprintln!("       native-mls-bot <base-url> session <room> <device> [<watch-room> --watch]");
            eprintln!("caller auth (--access-jwt-file <path>, any position; env NATIVE_MLS_BOT_ACCESS_JWT_FILE");
            eprintln!("or NATIVE_MLS_BOT_ACCESS_JWT): every request carries the CF Access assertion; the file is");
            eprintln!("re-read per request so an external refresher can rotate short-lived tokens");
            eprintln!("persistent identity (--state-file <path>, any position): the bot resumes its MLS");
            eprintln!("identity, room cursor and joined state across restarts; the file is rewritten");
            eprintln!("atomically whenever the group state moves (and before every echo leaves the process)");
            eprintln!("NATIVE_MLS_BOT_MAX_SECS=<secs> bounds the session (default 300; 0 = no deadline)");
            eprintln!("agent mode (--responder-argv-json <json array> | --responder-unix <socket>; env NATIVE_MLS_BOT_RESPONDER_ARGV_JSON |");
            eprintln!("NATIVE_MLS_BOT_RESPONDER_UNIX): every");
            eprintln!("application message becomes one turn of the stdio worker (docs/FLEET-WORKER.md) instead of an echo;");
            eprintln!("--owner-actor <actor> (env NATIVE_MLS_BOT_OWNER_ACTOR, default owner) answers approvals with 승인 n / 거절 n");
            return ExitCode::FAILURE;
        }
    };
    match result {
        Ok(()) => ExitCode::SUCCESS,
        Err(e) => {
            eprintln!("native-mls-bot: {e}");
            ExitCode::FAILURE
        }
    }
}

/// The positional identifiers of each subcommand (`publish <room> <device>`,
/// `consume <room> <device> <consumer>`, `session <room> <device> [<watch>]`)
/// must match the relay's `[A-Za-z0-9_-]{1,64}` rule.
fn validate_identifiers(args: &[String]) -> Result<(), api::BotError> {
    let names: &[(&'static str, usize)] = match args.get(1).map(String::as_str) {
        Some("publish") => &[
            ("room must match [A-Za-z0-9_-]{1,64}", 2),
            ("device must match [A-Za-z0-9_-]{1,64}", 3),
        ],
        Some("consume") => &[
            ("room must match [A-Za-z0-9_-]{1,64}", 2),
            ("device must match [A-Za-z0-9_-]{1,64}", 3),
            ("consumer must match [A-Za-z0-9_-]{1,64}", 4),
        ],
        Some("session") => &[
            ("room must match [A-Za-z0-9_-]{1,64}", 2),
            ("device must match [A-Za-z0-9_-]{1,64}", 3),
            ("watch-room must match [A-Za-z0-9_-]{1,64}", 4),
        ],
        _ => &[],
    };
    for (what, at) in names {
        if let Some(value) = args.get(*at) {
            if value == "--watch" {
                continue;
            }
            api::require_identifier(what, value)?;
        }
    }
    Ok(())
}

/// Pull `--access-jwt-file <path>` (or `--access-jwt-file=<path>`) out of the
/// argument list without constraining its position relative to the subcommand.
fn extract_flag(args: &[String], name: &str) -> Option<String> {
    for i in 0..args.len() {
        if args[i] == name {
            return args.get(i + 1).map(|p| p.trim().to_string());
        }
        if let Some(value) = args[i].strip_prefix(&format!("{name}=")) {
            return Some(value.trim().to_string());
        }
    }
    None
}

fn strip_flag(args: &[String], name: &str) -> Vec<String> {
    let mut out = Vec::with_capacity(args.len());
    let mut skip_next = false;
    for arg in args {
        if skip_next {
            skip_next = false;
            continue;
        }
        if arg == name {
            skip_next = true;
            continue;
        }
        if arg.starts_with(&format!("{name}=")) {
            continue;
        }
        out.push(arg.clone());
    }
    out
}

fn cmd_health(base: &str, access: &api::Access) -> Result<(), api::BotError> {
    if api::Client::with_access(base, access.clone()).health()? {
        println!("health ok ({base})");
        Ok(())
    } else {
        Err(api::BotError::Local("health 200 but ok=false"))
    }
}

/// Publish one fresh key package for `device` (ref = sha256 hex).
fn cmd_publish(base: &str, room: &str, device: &str, access: &api::Access) -> Result<(), api::BotError> {
    let mut device_handle =
        Device::new(device).map_err(|_| api::BotError::Local("device new: identity shape rejected"))?;
    let key_package = device_handle
        .key_package()
        .map_err(|_| api::BotError::Local("key package generation"))?;
    let key_ref = api::ref_hex(&key_package);
    let stored = api::Client::with_access(base, access.clone()).post_key_packages(
        room,
        device,
        &[(key_ref.as_str(), key_package)],
    )?;
    println!("published 1 key package for {device} in {room} (ref {key_ref}, stored {stored})");
    Ok(())
}

/// Consume `device`'s live key package as `consumer`.
fn cmd_consume(base: &str, room: &str, device: &str, consumer: &str, access: &api::Access) -> Result<(), api::BotError> {
    match api::Client::with_access(base, access.clone()).consume_key_package(room, device, consumer)? {
        Some(pkg) => {
            // The bot's own convention: refs are sha256 hex of the package, so
            // consume must return the exact bytes that were published.
            if api::ref_hex(&pkg.bytes) != pkg.key_ref {
                return Err(api::BotError::Local("consumed key package bytes do not match its sha256 ref"));
            }
            println!("consumed ref {} ({} bytes, expires_at {}) — sha256 matches ref",
                pkg.key_ref, pkg.bytes.len(), pkg.expires_at);
            Ok(())
        }
        None => {
            println!("no live key package for {device} in {room}");
            Ok(())
        }
    }
}

