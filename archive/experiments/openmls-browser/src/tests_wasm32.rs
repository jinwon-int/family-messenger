//! Real-target tests (wasm32-unknown-unknown): the CI `native-mls` job runs
//! this crate's tests on the target the bundle ships as, via the pinned
//! wasm-bindgen release's `wasm-bindgen-test-runner` in node. The host suite
//! (`tests_v2`) executes the same vectors against a 64-bit `usize`; these pin
//! the 32-bit behaviour the review-M3 guards exist for, plus the
//! stage-report wire format (review 2 J-MB).
use super::*;
use wasm_bindgen_test::wasm_bindgen_test;

/// §3.6-binding frames, same shape as the host suite's helpers.
fn enc(room: &str, client: &str, payload: &[u8]) -> Vec<u8> {
    let mut out = Vec::new();
    for part in [room.as_bytes(), client.as_bytes()] {
        out.extend_from_slice(&(part.len() as u32).to_le_bytes());
        out.extend_from_slice(part);
    }
    out.extend_from_slice(payload);
    out
}
fn dec(room: &str, wire: &[u8]) -> Vec<u8> {
    let mut out = (room.len() as u32).to_le_bytes().to_vec();
    out.extend_from_slice(room.as_bytes());
    out.extend_from_slice(wire);
    out
}
/// Inverse of `frame_decrypt` (DECRYPT_FORMAT 2).
fn attributed(out: &[u8]) -> (String, String, Vec<u8>) {
    let mut rest = out;
    let mut field = || {
        let len = u32::from_le_bytes(rest[..4].try_into().unwrap()) as usize;
        let value = String::from_utf8(rest[4..4 + len].to_vec()).unwrap();
        rest = &rest[4 + len..];
        value
    };
    let (sender, client) = (field(), field());
    (sender, client, rest.to_vec())
}
/// One `frame_members` section of a stage report.
fn take_roster(rest: &mut &[u8]) -> Vec<(String, Vec<u8>)> {
    let count = u32::from_le_bytes(rest[..4].try_into().unwrap()) as usize;
    *rest = &rest[4..];
    let mut out = Vec::new();
    for _ in 0..count {
        let len = u32::from_le_bytes(rest[..4].try_into().unwrap()) as usize;
        let identity = String::from_utf8(rest[4..4 + len].to_vec()).unwrap();
        let key = rest[4 + len..4 + len + 32].to_vec();
        *rest = &rest[4 + len + 32..];
        out.push((identity, key));
    }
    out
}

/// Review M3: a length field that would make `4 + len` wrap on this target's
/// 32-bit `usize` (or index past the end) is rejected before any arithmetic;
/// exactly `MAX_IDENTITY` still parses.
#[wasm_bindgen_test]
fn split_identity_rejects_lengths_that_cannot_fit_32_bit_usize() {
    for len in [u32::MAX - 1, 0xFFFF_FFFC, u32::MAX, 65, 0] {
        let mut input = len.to_le_bytes().to_vec();
        input.extend_from_slice(b"family-payload");
        assert_eq!(split_identity(&input).err(), Some(rejected(())), "len {len:#x}");
    }
    let mut input = 64u32.to_le_bytes().to_vec();
    input.extend_from_slice(&[b'a'; 64]);
    input.extend_from_slice(b"rest");
    assert_eq!(split_identity(&input).unwrap(), ("a".repeat(64).as_str(), b"rest".as_slice()));
    assert!(split_identity(&[3, 0, 0, 0, b'a', b'b']).is_err(), "declared length past the end");
}

/// The AAD frame guards on the shipped target: a malformed or lying header is
/// refused before MLS state is touched, and a wrong room context cannot open.
#[wasm_bindgen_test]
fn aad_frames_reject_malformed_input_on_wasm32() {
    let mut alice = Device::new("alice").unwrap();
    alice.create_inner().unwrap();
    for input in [&b""[..], &[1u8, 0, 0, 0], &[u8::MAX, 0, 0, 0], b"\x06\x00\x00\x00famil\x00"] {
        assert!(alice.encrypt_inner(input).is_err(), "{input:?}");
        assert!(alice.decrypt_inner(input).is_err(), "{input:?}");
    }
    for room in ["bad room", &"a".repeat(65)[..]] {
        assert!(alice.decrypt_inner(&dec(room, &[1, 2, 3])).is_err(), "{room:?}");
    }
}

/// End-to-end on the shipped target: the relay two-phase flow, the §3.6-bound
/// encrypt/decrypt roundtrip, and the stage report wire format
/// (`STAGE_REPORT_FORMAT` 2 — four `frame_members` sections; the add-only
/// commit carries no update proposals but always the committer's path leaf).
#[wasm_bindgen_test]
fn relay_flow_and_stage_report_format_work_on_wasm32() {
    assert_eq!(Device::decrypt_format(), 2);
    assert_eq!(Device::stage_report_format(), 2);
    let mut a1 = Device::new("a:1").unwrap();
    let mut a2 = Device::new("a:2").unwrap();
    let mut a3 = Device::new("a:3").unwrap();
    a1.create().unwrap();
    let framed = a1.invite_with_commit(&a2.key_package().unwrap()).unwrap();
    a1.merge_pending().unwrap();
    let n = u32::from_le_bytes(framed[..4].try_into().unwrap()) as usize;
    a2.join(&framed[4 + n..]).unwrap();
    let wire = a1.encrypt(&enc("family", "a:1", b"wasm32")).unwrap();
    assert_eq!(attributed(&a2.decrypt(&dec("family", &wire)).unwrap()),
        ("a:1".into(), "a:1".into(), b"wasm32".to_vec()));

    // a1 invites a3; a2 stages the commit and reads the report before merging.
    let framed = a1.invite_with_commit(&a3.key_package().unwrap()).unwrap();
    a1.merge_pending().unwrap();
    let n2 = u32::from_le_bytes(framed[..4].try_into().unwrap()) as usize;
    let (commit, welcome) = (&framed[4..4 + n2], &framed[4 + n2..]);
    let report = a2.stage_commit(commit).unwrap();
    let mut rest = report.as_slice();
    let [adds, removes, updates, path] = std::array::from_fn(|_| take_roster(&mut rest));
    assert!(rest.is_empty(), "report is exactly the four sections");
    assert_eq!(adds, vec![("a:3".into(), a3.public_key().unwrap())]);
    assert_eq!((removes, updates), (vec![], vec![]),
        "add-only commits carry no update proposals");
    assert_eq!(path, vec![("a:1".into(), a1.public_key().unwrap())],
        "the committer's path leaf rides every member commit (OpenMLS 0.9)");
    a2.merge_staged().unwrap();
    a3.join(welcome).unwrap();
    let reply = a3.encrypt(&enc("family", "a:3", b"three leaves")).unwrap();
    assert_eq!(attributed(&a2.decrypt(&dec("family", &reply)).unwrap()),
        ("a:3".into(), "a:3".into(), b"three leaves".to_vec()));
}
