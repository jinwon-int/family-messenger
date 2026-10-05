//! 스파이크 A 호스트 게이트 (#271 §12-A): 봇 `tests/native_facade_link.rs` 의 두 시나리오를
//! **FFI 객체(`MlsDevice::dispatch`)** 를 통해 반복한다. 이 테스트가 깨지면 "브라우저·봇·iOS 가 한 파사드"라는
//! 전제가 깨진 것이다. 프레이밍 규칙은 봇 테스트와 글자 그대로 같다.
use family_mls_ios_ffi::{decrypt_format, methods, MlsDevice, MlsError};

fn ok<T>(result: Result<T, MlsError>, what: &str) -> T {
    match result {
        Ok(value) => value,
        Err(err) => panic!("ffi rejected: {what}: {err}"),
    }
}

/// `encrypt`: `u32le len ‖ room ‖ u32le len ‖ client_id ‖ plaintext`.
fn frame(room: &str, client_id: &str, plaintext: &[u8]) -> Vec<u8> {
    let mut out = Vec::new();
    out.extend_from_slice(&(room.len() as u32).to_le_bytes());
    out.extend_from_slice(room.as_bytes());
    out.extend_from_slice(&(client_id.len() as u32).to_le_bytes());
    out.extend_from_slice(client_id.as_bytes());
    out.extend_from_slice(plaintext);
    out
}

/// `decrypt` 입력: `u32le len ‖ room ‖ ciphertext`.
fn frame_room(room: &str, ciphertext: &[u8]) -> Vec<u8> {
    let mut out = Vec::new();
    out.extend_from_slice(&(room.len() as u32).to_le_bytes());
    out.extend_from_slice(room.as_bytes());
    out.extend_from_slice(ciphertext);
    out
}

/// `decrypt` 출력(`DECRYPT_FORMAT` 2): `u32le len ‖ sender_device ‖ u32le len ‖ client_id ‖ plaintext`.
fn frame_decrypt(sender_device: &str, client_id: &str, plaintext: &[u8]) -> Vec<u8> {
    let mut out = Vec::new();
    out.extend_from_slice(&(sender_device.len() as u32).to_le_bytes());
    out.extend_from_slice(sender_device.as_bytes());
    out.extend_from_slice(&(client_id.len() as u32).to_le_bytes());
    out.extend_from_slice(client_id.as_bytes());
    out.extend_from_slice(plaintext);
    out
}

fn call(device: &MlsDevice, method: &str, input: &[u8]) -> Result<Vec<u8>, MlsError> {
    device.dispatch(method.to_owned(), input.to_vec())
}

#[test]
fn two_devices_roundtrip_through_the_ffi_object() {
    assert_eq!(decrypt_format(), 2, "host parser pins decrypt framing 2");
    assert!(methods().iter().any(|m| m == "stage_commit"), "durable-lane commit staging is exposed");

    let owner = ok(MlsDevice::new("owner-iphone".into()), "owner new");
    let peer = ok(MlsDevice::new("owner-pc".into()), "peer new");

    let peer_kp = ok(call(&peer, "key_package", &[]), "peer key package");
    assert_eq!(ok(peer.key_packages_outstanding(), "outstanding"), 1);
    ok(call(&owner, "create", &[]), "owner creates group");
    let welcome = ok(call(&owner, "invite", &peer_kp), "owner invites peer");
    ok(call(&peer, "join", &welcome), "peer joins");

    let to_peer = ok(call(&owner, "encrypt", &frame("room-a", "owner-iphone", b"hello pc")), "owner encrypt");
    let got = ok(call(&peer, "decrypt", &frame_room("room-a", &to_peer)), "peer decrypt");
    assert_eq!(got, frame_decrypt("owner-iphone", "owner-iphone", b"hello pc"));

    let to_owner = ok(call(&peer, "encrypt", &frame("room-a", "owner-pc", b"hello iphone")), "peer encrypt");
    let got = ok(call(&owner, "decrypt", &frame_room("room-a", &to_owner)), "owner decrypt");
    assert_eq!(got, frame_decrypt("owner-pc", "owner-pc", b"hello iphone"));
}

#[test]
fn export_import_resumes_identity_and_rejects_foreign_identity() {
    let owner = ok(MlsDevice::new("owner-iphone".into()), "owner new");
    let peer = ok(MlsDevice::new("owner-pc".into()), "peer new");
    let peer_kp = ok(call(&peer, "key_package", &[]), "peer key package");
    ok(call(&owner, "create", &[]), "create");
    let welcome = ok(call(&owner, "invite", &peer_kp), "invite");
    ok(call(&peer, "join", &welcome), "join");
    let before = ok(call(&owner, "encrypt", &frame("room-a", "owner-iphone", b"before")), "encrypt before");
    ok(call(&peer, "decrypt", &frame_room("room-a", &before)), "decrypt before");

    // 프로세스 종료(NSE/앱 교대) — 살아남는 것은 export_state 바이트뿐.
    let exported = ok(peer.export_state(), "export");
    assert!(MlsDevice::import_state("owner-pc-2".into(), exported.clone()).is_err(), "foreign identity rejected");
    let resumed = ok(MlsDevice::import_state("owner-pc".into(), exported), "import");
    assert_eq!(ok(resumed.public_key(), "pk"), ok(peer.public_key(), "pk"), "restart must not mint a new identity");
    assert_eq!(ok(resumed.fingerprint(), "fp").len(), 64, "fingerprint is sha256 hex");
    assert_eq!(ok(resumed.fingerprint(), "fp"), ok(peer.fingerprint(), "fp"));

    let after = ok(call(&owner, "encrypt", &frame("room-a", "owner-iphone", b"after restart")), "encrypt after");
    let got = ok(call(&resumed, "decrypt", &frame_room("room-a", &after)), "resumed decrypt");
    assert_eq!(got, frame_decrypt("owner-iphone", "owner-iphone", b"after restart"));
    let echo = ok(call(&resumed, "encrypt", &frame("room-a", "owner-pc", b"after restart")), "resumed encrypt");
    let got = ok(call(&owner, "decrypt", &frame_room("room-a", &echo)), "owner decrypt echo");
    assert_eq!(got, frame_decrypt("owner-pc", "owner-pc", b"after restart"));
}

#[test]
fn rejected_operation_rolls_back_to_the_snapshot() {
    let owner = ok(MlsDevice::new("owner-iphone".into()), "owner new");
    ok(call(&owner, "create", &[]), "create");
    let fp = ok(owner.fingerprint(), "fp");
    // 잘못된 Welcome 바이트로 join → 파사드 거부 → 기기는 스냅샷으로 복원되어 계속 쓸 수 있어야 한다.
    let err = call(&owner, "join", b"not a welcome").expect_err("garbage welcome must be rejected");
    assert!(matches!(err, MlsError::Rejected { .. }), "facade rejection surfaces as Rejected: {err}");
    assert_eq!(ok(owner.fingerprint(), "fp after rollback"), fp, "identity survives a rejected op");
    let kp = ok(call(&owner, "key_package", &[]), "device still usable after rollback");
    assert!(!kp.is_empty());
    let unknown = call(&owner, "members", &[]).expect_err("session-level methods are not exposed in the spike");
    assert!(matches!(unknown, MlsError::Invalid { .. }));
}
