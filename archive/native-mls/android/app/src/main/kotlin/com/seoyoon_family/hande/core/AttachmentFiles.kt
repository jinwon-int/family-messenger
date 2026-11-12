// 첨부 열기·보내기(#366 C · #338 C 단계)의 순수 규칙 — 저장·공유 이름, MIME → 확장자, 보낼 이름, 보낼 크기. android.* 없이 JVM 에서 돈다
// (`AttachmentFilesTest`). 파일 바이트를 다루는 일(선택한 파일 읽기 · 임시 공유 파일 · 이미지 디코딩)은 `ui/AttachmentIo.kt`.
package com.seoyoon_family.hande.core

import com.seoyoon_family.hande.mls.fileV2DisplayName

object AttachmentFiles {
    /** 첨부 열기의 결과(`DeviceHub.openAttachment`). */
    sealed interface OpenResult

    /** 받은 첨부 하나를 연 결과 — 이력에 저장하지 않는 평문(FILE-V2 §4-2). `kind` = `image`/`file`(내용으로 정한 `mime` 기준). */
    class Opened(val bytes: ByteArray, val mime: String, val kind: String, val name: String) : OpenResult {
        override fun toString() = "Opened($mime, ${bytes.size} B)"
    }

    /** 첨부 열기 실패 — 화면에 보일 문구와, 다시 눌러 볼 만한지(전송 실패·손상은 참, 사라진 blob·틀린 설명자는 거짓). */
    class OpenFailed(val message: String, val retry: Boolean) : OpenResult

    /** 릴레이가 크기 한도로 거절한 업로드(413 `blob_too_large` · `room_bytes_cap` · `device_bytes_cap`, blobs.go)인가 — 오류 문구로 판정. */
    fun isSizeRefusal(reason: String): Boolean =
        listOf("blob_too_large", "room_bytes_cap", "device_bytes_cap").any { it in reason }

    /** 보낼 수 있는 가장 큰 파일 — FILE-V2 §1 `size` 상한(50 MiB, #499 오너 결정). 릴레이 한도(413)는 보내 봐야 안다. */
    const val MAX_SEND_BYTES: Long = FileV2.MAX_FILE_BYTES

    /** 내용으로 정한 MIME → 저장·공유 파일 확장자(코어 `sniff_mime` 이 내는 값들). 모르면 `.bin`. */
    fun extensionFor(mime: String): String = when (mime) {
        "image/jpeg" -> ".jpg"
        "image/png" -> ".png"
        "image/gif" -> ".gif"
        "image/webp" -> ".webp"
        "image/heic" -> ".heic"
        "image/heif" -> ".heif"
        "image/bmp" -> ".bmp"
        "image/tiff" -> ".tif"
        "application/pdf" -> ".pdf"
        "application/zip" -> ".zip"
        "text/plain" -> ".txt"
        else -> ".bin"
    }

    /** 마지막 경로 조각 · 앞뒤 공백 제거 · 1~255 코드 포인트 · 제어 문자(U+0000–001F, U+007F–009F) 없음 · `.`/`..` 아님. 아니면 null. */
    private fun lastSegment(name: String?): String? {
        val last = name?.substringAfterLast('/')?.substringAfterLast('\\')?.trim() ?: return null
        if (last.isEmpty() || last == "." || last == "..") return null
        if (last.codePointCount(0, last.length) > 255) return null
        if (last.any { it <= '\u001f' || it in '\u007f'..'\u009f' }) return null
        return last
    }

    /**
     * 임시 공유 파일 이름(받은 첨부 열기). 보낸 이름을 쓰되 양방향 제어 문자가 든 이름은 쓰지 않는다(확장자 위장 — 코어
     * `fileV2DisplayName`, 웹 `safeFileName` 과 같은 규칙). 못 쓰면 「첨부」+ 내용으로 정한 확장자.
     */
    fun safeName(name: String?, mime: String): String =
        lastSegment(name)?.let { fileV2DisplayName(it) } ?: ("첨부" + extensionFor(mime))

    /** 보낼 때 설명자 `name`: 마지막 경로 조각이 규칙에 맞으면 그것, 아니면 이름 없이 보낸다(null — 받는 쪽이 「첨부.확장자」). */
    fun sendName(name: String?): String? = lastSegment(name)

    /** 보내기 전 크기 판정. `size` 를 모르면(null — 제공자가 알려 주지 않음) 읽어 본 뒤 다시 판정한다. */
    enum class SizeCheck { OK, EMPTY, TOO_LARGE, UNKNOWN }

    fun checkSize(size: Long?): SizeCheck = when {
        size == null || size < 0 -> SizeCheck.UNKNOWN
        size == 0L -> SizeCheck.EMPTY
        size > MAX_SEND_BYTES -> SizeCheck.TOO_LARGE
        else -> SizeCheck.OK
    }
}
