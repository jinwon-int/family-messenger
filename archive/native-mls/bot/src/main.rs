//! Native MLS bot (M5, #177 §7 Q3 답 1): a Rust process that speaks MLS through
//! the browser facade and the v2 relay like any other leaf.
//!
//! This commit is the risk-resolution slice: the facade links natively (see
//! `tests/native_facade_link.rs`), and this binary already talks `/v2` with the
//! relay's exact wire shapes (`health`/`publish`/`consume`). Room-session
//! behavior (join on welcome, echo replies, attachment frames) lands next.

mod api;
mod b64;
mod http;

use family_mls_browser_experiment::Device;
use std::process::ExitCode;

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let result = match args.as_slice() {
        [base, cmd] if cmd == "health" => cmd_health(base),
        [base, cmd, room, device] if cmd == "publish" => cmd_publish(base, room, device),
        [base, cmd, room, device, consumer] if cmd == "consume" => cmd_consume(base, room, device, consumer),
        _ => {
            eprintln!("usage: native-mls-bot <base-url> health");
            eprintln!("       native-mls-bot <base-url> publish <room> <device>");
            eprintln!("       native-mls-bot <base-url> consume <room> <device> <consumer>");
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

fn cmd_health(base: &str) -> Result<(), api::BotError> {
    if api::Client::new(base).health()? {
        println!("health ok ({base})");
        Ok(())
    } else {
        Err(api::BotError::Local("health 200 but ok=false"))
    }
}

/// Publish one fresh key package for `device` (ref = sha256 hex).
fn cmd_publish(base: &str, room: &str, device: &str) -> Result<(), api::BotError> {
    let mut device_handle =
        Device::new(device).map_err(|_| api::BotError::Local("device new: identity shape rejected"))?;
    let key_package = device_handle
        .key_package()
        .map_err(|_| api::BotError::Local("key package generation"))?;
    let key_ref = api::ref_hex(&key_package);
    let stored = api::Client::new(base).post_key_packages(
        room,
        device,
        &[(key_ref.as_str(), key_package)],
    )?;
    println!("published 1 key package for {device} in {room} (ref {key_ref}, stored {stored})");
    Ok(())
}

/// Consume `device`'s live key package as `consumer`.
fn cmd_consume(base: &str, room: &str, device: &str, consumer: &str) -> Result<(), api::BotError> {
    match api::Client::new(base).consume_key_package(room, device, consumer)? {
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

