//! #366 3d: file-v2 FFI 표면이 공유 벡터 `archive/native-mls/tests/fixtures/file-v2-vectors.json` 을 host-core 와 같게 판정하는지,
//! 그리고 봉인 → 열기가 FFI 바이트만으로 왕복하는지 본다(Kotlin 은 같은 함수를 JNA 로 부른다 — android `jvm-roundtrip.sh` ⑧).
use family_mls_ios_ffi::{
    attachment_limits, file_v2_check, file_v2_classify, file_v2_display_name, file_v2_open, file_v2_seal, file_v2_sniff,
    is_attachment_client_id, MlsAttachmentLimits, MlsError, MlsFileV2Kind,
};
use serde_json::Value;

fn unhex(text: &str) -> Vec<u8> {
    (0..text.len()).step_by(2).map(|i| u8::from_str_radix(&text[i..i + 2], 16).expect("hex")).collect()
}

fn reason(err: MlsError) -> String {
    match err {
        MlsError::Rejected { reason } | MlsError::Invalid { reason } => reason,
    }
}

fn vectors() -> Value {
    let path = concat!(env!("CARGO_MANIFEST_DIR"), "/../tests/fixtures/file-v2-vectors.json");
    serde_json::from_str(&std::fs::read_to_string(path).expect("vectors")).expect("json")
}

#[test]
fn descriptors_match_the_shared_vectors() {
    let doc = vectors();
    let cases = doc["descriptors"].as_array().unwrap();
    assert!(cases.len() >= 50);
    for case in cases {
        let name = case["name"].as_str().unwrap();
        let bytes = match case["hex"].as_str() {
            Some(hex) => unhex(hex),
            None => case["text"].as_str().unwrap().as_bytes().to_vec(),
        };
        let got = file_v2_check(bytes);
        match case["expect"].as_str().unwrap() {
            "accept" => assert_eq!(got.unwrap_or_else(|e| panic!("{name}: {}", reason(e))).size, case["size"].as_u64().unwrap(), "{name}"),
            _ => {
                let err = reason(got.err().unwrap_or_else(|| panic!("{name}: accepted")));
                if let Some(want) = case["reason"].as_str() {
                    assert_eq!(err, want, "{name}");
                }
            }
        }
    }
}

#[test]
fn classify_matches_the_shared_vectors() {
    let doc = vectors();
    for case in doc["classify"].as_array().unwrap() {
        let name = case["name"].as_str().unwrap();
        let got = file_v2_classify(case["client_id"].as_str().unwrap().into(), case["plaintext"].as_str().unwrap().as_bytes().to_vec());
        let want = match case["kind"].as_str().unwrap() {
            "status" => MlsFileV2Kind::Status,
            "file-v1" => MlsFileV2Kind::FileV1,
            "file-v2" => MlsFileV2Kind::FileV2 { size: case["size"].as_u64().unwrap() },
            "undecryptable" => MlsFileV2Kind::Undecryptable,
            _ => MlsFileV2Kind::Text,
        };
        assert_eq!(got, want, "{name}");
        let attachment = case["attachment"].as_bool().unwrap();
        assert_eq!(is_attachment_client_id(case["client_id"].as_str().unwrap().into()), attachment, "{name}: attachment id");
    }
}

/// #366 3f: 크기 상한은 코어 한 곳 — Android `FileV2VectorsTest.limitsMatchCore` 가 앱 상수를 이 값에 묶는다.
#[test]
fn attachment_limits_are_the_core_constants() {
    assert_eq!(
        attachment_limits(),
        MlsAttachmentLimits { file_v1_max_bytes: 5 * 1024 * 1024, file_v2_max_bytes: 50 * 1024 * 1024, descriptor_max_bytes: 4096 }
    );
}

#[test]
fn opens_the_web_vector_and_round_trips_a_seal() {
    let doc = vectors();
    let ct = &doc["ciphertext"];
    let descriptor = ct["descriptor"].as_str().unwrap().as_bytes().to_vec();
    let info = file_v2_check(descriptor.clone()).unwrap();
    assert_eq!((info.size, info.mime.as_deref(), info.name.as_deref()), (29, Some("image/png"), Some("사진.png")));
    let plain = file_v2_open(descriptor.clone(), unhex(ct["ciphertext_hex"].as_str().unwrap())).unwrap();
    assert_eq!(plain, unhex(ct["plaintext_hex"].as_str().unwrap()));
    let mut tampered = unhex(ct["ciphertext_hex"].as_str().unwrap());
    tampered[0] ^= 1;
    assert_eq!(reason(file_v2_open(descriptor, tampered).unwrap_err()), "integrity");

    let sniff = file_v2_sniff(plain.clone());
    assert_eq!((sniff.mime.as_str(), sniff.kind.as_str()), ("image/png", "image"));
    let sealed = file_v2_seal(plain.clone(), sniff.mime, Some("사진.png".into())).unwrap();
    assert!(!format!("{sealed:?}").contains("key"));
    assert_eq!(file_v2_check(sealed.descriptor.clone()).unwrap().blob, sealed.blob);
    assert_eq!(file_v2_open(sealed.descriptor, sealed.ciphertext).unwrap(), plain);
    assert_eq!(reason(file_v2_seal(Vec::new(), "text/plain".into(), None).unwrap_err()), "size");
    assert_eq!(file_v2_display_name("photo\u{202e}gpj.exe".into()), None);
    assert_eq!(file_v2_display_name("사진.jpg".into()).as_deref(), Some("사진.jpg"));
}
