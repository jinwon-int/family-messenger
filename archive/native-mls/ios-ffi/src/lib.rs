//! iOS 호스트 FFI (#271 §3). 브라우저 파사드 `Device` 를 Swift 객체 하나로 노출한다.
//!
//! 표면은 durable-worker(`web/durable-worker.js` `allowed`)·봇(`bot/src/session.rs`)과 같은
//! **`dispatch(method, bytes) → bytes`** 다. 여기엔 MLS 로직이 없다: 와이어 프레이밍(encrypt
//! `u32le len‖room‖u32le len‖client_id‖plaintext` 등)은 호스트가 만들고, AAD·commit 검사·record 코덱은
//! 파사드 안에 있다.
//!
//! 실패 계약은 봇과 동일: 연산 전에 `export_state` 스냅샷을 뜨고, 파사드가 거부하면 기기 객체를
//! 스냅샷으로 되돌린다(파사드는 오류 시 기기를 퇴역시키므로). 영속은 호스트 책임이다 —
//! `export_state` 바이트를 원자적으로(tmp→fsync→rename) 쓰고, App↔NSE 는 flock 으로 직렬화한다(#271 §4).
//! 이 크레이트는 디스크·키체인·네트워크를 모른다.
use std::sync::Mutex;

use family_mls_browser_experiment::{Device, DECRYPT_FORMAT};
use sha2::{Digest, Sha256};

uniffi::setup_scaffolding!();

#[derive(Debug, uniffi::Error)]
pub enum MlsError {
    /// 파사드가 거부했다(사유는 파사드의 고정 문자열; 키·평문은 절대 담기지 않는다).
    Rejected { reason: String },
    /// 호스트 측 전제 위반(알 수 없는 메서드, 잠금 오염 등).
    Invalid { reason: String },
}

impl std::fmt::Display for MlsError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            MlsError::Rejected { reason } => write!(f, "rejected: {reason}"),
            MlsError::Invalid { reason } => write!(f, "invalid: {reason}"),
        }
    }
}

fn rejected(e: family_mls_browser_experiment::Rejected) -> MlsError {
    // `Rejected(&'static str)` 의 필드는 비공개 — Debug 표현("Rejected(\"...\")")에서 사유만 추린다.
    let text = format!("{e:?}");
    let reason = text.trim_start_matches("Rejected(\"").trim_end_matches("\")").to_owned();
    MlsError::Rejected { reason }
}

/// 한 기기 = 파사드 `Device` 하나. 메서드는 모두 `&self` 이고 내부 Mutex 로 직렬화된다(uniffi Object 는 Send+Sync 필요).
#[derive(uniffi::Object)]
pub struct MlsDevice {
    identity: String,
    inner: Mutex<Option<Device>>,
}

/// `dispatch` 가 받는 메서드 이름 — durable-worker `allowed` 중 `Device` 수준의 것.
/// `members`·`fingerprint(정책)`·`policy_fingerprint`·`sign_approval` 은 파사드의 비공개 `Session`(durable lane)에
/// 있어 이 스파이크에서는 노출하지 않는다(README "증명하지 않은 것").
pub const METHODS: &[&str] = &[
    "key_package", "delete_key_package", "create", "invite", "invite_with_commit", "join", "encrypt", "decrypt",
    "remove", "remove_pending", "commit", "merge_pending", "clear_pending", "stage_commit", "merge_staged",
    "discard_staged",
];

#[uniffi::export]
impl MlsDevice {
    /// 새 신원(서명키는 파사드 안에서 생성·보관). `identity` = `actor-device` 모양의 식별자(파사드가 검증).
    #[uniffi::constructor]
    pub fn new(identity: String) -> Result<std::sync::Arc<Self>, MlsError> {
        let device = Device::new(&identity).map_err(rejected)?;
        Ok(std::sync::Arc::new(Self { identity, inner: Mutex::new(Some(device)) }))
    }

    /// `export_state` 바이트로 복원. 다른 identity 의 상태는 파사드가 거부한다.
    #[uniffi::constructor]
    pub fn import_state(identity: String, bytes: Vec<u8>) -> Result<std::sync::Arc<Self>, MlsError> {
        let device = Device::import_state(&identity, &bytes).map_err(rejected)?;
        Ok(std::sync::Arc::new(Self { identity, inner: Mutex::new(Some(device)) }))
    }

    pub fn identity(&self) -> String {
        self.identity.clone()
    }

    /// 전체 상태 스냅샷(봉인은 호스트 몫 — #271 §4: Keychain 키 + secretstream + Data Protection).
    pub fn export_state(&self) -> Result<Vec<u8>, MlsError> {
        self.with(|d| d.export_state(&self.identity).map_err(rejected))
    }

