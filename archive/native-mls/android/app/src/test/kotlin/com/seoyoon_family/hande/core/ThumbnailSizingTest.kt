// `ThumbnailSizing` 고정(#698 C2): 저절로 받아 볼 첨부 · 디코드 표본 크기 · 줄일 크기 · 말풍선 자리(#647 규칙).
// android.* 없이 JVM 에서 돈다(CI `:app:testDebugUnitTest`).
package com.seoyoon_family.hande.core

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

class ThumbnailSizingTest {
    @Test fun fileV2CandidatesAreSmallEnoughAndNotHintedAsSomethingElse() {
        assertEquals(ThumbnailSizing.Preview(true, 4032, 3024), ThumbnailSizing.fileV2(2_481_920, "image/jpeg", 4032, 3024))
        assertTrue(ThumbnailSizing.fileV2(1_000, null, null, null).candidate, "MIME 힌트가 없으면 받아서 판별")
        assertTrue(ThumbnailSizing.fileV2(1_000, " Image/PNG ", null, null).candidate)
        assertFalse(ThumbnailSizing.fileV2(1_000, "application/pdf", null, null).candidate, "PDF 는 보이는 대로 내려받지 않는다")
        assertTrue(ThumbnailSizing.fileV2(ThumbnailSizing.PREVIEW_MAX_BYTES, "image/jpeg", null, null).candidate)
        assertFalse(ThumbnailSizing.fileV2(ThumbnailSizing.PREVIEW_MAX_BYTES + 1, "image/jpeg", null, null).candidate, "20 MiB 초과는 눌러서 열 때만")
        assertFalse(ThumbnailSizing.fileV2(0, "image/jpeg", null, null).candidate)
    }

    @Test fun dimensionHintsMustBothBeInRange() {
        assertEquals(1 to 20_000, ThumbnailSizing.hint(1, 20_000))
        assertNull(ThumbnailSizing.hint(0, 100))
        assertNull(ThumbnailSizing.hint(100, 20_001))
        assertNull(ThumbnailSizing.hint(100, null))
        assertEquals(ThumbnailSizing.Preview(true, null, null), ThumbnailSizing.fileV2(10, "image/png", 100, 0), "한쪽만 틀려도 힌트 없음")
    }

    @Test fun targetIs360dpTimesDensity() {
        assertEquals(360, ThumbnailSizing.targetLongSidePx(1f))
        assertEquals(1080, ThumbnailSizing.targetLongSidePx(3f))
        assertEquals(945, ThumbnailSizing.targetLongSidePx(2.625f))
        assertEquals(1, ThumbnailSizing.targetLongSidePx(0f))
    }

    @Test fun sampleSizeKeepsTheLongSideAtOrAboveTheTarget() {
        assertEquals(2, ThumbnailSizing.sampleSize(4032, 3024, 1080), "4032/2 = 2016 ≥ 1080, 4032/4 = 1008 < 1080")
        assertEquals(2, ThumbnailSizing.sampleSize(3024, 4032, 1080), "세로 사진도 같은 값(긴 변 기준 — EXIF 회전 무관)")
        assertEquals(8, ThumbnailSizing.sampleSize(4032, 3024, 360))
        assertEquals(1, ThumbnailSizing.sampleSize(800, 600, 1080), "목표보다 작으면 그대로")
        assertEquals(1, ThumbnailSizing.sampleSize(2159, 100, 1080))
        assertEquals(2, ThumbnailSizing.sampleSize(2160, 100, 1080))
        assertEquals(1, ThumbnailSizing.sampleSize(0, 0, 1080), "크기 모름")
        assertEquals(1, ThumbnailSizing.sampleSize(100, 100, 0))
    }

    @Test fun scaledSizeShrinksToTheTargetWithoutGrowing() {
        assertEquals(1080 to 810, ThumbnailSizing.scaledSize(2016, 1512, 1080))
        assertEquals(810 to 1080, ThumbnailSizing.scaledSize(1512, 2016, 1080))
        assertEquals(800 to 600, ThumbnailSizing.scaledSize(800, 600, 1080), "키우지 않는다")
        assertEquals(1080 to 1, ThumbnailSizing.scaledSize(20_000, 1, 1080), "아주 긴 그림도 각 변 최소 1")
    }

    @Test fun boxFitsTheBubbleKeepsTheRatioAndMatchesBeforeAndAfterDecode() {
        assertEquals(260 to 195, ThumbnailSizing.box(4032, 3024))
        assertEquals(260 to 347, ThumbnailSizing.box(3024, 4032), "세로 사진: 너비 260 이 먼저 닿는다(4032 × 260/3024 ≈ 346.7)")
        assertEquals(203 to 360, ThumbnailSizing.box(1000, 1773), "아주 긴 세로 사진은 높이 360 에서")
        assertEquals(100 to 80, ThumbnailSizing.box(100, 80), "작은 그림은 키우지 않는다")
        assertNull(ThumbnailSizing.box(0, 10))
        // 받기 전(설명자 힌트)과 받은 뒤(디코드한 1080×810)의 자리가 같다 — 타임라인이 밀리지 않는다(#647).
        val (dw, dh) = ThumbnailSizing.scaledSize(4032 / ThumbnailSizing.sampleSize(4032, 3024, 1080), 3024 / ThumbnailSizing.sampleSize(4032, 3024, 1080), 1080)
        assertEquals(ThumbnailSizing.box(4032, 3024), ThumbnailSizing.box(dw, dh))
    }
}
