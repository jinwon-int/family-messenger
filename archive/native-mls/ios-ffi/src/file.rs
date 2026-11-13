//! #366 3d: file-v2 첨부 규칙(`FILE-V2.md`)을 uniffi 로 노출한다 — 구현은 host-core `file_v2`(봇과 같은 코드).
//!
//! - 설명자 검증 `file_v2_check` · 수신 분류 `file_v2_classify` · 열기 `file_v2_open` · 봉인 `file_v2_seal` · 내용 판별 `file_v2_sniff`.
//! - **키·nonce 는 FFI 경계를 넘지 않는다**: 검증 결과([`MlsFileV2Info`])에는 키가 없고, 열기·봉인은 설명자 **바이트**를 그대로 주고받는다
//!   (호스트는 그 바이트를 지금처럼 이력의 attachment 칸에 둔다 — FILE-V2 §4-2).
//! - 거부 사유는 host-core 의 고정 코드(`too large` · `missing blob` · `integrity` …)다. 보낸 쪽 값이나 키를 담지 않으므로 로그에 남겨도 된다.
//! - uniffi 레코드는 iOS 코어 타입과 겹치지 않게 `Mls` 접두(3c 와 같은 규칙).
use native_mls_host::file_v2 as core;

use crate::MlsError;

fn refused(reason: &'static str) -> MlsError {
    MlsError::Rejected { reason: reason.to_owned() }
}

/// 검증한 설명자의 공개 부분(키·nonce 제외).
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct MlsFileV2Info {
    pub blob: String,
    pub size: u64,
    pub mime: Option<String>,
    pub name: Option<String>,
    pub w: Option<u64>,
    pub h: Option<u64>,
}

/// 복호화한 application 메시지 하나를 어떻게 저장할지(FILE-V2 §4.1 · STATUS-V1).
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Enum)]
pub enum MlsFileV2Kind {
    /// `status-<uuid>` — 임시 작업 상태 줄, 저장하지 않는다.
    Status,
    /// `file-v1-<uuid>` — 평문이 파일 자체(비정규 id 는 `Text`, #366 3f).
    FileV1,
    /// 올바른 설명자를 가진 `file-v2-<uuid>`.
    FileV2 { size: u64 },
    /// 정규형이 아니거나 설명자가 틀린 `file-v2-…` — 어떤 경우에도 글로 보이지 않는다.
    Undecryptable,
    /// 그 밖 — 글.
    Text,
}

/// 봉인 결과: 올릴 암호문 · 게시할 설명자 바이트(파일 키 포함 — 로그 금지) · blob id(= sha256(암호문)).
#[derive(Clone, uniffi::Record)]
pub struct MlsFileV2Sealed {
    pub ciphertext: Vec<u8>,
    pub descriptor: Vec<u8>,
    pub blob: String,
}

impl std::fmt::Debug for MlsFileV2Sealed {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("MlsFileV2Sealed").field("ciphertext_len", &self.ciphertext.len()).finish_non_exhaustive()
    }
}

/// 내용(매직 바이트)으로 정한 MIME 과 종류(`image`/`file`). 설명자의 `mime` 힌트는 믿지 않는다(FILE-V2 §4.4).
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct MlsFileV2Sniff {
    pub mime: String,
    pub kind: String,
}

/// FILE-V2 §1 엄격 검증. 실패면 `Rejected { reason }`.
#[uniffi::export]
pub fn file_v2_check(descriptor: Vec<u8>) -> Result<MlsFileV2Info, MlsError> {
    let d = core::parse_descriptor(&descriptor).map_err(refused)?;
    Ok(MlsFileV2Info { blob: d.blob.clone(), size: d.size, mime: d.mime.clone(), name: d.name.clone(), w: d.w, h: d.h })
}

