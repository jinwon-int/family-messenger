//! Risk gate for M5 (#177): the browser facade must build and run on the host
//! as a plain path dependency of the native bot. wasm-bindgen is annotations
//! only on non-wasm targets; everything under it (MLS suite, AAD binding, v2
//! record store) is pure Rust. If this test breaks, the "one facade for
//! browser and bot" premise of M5 is dead and the bot needs its own MLS stack.

use family_mls_browser_experiment::{Device, DECRYPT_FORMAT};

fn ok<T>(result: Result<T, family_mls_browser_experiment::Rejected>, what: &str) -> T {
    match result {
        Ok(value) => value,
        Err(_) => panic!("facade rejected: {what}"),
    }
}

/// `encrypt` wire framing: `u32le len ‖ room ‖ u32le len ‖ client_id ‖ plaintext`.
fn frame(room: &str, client_id: &str, plaintext: &[u8]) -> Vec<u8> {
    let mut out = Vec::new();
    out.extend_from_slice(&(room.len() as u32).to_le_bytes());
    out.extend_from_slice(room.as_bytes());
    out.extend_from_slice(&(client_id.len() as u32).to_le_bytes());
    out.extend_from_slice(client_id.as_bytes());
    out.extend_from_slice(plaintext);
    out
}

/// `decrypt` wire framing: `u32le len ‖ room ‖ ciphertext`.
fn frame_room(room: &str, ciphertext: &[u8]) -> Vec<u8> {
    let mut out = Vec::new();
    out.extend_from_slice(&(room.len() as u32).to_le_bytes());
    out.extend_from_slice(room.as_bytes());
    out.extend_from_slice(ciphertext);
    out
}

/// `decrypt` output framing (`DECRYPT_FORMAT` 2): `u32le len ‖ sender_device ‖
/// u32le len ‖ client_id ‖ plaintext`.
fn frame_decrypt(sender_device: &str, client_id: &str, plaintext: &[u8]) -> Vec<u8> {
    let mut out = Vec::new();
    out.extend_from_slice(&(sender_device.len() as u32).to_le_bytes());
    out.extend_from_slice(sender_device.as_bytes());
    out.extend_from_slice(&(client_id.len() as u32).to_le_bytes());
    out.extend_from_slice(client_id.as_bytes());
    out.extend_from_slice(plaintext);
    out
}

#[test]
fn native_two_device_roundtrip_through_the_facade() {
    // Pin the decrypt framing this test asserts against; if the facade bumps
    // it, this line is where the bot's parser must be updated too.
    assert_eq!(DECRYPT_FORMAT, 2);
    assert_eq!(Device::decrypt_format(), 2);

    let mut owner = ok(Device::new("owner.dev1"), "owner device new");
    let mut bot = ok(Device::new("bot.dev1"), "bot device new");

    // Kit flow rule: the inviter consumes the joiner's published key package.
    let bot_key_package = ok(bot.key_package(), "bot key package");
    ok(owner.create(), "owner creates group");
    let welcome = ok(owner.invite(&bot_key_package), "owner invites bot");
    ok(bot.join(&welcome), "bot joins via welcome");

    // Text both ways, AAD-checked like on the wire. Attribution rule (review
    // H1): the bot crate only gets `decrypt` (no pin map), so the AAD client_id
    // must equal the sender's device identity — same contract the bot session
    // will use on the relay.
    let to_bot = ok(owner.encrypt(&frame("room-a", "owner.dev1", b"hello bot")), "owner encrypt");
    let got = ok(bot.decrypt(&frame_room("room-a", &to_bot)), "bot decrypt");
    assert_eq!(got, frame_decrypt("owner.dev1", "owner.dev1", b"hello bot"));

    let to_owner = ok(bot.encrypt(&frame("room-a", "bot.dev1", b"hello owner")), "bot encrypt");
    let got = ok(owner.decrypt(&frame_room("room-a", &to_owner)), "owner decrypt");
    assert_eq!(got, frame_decrypt("bot.dev1", "bot.dev1", b"hello owner"));
}

/// Persistent bot identity (M5 후속): the state file is the whole device. The
/// resumed device must hold the same signing key and keep decrypting and
/// encrypting on the group ratchet — otherwise a restart would need a new
/// enrollment and a re-invite, which is exactly what persistence avoids.
#[test]
fn exported_state_resumes_the_same_identity_and_ratchet() {
    let mut owner = ok(Device::new("owner.dev1"), "owner device new");
    let mut bot = ok(Device::new("bot.dev1"), "bot device new");

    let bot_key_package = ok(bot.key_package(), "bot key package");
    ok(owner.create(), "owner creates group");
    let welcome = ok(owner.invite(&bot_key_package), "owner invites bot");
    ok(bot.join(&welcome), "bot joins via welcome");
    let before = ok(owner.encrypt(&frame("room-a", "owner.dev1", b"before")), "owner encrypt");
    ok(bot.decrypt(&frame_room("room-a", &before)), "bot decrypt before");

    // The bot process dies; `export_state` bytes are all that survive it.
    let exported = ok(bot.export_state("bot.dev1"), "bot export state");
    // The binding refuses to replay the file as another device.
    assert!(Device::import_state("bot.dev2", &exported).is_err(), "foreign identity rejected");

    let mut resumed = ok(Device::import_state("bot.dev1", &exported), "bot import state");
    assert_eq!(ok(resumed.public_key(), "resumed public key"), ok(bot.public_key(), "bot public key"),
        "restart must not mint a new identity");

    // Traffic that only exists after the restart: the resumed device is a
    // full member (decrypt) and its echo holds (encrypt advances the ratchet).
    let after = ok(owner.encrypt(&frame("room-a", "owner.dev1", b"after restart")), "owner encrypt after");
    let got = ok(resumed.decrypt(&frame_room("room-a", &after)), "resumed decrypt after restart");
    assert_eq!(got, frame_decrypt("owner.dev1", "owner.dev1", b"after restart"));
    let echo = ok(resumed.encrypt(&frame("room-a", "bot.dev1", b"after restart")), "resumed encrypt");
    let got = ok(owner.decrypt(&frame_room("room-a", &echo)), "owner decrypt resumed echo");
    assert_eq!(got, frame_decrypt("bot.dev1", "bot.dev1", b"after restart"));
}
