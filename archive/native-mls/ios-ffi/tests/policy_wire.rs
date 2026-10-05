//! #275 L2 (a): 정책 메서드 4개(`members`·`members_after_pending`·`policy_fingerprint`·`sign_approval`)를
//! **FFI 객체**로 부른다. 바이트 규칙은 파사드 `policy_wire` — durable lane `Session::dispatch` 와 같은 함수 —
//! 가 소유하므로, 여기서는 relay-app(`web/relay-app.js`)이 그 바이트를 다루는 방식 그대로 검증한다.
//!
//! 승인 서명은 고정 벡터 `archive/native-mls/tests/fixtures/ios-ffi-approval-vector.json` 과 바이트 단위로
//! 비교하고, 같은 벡터를 Go 테스트(`server/cmd/native-devices/approval_vector_test.go`)가 실제
//! `-add-device` 경로로 수락하는지 검사한다(Ed25519 서명은 결정적이라 같은 기기 상태 → 같은 바이트).
//! 재생성: `FM_REGEN_APPROVAL_VECTOR=1 cargo +1.91.1 test --locked --test policy_wire`.
use family_mls_ios_ffi::{methods, MlsDevice, MlsError};

fn ok<T>(result: Result<T, MlsError>, what: &str) -> T {
    match result {
        Ok(value) => value,
        Err(err) => panic!("ffi rejected: {what}: {err}"),
    }
}

fn call(device: &MlsDevice, method: &str, input: &[u8]) -> Result<Vec<u8>, MlsError> {
    device.dispatch(method.to_owned(), input.to_vec())
}

fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

fn unhex(text: &str) -> Vec<u8> {
    assert!(text.len() % 2 == 0, "odd hex");
    (0..text.len()).step_by(2).map(|i| u8::from_str_radix(&text[i..i + 2], 16).expect("hex")).collect()
}

fn u32le(bytes: &[u8], at: usize) -> usize {
    u32::from_le_bytes(bytes[at..at + 4].try_into().unwrap()) as usize
}

/// relay-app `parseMembers` + 키: `u32le count`, 각 `u32le len ‖ identity ‖ 32B key`.
fn parse_members(framed: &[u8]) -> Vec<(String, Vec<u8>)> {
    let count = u32le(framed, 0);
    let mut at = 4;
    let mut out = Vec::new();
    for _ in 0..count {
        let n = u32le(framed, at);
        at += 4;
        let id = String::from_utf8(framed[at..at + n].to_vec()).expect("utf8 identity");
        at += n;
        out.push((id, framed[at..at + 32].to_vec()));
        at += 32;
    }
    assert_eq!(at, framed.len(), "no trailing bytes");
    out
}

/// relay-app `membersWire`: 정렬된 `{device, actor}` — 릴레이 outer 명단(server.go `memberWire`).
fn members_wire(devices: &[String]) -> Vec<(String, String)> {
    let mut sorted = devices.to_vec();
    sorted.sort();
    sorted.into_iter().map(|d| {
        let actor = d.split('-').next().unwrap().to_owned();
        (d, actor)
    }).collect()
}

/// relay-app 이 만드는 `sign_approval` 인자 JSON(키 순서 그대로).
fn approval_args(device_id: &str, actor: &str, subject: &str, signing_key: &str, base_revision: u64) -> Vec<u8> {
    format!(
        "{{\"action\":\"approve-device\",\"device_id\":\"{device_id}\",\"actor\":\"{actor}\",\"subject\":\"{subject}\",\
\"signing_key\":\"{signing_key}\",\"acceptance\":\"trusted-device-fingerprint\",\"base_revision\":{base_revision}}}"
    )
    .into_bytes()
}

/// `u32le n ‖ canonical ‖ 64B signature` → (canonical, signature).
fn split_evidence(framed: &[u8]) -> (Vec<u8>, Vec<u8>) {
    let n = u32le(framed, 0);
    assert_eq!(framed.len(), 4 + n + 64, "framed evidence = 4 + canonical + 64");
    (framed[4..4 + n].to_vec(), framed[4 + n..].to_vec())
}

#[test]
fn policy_methods_are_dispatchable() {
    let listed = methods();
    for m in ["members", "members_after_pending", "policy_fingerprint", "sign_approval"] {
        assert!(listed.iter().any(|x| x == m), "{m} is in METHODS");
    }
}

