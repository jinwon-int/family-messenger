// 첨부 열기·보내기 규칙(#366 C) — 저장·공유 이름 · MIME → 확장자 · 보낼 이름 · 보낼 크기 · 릴레이 크기 거절 판정.
// android.* 없이 JVM 에서 돈다(CI `:app:testDebugUnitTest`, 양방향 제어 문자 판정은 코어 `fileV2DisplayName` — JNA).
package com.seoyoon_family.hande.core

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

class AttachmentFilesTest {
    @Test fun safeNameKeepsTheSendersLastSegment() {
        assertEquals("사진.jpg", AttachmentFiles.safeName("사진.jpg", "image/jpeg"))
        assertEquals("r.pdf", AttachmentFiles.safeName("dir/sub/r.pdf", "application/pdf"))
        assertEquals("r.pdf", AttachmentFiles.safeName("C:\\Users\\a\\r.pdf", "application/pdf"))
        assertEquals("보고서 최종.pdf", AttachmentFiles.safeName("  보고서 최종.pdf  ", "application/pdf"))
    }

    @Test fun safeNameFallsBackByContentType() {
        assertEquals("첨부.png", AttachmentFiles.safeName(null, "image/png"))
        assertEquals("첨부.jpg", AttachmentFiles.safeName("", "image/jpeg"))
        assertEquals("첨부.pdf", AttachmentFiles.safeName("dir/", "application/pdf"))
        assertEquals("첨부.bin", AttachmentFiles.safeName("..", "application/octet-stream"))
        assertEquals("첨부.txt", AttachmentFiles.safeName("a\u0007b.txt", "text/plain"), "control character")
        assertEquals("첨부.png", AttachmentFiles.safeName("가".repeat(256), "image/png"), "over 255 code points")
        // 양방향 제어 문자 = 확장자 위장(「photo‮gpj.exe」가 「photoexe.jpg」처럼 보인다) — 코어 규칙으로 버린다.
        assertEquals("첨부.bin", AttachmentFiles.safeName("photo\u202egpj.exe", "application/octet-stream"))
    }

    @Test fun extensionsFollowTheSniffedMime() {
        assertEquals(".heic", AttachmentFiles.extensionFor("image/heic"))
        assertEquals(".tif", AttachmentFiles.extensionFor("image/tiff"))
        assertEquals(".zip", AttachmentFiles.extensionFor("application/zip"))
        assertEquals(".bin", AttachmentFiles.extensionFor("application/x-unknown"))
    }

    @Test fun sendNameIsTheLastSegmentOrNothing() {
        assertEquals("IMG_0001.HEIC", AttachmentFiles.sendName("/storage/emulated/0/DCIM/IMG_0001.HEIC"))
        assertNull(AttachmentFiles.sendName(null))
        assertNull(AttachmentFiles.sendName("  "))
        assertNull(AttachmentFiles.sendName("a\nb"))
        assertEquals("가".repeat(255), AttachmentFiles.sendName("가".repeat(255)))
        assertNull(AttachmentFiles.sendName("가".repeat(256)))
    }

    @Test fun sizeChecks() {
        assertEquals(AttachmentFiles.SizeCheck.UNKNOWN, AttachmentFiles.checkSize(null))
        assertEquals(AttachmentFiles.SizeCheck.UNKNOWN, AttachmentFiles.checkSize(-1))
        assertEquals(AttachmentFiles.SizeCheck.EMPTY, AttachmentFiles.checkSize(0))
        assertEquals(AttachmentFiles.SizeCheck.OK, AttachmentFiles.checkSize(1))
        assertEquals(AttachmentFiles.SizeCheck.OK, AttachmentFiles.checkSize(50L * 1024 * 1024))
        assertEquals(AttachmentFiles.SizeCheck.TOO_LARGE, AttachmentFiles.checkSize(50L * 1024 * 1024 + 1))
    }

    @Test fun relaySizeRefusals() {
        assertTrue(AttachmentFiles.isSizeRefusal("relay error 413: blob_too_large"))
        assertTrue(AttachmentFiles.isSizeRefusal("relay error 413: room_bytes_cap"))
        assertTrue(AttachmentFiles.isSizeRefusal("relay error 413: device_bytes_cap"))
        assertFalse(AttachmentFiles.isSizeRefusal("relay error 403: not_a_member"))
    }

    @Test fun openedNeverPrintsItsBytes() {
        val o = AttachmentFiles.Opened(byteArrayOf(1, 2, 3), "image/png", "image", "a.png")
        assertEquals("Opened(image/png, 3 B)", o.toString())
    }
}
