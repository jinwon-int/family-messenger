//! #492: `native-mls-bot identity-public-key --identity-file <f>` prints the
//! same 64-hex signing key the steward announces in `steward_ready`, so the
//! installer can write `enrollment.json` without waiting on the journal.

use family_mls_browser_experiment::Device;
use std::path::PathBuf;
use std::process::Command;

const BIN: &str = env!("CARGO_BIN_EXE_native-mls-bot");

fn temp_dir(tag: &str) -> PathBuf {
    let dir = std::env::temp_dir().join(format!("native-mls-bot-{tag}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).expect("temp dir");
    dir
}

/// The bot's identity envelope (`session.rs` `IdentityEnvelope`, version 1).
fn write_identity(path: &PathBuf, device: &str) {
    let dev = Device::new(device).unwrap_or_else(|_| panic!("device new"));
    let bytes = dev.export_identity(device).unwrap_or_else(|_| panic!("export identity"));
    let identity: serde_json::Value = serde_json::from_slice(&bytes).expect("identity json");
    let env = serde_json::json!({ "version": 1, "device": device, "identity": identity });
    std::fs::write(path, serde_json::to_vec(&env).expect("envelope")).expect("write identity");
}

#[test]
fn identity_public_key_equals_steward_ready_public_key() {
    let dir = temp_dir("identity-public-key");
    let identity = dir.join("identity.json");
    write_identity(&identity, "bot-1");

    let out = Command::new(BIN)
        .args(["identity-public-key", "--identity-file"]).arg(&identity)
        .output().expect("run identity-public-key");
    assert!(out.status.success(), "identity-public-key failed: {}", String::from_utf8_lossy(&out.stderr));
    let printed = String::from_utf8(out.stdout).expect("utf8");
    let key = printed.trim_end_matches('\n');
    assert_eq!(printed, format!("{key}\n"), "exactly one line");
    assert!(key.len() == 64 && key.bytes().all(|b| b.is_ascii_hexdigit() && !b.is_ascii_uppercase()), "64 lowercase hex: {key:?}");

    // Same key with the device named; a foreign device is refused.
    let named = Command::new(BIN)
        .args(["identity-public-key", "bot-1", "--identity-file"]).arg(&identity)
        .output().expect("run identity-public-key bot-1");
    assert!(named.status.success());
    assert_eq!(String::from_utf8_lossy(&named.stdout).trim(), key);
    let foreign = Command::new(BIN)
        .args(["identity-public-key", "bot-2", "--identity-file"]).arg(&identity)
        .output().expect("run identity-public-key bot-2");
    assert!(!foreign.status.success() && foreign.stdout.is_empty(), "foreign device must fail closed");

    // The steward announces `steward_ready` before it touches the relay; an
    // unroutable relay and a 1 s deadline end the run right after.
    let rooms = dir.join("rooms");
    let steward = Command::new(BIN)
        .args(["http://127.0.0.1:9", "steward", "bot-1", "--identity-file"]).arg(&identity)
        .arg("--rooms-dir").arg(&rooms)
        .env("NATIVE_MLS_BOT_MAX_SECS", "1")
        .env_remove("NATIVE_MLS_BOT_RESPONDER_ARGV_JSON").env_remove("NATIVE_MLS_BOT_RESPONDER_UNIX")
        .output().expect("run steward");
    let stdout = String::from_utf8_lossy(&steward.stdout);
    let ready = stdout.lines()
        .filter_map(|line| serde_json::from_str::<serde_json::Value>(line).ok())
        .find(|v| v["event"] == "steward_ready")
        .unwrap_or_else(|| panic!("no steward_ready in: {stdout}"));
    assert_eq!(ready["public_key"].as_str(), Some(key));

    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn identity_public_key_needs_an_identity_file() {
    let out = Command::new(BIN)
        .arg("identity-public-key")
        .env_remove("NATIVE_MLS_BOT_IDENTITY_FILE")
        .output().expect("run");
    assert!(!out.status.success() && out.stdout.is_empty());
}