/// 바깥 client_id 와 MLS 평문으로 저장 종류를 정한다(Android `FileV2.classify` 와 같은 판정).
#[uniffi::export]
pub fn file_v2_classify(client_id: String, plaintext: Vec<u8>) -> MlsFileV2Kind {
    match core::classify(&client_id, &plaintext) {
        core::Classified::Status => MlsFileV2Kind::Status,
        core::Classified::FileV1 => MlsFileV2Kind::FileV1,
        core::Classified::FileV2 { size } => MlsFileV2Kind::FileV2 { size },
        core::Classified::Undecryptable => MlsFileV2Kind::Undecryptable,
        core::Classified::Text => MlsFileV2Kind::Text,
    }
}

/// FILE-V2 §4.3: 설명자 바이트 + 받은 암호문 → 평문. 설명자가 틀리면 그 사유, 길이·해시·GCM 이 어긋나면 `integrity`.
#[uniffi::export]
pub fn file_v2_open(descriptor: Vec<u8>, ciphertext: Vec<u8>) -> Result<Vec<u8>, MlsError> {
    let d = core::parse_descriptor(&descriptor).map_err(refused)?;
    let plaintext = core::open(&ciphertext, &d).map_err(refused)?;
    Ok(plaintext.to_vec())
}

/// FILE-V2 §2/§3: 새 무작위 키·nonce 로 봉인한다. `mime` 은 [`file_v2_sniff`] 결과를 넘긴다.
/// 실패: `size`(1 ~ 50 MiB 밖) · `mime` · `name` · `too large`(설명자 > 4 KiB) · `random` · `crypto`.
#[uniffi::export]
pub fn file_v2_seal(plaintext: Vec<u8>, mime: String, name: Option<String>) -> Result<MlsFileV2Sealed, MlsError> {
    let sealed = core::seal(&plaintext, &mime, name.as_deref()).map_err(refused)?;
    Ok(MlsFileV2Sealed { ciphertext: sealed.ciphertext.clone(), descriptor: sealed.descriptor.to_vec(), blob: sealed.blob.clone() })
}

/// 내용으로 MIME·종류를 정한다.
#[uniffi::export]
pub fn file_v2_sniff(bytes: Vec<u8>) -> MlsFileV2Sniff {
    let mime = core::sniff_mime(&bytes);
    MlsFileV2Sniff { mime: mime.to_owned(), kind: core::kind_for(mime).to_owned() }
}

/// 첨부 크기 상한(#366 3f) — 호스트는 자기 상수를 이 값과 같게 둔다(Android `FileV2VectorsTest` 가 고정).
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct MlsAttachmentLimits {
    /// file-v1 평문 상한 5 MiB(#364 결정 B, 보내는 쪽 기준).
    pub file_v1_max_bytes: u64,
    /// file-v2 평문 상한 50 MiB(#499).
    pub file_v2_max_bytes: u64,
    /// file-v2 설명자(MLS 평문) 상한 4 KiB.
    pub descriptor_max_bytes: u64,
}

/// host-core 의 첨부 크기 상한.
#[uniffi::export]
pub fn attachment_limits() -> MlsAttachmentLimits {
    MlsAttachmentLimits {
        file_v1_max_bytes: core::MAX_FILE_V1,
        file_v2_max_bytes: core::MAX_FILE_V2,
        descriptor_max_bytes: core::MAX_DESCRIPTOR_BYTES as u64,
    }
}

/// client_id 만으로 첨부(`file-v1-<uuid>` · `file-v2-<uuid>`)인지 — 웹·iOS·봇과 같은 엄격 규칙(#366 3f).
#[uniffi::export]
pub fn is_attachment_client_id(client_id: String) -> bool {
    core::is_attachment_client_id(&client_id)
}

/// 저장·표시 이름 규칙: 양방향 제어 문자가 든 이름은 쓰지 않는다(`null`).
#[uniffi::export]
pub fn file_v2_display_name(name: String) -> Option<String> {
    core::display_name(Some(&name))
}