    /// Ed25519 서명 공개키 원본 바이트(등록 JSON 의 `signing_key` = 이것의 lowercase hex).
    pub fn public_key(&self) -> Result<Vec<u8>, MlsError> {
        self.with(|d| d.public_key().map_err(rejected))
    }

    /// 지문 = sha256(공개키 원본 바이트) lowercase hex — DEVICES-V4 와 동일. 사람이 대역외로 비교하는 값.
    pub fn fingerprint(&self) -> Result<String, MlsError> {
        let key = self.public_key()?;
        Ok(hex(&Sha256::digest(key)))
    }

    pub fn has_pending(&self) -> Result<bool, MlsError> {
        self.with(|d| Ok(d.has_pending()))
    }

    pub fn key_packages_outstanding(&self) -> Result<u32, MlsError> {
        self.with(|d| Ok(d.key_packages_outstanding()))
    }

    /// 워커·봇과 같은 단일 진입점. 실패 시 기기 객체는 연산 전 스냅샷으로 되돌아간다.
    pub fn dispatch(&self, method: String, input: Vec<u8>) -> Result<Vec<u8>, MlsError> {
        if !METHODS.contains(&method.as_str()) {
            return Err(MlsError::Invalid { reason: format!("unknown method {method}") });
        }
        let mut guard = self.inner.lock().map_err(|_| MlsError::Invalid { reason: "device lock poisoned".into() })?;
        let mut device = guard.take().ok_or_else(|| MlsError::Invalid { reason: "device missing".into() })?;
        let snapshot = device.export_state(&self.identity).map_err(rejected);
        let result = run(&mut device, &method, &input);
        match result {
            Ok(output) => {
                *guard = Some(device);
                Ok(output)
            }
            Err(err) => {
                // 봇 session.rs 와 같은 롤백: 거부된 연산의 변이(퇴역 포함)를 버리고 스냅샷으로 복원.
                let restored = snapshot.and_then(|bytes| Device::import_state(&self.identity, &bytes).map_err(rejected));
                *guard = Some(restored.unwrap_or(device));
                Err(err)
            }
        }
    }
}

impl MlsDevice {
    fn with<T>(&self, f: impl FnOnce(&mut Device) -> Result<T, MlsError>) -> Result<T, MlsError> {
        let mut guard = self.inner.lock().map_err(|_| MlsError::Invalid { reason: "device lock poisoned".into() })?;
        let device = guard.as_mut().ok_or_else(|| MlsError::Invalid { reason: "device missing".into() })?;
        f(device)
    }
}

fn run(device: &mut Device, method: &str, input: &[u8]) -> Result<Vec<u8>, MlsError> {
    let unit = |r: Result<(), family_mls_browser_experiment::Rejected>| r.map(|()| Vec::new()).map_err(rejected);
    match method {
        "key_package" => device.key_package().map_err(rejected),
        "delete_key_package" => unit(device.delete_key_package(input)),
        "create" => unit(device.create()),
        "invite" => device.invite(input).map_err(rejected),
        "invite_with_commit" => device.invite_with_commit(input).map_err(rejected),
        "join" => unit(device.join(input)),
        "encrypt" => device.encrypt(input).map_err(rejected),
        "decrypt" => device.decrypt(input).map_err(rejected),
        "remove" => device.remove_member(input).map_err(rejected),
        "remove_pending" => device.remove_member_pending(input).map_err(rejected),
        "commit" => unit(device.apply_commit(input)),
        "merge_pending" => unit(device.merge_pending()),
        "clear_pending" => unit(device.clear_pending()),
        "stage_commit" => device.stage_commit(input).map_err(rejected),
        "merge_staged" => unit(device.merge_staged()),
        "discard_staged" => unit(device.discard_staged()),
        other => Err(MlsError::Invalid { reason: format!("unknown method {other}") }),
    }
}

/// `decrypt` 출력 프레이밍 버전(호스트 파서가 핀할 값).
#[uniffi::export]
pub fn decrypt_format() -> u32 {
    DECRYPT_FORMAT
}

/// `stage_commit` 보고서 프레이밍 버전.
#[uniffi::export]
pub fn stage_report_format() -> u32 {
    Device::stage_report_format()
}

/// 노출하는 dispatch 메서드 목록(호스트 테스트·문서 동기화용).
#[uniffi::export]
pub fn methods() -> Vec<String> {
    METHODS.iter().map(|m| (*m).to_owned()).collect()
}

fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}
