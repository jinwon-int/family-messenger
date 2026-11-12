// file-v2 분리 첨부 수신(#499, 정본 `archive/native-mls/FILE-V2.md`) — 설명자 검증과 수신 메시지 분류.
// #366 3e: 판정은 공용 Rust 코어(host-core `file_v2`)가 한다 — uniffi `fileV2Check` · `fileV2Classify`(봇과 같은 코드, iOS 와 같은 판정).
// 이 파일은 그 결과를 이 앱의 저장 행(kind · body · attachment)으로 옮기는 얇은 층이다. 공유 벡터:
// `archive/native-mls/tests/fixtures/file-v2-vectors.json`(`FileV2VectorsTest`). JVM 단위 테스트는 호스트 cdylib 을 JNA 로 싣는다
// (`<ffiOut>/host`, ios-ffi/build-android.sh — app/build.gradle.kts 참고).
//
// 바깥 client_id 가 `file-v2-` 로 시작하는 메시지의 평문은 파일을 열 **키**가 든 설명자 JSON 이다. 그래서 이 메시지는 어떤 경우에도
// 글(text)로 저장하거나 보이지 않는다: 설명자가 올바르면 `file-v2` 행(본문 = 자리 표시, 설명자는 attachment 칸), 아니면
// `undecryptable` 행(평문 버림). 파일 바이트를 받아 여는 일(blob GET → `fileV2Open`)은 v1 첨부 미리보기와 함께 C 단계에서 한다.
package com.seoyoon_family.hande.core

import com.seoyoon_family.hande.mls.MlsException
import com.seoyoon_family.hande.mls.MlsFileV2Kind
import com.seoyoon_family.hande.mls.fileV2Check
import com.seoyoon_family.hande.mls.fileV2Classify
import com.seoyoon_family.hande.ui.Strings

object FileV2 {
    const val MAX_FILE_BYTES = 50L * 1024 * 1024 // #499 오너 결정 (코어 `MAX_FILE_V2` 와 같은 값)
    const val MAX_DESCRIPTOR_BYTES = 4096
    const val CLIENT_PREFIX = "file-v2-"
    /** status-v1(#560, `archive/native-mls/STATUS-V1.md`): 에이전트의 작업 상태 한 줄. 저장하지 않는다(임시 말풍선 전용). */
    const val STATUS_CLIENT_PREFIX = "status-"

    /** 검증한 설명자의 공개 부분. 키·nonce 는 코어 밖으로 나오지 않는다(열기는 설명자 바이트째 코어에 넘긴다). */
    class Descriptor(
        val blob: String,
        val size: Long,
        val mime: String?,
        val name: String?,
        val w: Long?,
        val h: Long?,
    ) {
        override fun toString() = "FileV2.Descriptor(blob=${blob.take(12)}…, size=$size)"
    }

    /** 거부 이유는 코어의 고정된 짧은 코드뿐이다(보낸 쪽 값·키 이름을 담지 않는다 — 로그에 그대로 남겨도 된다). */
    class Rejected(val reason: String) : Exception("file-v2 descriptor rejected: $reason")

    /** `status-<uuid>`(정규형)인가. 정규형이 아닌 `status-…` 는 그냥 글이다(모르는 접두사 = 글, 다른 앱과 같다). */
    fun isStatusClientId(clientId: String): Boolean = fileV2Classify(clientId, ByteArray(0)) == MlsFileV2Kind.Status

    /** MLS 평문(UTF-8 바이트)을 설명자로 엄격 검증한다. 하나라도 어긋나면 [Rejected]. */
    fun parseDescriptor(plaintext: ByteArray): Descriptor {
        val info = try {
            fileV2Check(plaintext)
        } catch (e: MlsException) {
            throw Rejected((e as? MlsException.Rejected)?.reason ?: "invalid")
        }
        return Descriptor(info.blob, info.size.toLong(), info.mime, info.name, info.w?.toLong(), info.h?.toLong())
    }

    // ---- 수신 분류 ----

    /** `messages` 표에 넣을 한 행의 kind · body · attachment. */
    class Row(val kind: String, val body: String, val attachment: ByteArray?)

    /**
     * 복호화한 application 메시지 하나를 저장 행으로 바꾼다(DeviceHub `onMessage`). 판정은 코어 `fileV2Classify`.
     * - `file-v1-…` → 첨부(평문 = 파일 바이트, 기존 동작).
     * - `file-v2-<uuid>` + 올바른 설명자 → `file-v2`(body 는 자리 표시, attachment = 설명자 바이트 — 이력에는 설명자만, §4-2).
     * - 설명자가 틀리거나 client_id 가 `file-v2-` 로 시작하지만 정규형이 아님 → `undecryptable`(평문은 저장하지 않는다 — 키가 있을 수 있다).
     * - `status-<uuid>` → **null**(저장하지 않는다 — 이력·안 읽음·미리보기에 들어가면 안 되는 임시 글, #560).
     * - 그 밖 → 글.
     */
    fun classify(clientId: String, plaintext: ByteArray): Row? = when (val kind = fileV2Classify(clientId, plaintext)) {
        MlsFileV2Kind.Status -> null
        MlsFileV2Kind.FileV1 -> Row(MessageSchema.KIND_ATTACHMENT, Strings.attachmentPlaceholder(plaintext.size.toLong()), plaintext)
        is MlsFileV2Kind.FileV2 -> Row(MessageSchema.KIND_FILE_V2, Strings.attachmentPlaceholder(kind.size.toLong()), plaintext.copyOf())
        MlsFileV2Kind.Undecryptable -> Row(MessageSchema.KIND_UNDECRYPTABLE, Strings.fileV2Invalid, null)
        MlsFileV2Kind.Text -> Row(MessageSchema.KIND_TEXT, String(plaintext, Charsets.UTF_8), null)
    }
}