#[test]
fn roster_views_match_the_relay_outer_list_and_fingerprints() {
    let owner = ok(MlsDevice::new("owner-iphone".into()), "owner new");
    let peer = ok(MlsDevice::new("owner-pc".into()), "peer new");
    let third = ok(MlsDevice::new("kid-tablet".into()), "third new");

    ok(call(&owner, "create", &[]), "create");
    let solo = parse_members(&ok(call(&owner, "members", &[]), "members solo"));
    assert_eq!(solo, vec![("owner-iphone".to_owned(), ok(owner.public_key(), "pk"))]);

    let peer_kp = ok(call(&peer, "key_package", &[]), "peer kp");
    let welcome = ok(call(&owner, "invite", &peer_kp), "invite");
    ok(call(&peer, "join", &welcome), "join");

    // inner(엔진) == outer(릴레이 명단): 두 기기 모두 같은 명단을 보고, 키는 각 기기의 공개키다.
    let from_owner = parse_members(&ok(call(&owner, "members", &[]), "owner members"));
    let from_peer = parse_members(&ok(call(&peer, "members", &[]), "peer members"));
    assert_eq!(from_owner, from_peer, "both sides see the same roster");
    assert_eq!(from_owner, vec![
        ("owner-iphone".to_owned(), ok(owner.public_key(), "pk")),
        ("owner-pc".to_owned(), ok(peer.public_key(), "pk")),
    ]);
    let ids: Vec<String> = from_owner.iter().map(|(id, _)| id.clone()).collect();
    assert_eq!(members_wire(&ids), vec![
        ("owner-iphone".to_owned(), "owner".to_owned()),
        ("owner-pc".to_owned(), "owner".to_owned()),
    ]);

    // 대기 중 commit: members 는 그대로, members_after_pending 은 추가 후 명단(커밋 POST 의 outer 명단).
    let third_kp = ok(call(&third, "key_package", &[]), "third kp");
    ok(call(&owner, "invite_with_commit", &third_kp), "pending add");
    assert_eq!(parse_members(&ok(call(&owner, "members", &[]), "members while pending")), from_owner);
    let after: Vec<String> = parse_members(&ok(call(&owner, "members_after_pending", &[]), "after pending"))
        .into_iter().map(|(id, _)| id).collect();
    assert_eq!(after, vec!["kid-tablet", "owner-iphone", "owner-pc"]);
    ok(call(&owner, "clear_pending", &[]), "clear pending");

    // policy_fingerprint(후보 공개키 hex) == 그 기기의 지문(대역외 비교값, DEVICES-V4).
    for device in [&owner, &peer, &third] {
        let key_hex = hex(&ok(device.public_key(), "pk"));
        let fp = ok(call(&owner, "policy_fingerprint", key_hex.as_bytes()), "policy_fingerprint");
        assert_eq!(String::from_utf8(fp).unwrap(), ok(device.fingerprint(), "fingerprint"));
    }

    // 입력 규칙(durable lane 과 동일): 빈 입력 전용 메서드에 바이트, 대문자/짧은 hex → Rejected.
    let fp_before = ok(owner.fingerprint(), "fp");
    for (method, input) in [
        ("members", &b"x"[..]),
        ("members_after_pending", &b"x"[..]),
        ("policy_fingerprint", &b"AB"[..]),
        ("policy_fingerprint", "ab".repeat(32).to_uppercase().as_bytes()),
        ("policy_fingerprint", &[0xff, 0xfe][..]),
    ] {
        let err = call(&owner, method, input).expect_err("malformed input is rejected");
        assert!(matches!(err, MlsError::Rejected { .. }), "{method}: {err}");
    }
    assert_eq!(ok(owner.fingerprint(), "fp after"), fp_before);
    assert_eq!(parse_members(&ok(call(&owner, "members", &[]), "members after rejects")), from_owner);
}

#[test]
fn sign_approval_rejections_keep_the_device_usable() {
    let owner = ok(MlsDevice::new("owner-iphone".into()), "owner new");
    let candidate = ok(MlsDevice::new("owner-ipad".into()), "candidate new");
    let cand_key = hex(&ok(candidate.public_key(), "pk"));
    let own_key = hex(&ok(owner.public_key(), "pk"));
    let bad: Vec<Vec<u8>> = vec![
        b"not json".to_vec(),
        // 모르는 필드 — relay-app 이 증거 JSON 에 덧붙이는 `fingerprint` 를 서명 인자에 섞으면 거부.
        format!("{{\"action\":\"approve-device\",\"device_id\":\"owner-ipad\",\"actor\":\"owner\",\"subject\":\"person-owner\",\
\"signing_key\":\"{cand_key}\",\"acceptance\":\"trusted-device-fingerprint\",\"base_revision\":2,\"fingerprint\":\"x\"}}").into_bytes(),
        // 필드 누락
        b"{\"action\":\"approve-device\"}".to_vec(),
        // approve-device 는 trusted 수용만
        String::from_utf8(approval_args("owner-ipad", "owner", "person-owner", &cand_key, 2)).unwrap()
            .replace("trusted-device-fingerprint", "out-of-band").into_bytes(),
        approval_args("owner-ipad", "owner", "person-owner", &cand_key, 0), // base_revision ≥ 1
        approval_args("owner-ipad", "owner", "person-owner", &own_key, 2),  // 자기 승인
        approval_args("owner ipad", "owner", "person-owner", &cand_key, 2), // 식별자 문자집합
    ];
    for input in &bad {
        let err = call(&owner, "sign_approval", input).expect_err("malformed approval is rejected");
        assert!(matches!(err, MlsError::Rejected { .. }), "{err}");
    }
    let framed = ok(call(&owner, "sign_approval", &approval_args("owner-ipad", "owner", "person-owner", &cand_key, 2)),
                    "valid approval after rejections");
    let (canonical, signature) = split_evidence(&framed);
    assert_eq!(signature.len(), 64);
    let canonical = String::from_utf8(canonical).unwrap();
    assert!(canonical.contains("\"signing_key\":\"") && canonical.contains(&cand_key), "canonical pins the candidate key");
}

const VECTOR: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/../tests/fixtures/ios-ffi-approval-vector.json");

/// 평평한 JSON(한 줄에 `"key": value` 하나)만 읽는다 — 이 벡터는 이 테스트가 그 모양으로 쓴다.
fn field(text: &str, key: &str) -> String {
    let prefix = format!("\"{key}\":");
    for line in text.lines() {
        let line = line.trim().trim_end_matches(',');
        if let Some(rest) = line.strip_prefix(&prefix) {
            return rest.trim().trim_matches('"').to_owned();
        }
    }
    panic!("vector field {key} missing")
}

#[test]
fn sign_approval_matches_the_go_accepted_vector() {
    const APPROVER: &str = "owner-iphone";
    const CANDIDATE: &str = "owner-ipad";
    const ACTOR: &str = "owner";
    const SUBJECT: &str = "person-owner";
    // native-devices: -init → rev 1, approver -enroll-first → rev 2, 그 위의 -add-device.
    const BASE_REVISION: u64 = 2;

    if std::env::var_os("FM_REGEN_APPROVAL_VECTOR").is_some() {
        let approver = ok(MlsDevice::new(APPROVER.into()), "approver new");
        let candidate = ok(MlsDevice::new(CANDIDATE.into()), "candidate new");
        let cand_key = hex(&ok(candidate.public_key(), "pk"));
        let state = ok(approver.export_state(), "export");
        let framed = ok(call(&approver, "sign_approval", &approval_args(CANDIDATE, ACTOR, SUBJECT, &cand_key, BASE_REVISION)),
                        "sign");
        let (canonical, signature) = split_evidence(&framed);
        let text = format!(
            "{{\n\"about\": \"SYNTHETIC test vector, never enrolled anywhere. Generated by archive/native-mls/ios-ffi/tests/policy_wire.rs (FM_REGEN_APPROVAL_VECTOR=1). approver_state_hex is a throwaway facade export_state (includes its private signing key) so the Ed25519 signature is reproducible byte-for-byte; the Go test feeds the same evidence to native-devices -add-device.\",\n\
\"approver_identity\": \"{APPROVER}\",\n\"approver_state_hex\": \"{}\",\n\"approver_public_hex\": \"{}\",\n\"approver_fingerprint\": \"{}\",\n\
\"actor\": \"{ACTOR}\",\n\"subject\": \"{SUBJECT}\",\n\"candidate_device_id\": \"{CANDIDATE}\",\n\"candidate_public_hex\": \"{cand_key}\",\n\
\"candidate_fingerprint\": \"{}\",\n\"base_revision\": {BASE_REVISION},\n\"canonical_hex\": \"{}\",\n\"signature_hex\": \"{}\",\n\"framed_hex\": \"{}\"\n}}\n",
            hex(&state), hex(&ok(approver.public_key(), "pk")), ok(approver.fingerprint(), "fp"),
            ok(candidate.fingerprint(), "fp"), hex(&canonical), hex(&signature), hex(&framed),
        );
        std::fs::write(VECTOR, text).expect("write vector");
    }

    let text = std::fs::read_to_string(VECTOR).expect("read vector");
    assert_eq!(field(&text, "approver_identity"), APPROVER);
    assert_eq!(field(&text, "base_revision"), BASE_REVISION.to_string());
    let approver = ok(MlsDevice::import_state(APPROVER.into(), unhex(&field(&text, "approver_state_hex"))), "import approver");
    assert_eq!(hex(&ok(approver.public_key(), "pk")), field(&text, "approver_public_hex"));
    assert_eq!(ok(approver.fingerprint(), "fp"), field(&text, "approver_fingerprint"));

    let cand_key = field(&text, "candidate_public_hex");
    let fp = ok(call(&approver, "policy_fingerprint", cand_key.as_bytes()), "policy_fingerprint");
    assert_eq!(String::from_utf8(fp).unwrap(), field(&text, "candidate_fingerprint"));

    let framed = ok(call(&approver, "sign_approval",
                         &approval_args(&field(&text, "candidate_device_id"), &field(&text, "actor"),
                                        &field(&text, "subject"), &cand_key, BASE_REVISION)), "sign");
    assert_eq!(hex(&framed), field(&text, "framed_hex"), "ios-ffi output is byte-identical to the Go-accepted vector");
    let (canonical, signature) = split_evidence(&framed);
    assert_eq!(hex(&canonical), field(&text, "canonical_hex"));
    // relay-app 과 같은 추출: 증거 JSON 의 `signature` = 뒤 64바이트의 lowercase hex.
    assert_eq!(hex(&signature), field(&text, "signature_hex"));
}
