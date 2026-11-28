package com.seoyoon_family.hande.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class PdfPagesTest {
    @Test
    fun opensInAppOnlyForContentSniffedPdf() {
        assertTrue(PdfPages.opensInApp("application/pdf"))
        assertFalse(PdfPages.opensInApp("application/octet-stream"))
        assertFalse(PdfPages.opensInApp("application/zip"))
        assertFalse(PdfPages.opensInApp("image/png"))
        // 대소문자·매개변수가 붙은 값은 판별기가 내지 않는다 — 그대로 다른 앱 경로로.
        assertFalse(PdfPages.opensInApp("Application/PDF"))
    }

    @Test
    fun renderWidthIsViewWidthTimesScaleCappedAtMax() {
        // A4 세로(595 × 842pt), 화면 폭 540px → 1080px 폭, 높이는 비율대로.
        assertEquals(1080 to 1528, PdfPages.renderSize(595, 842, 540))
        // 화면 폭 1440px → 2880 이 아니라 상한 2048.
        assertEquals(2048 to 2898, PdfPages.renderSize(595, 842, 1440))
    }

    @Test
    fun veryTallPageShrinksToPixelCapKeepingAspect() {
        val (w, h) = PdfPages.renderSize(100, 20_000, 1080)!!
        assertTrue("넓이 ${w.toLong() * h} ≤ 상한", w.toLong() * h <= PdfPages.MAX_PIXELS)
        assertTrue(w >= 1 && h >= 1)
        // 비율 유지(반올림 오차 1px 이내).
        assertEquals(h.toDouble(), w * 200.0, 200.0)
    }

    @Test
    fun invalidSizesDrawNothing() {
        assertNull(PdfPages.renderSize(0, 842, 540))
        assertNull(PdfPages.renderSize(595, -1, 540))
        assertNull(PdfPages.renderSize(595, 842, 0))
    }

    @Test
    fun aspectFallsBackToA4Portrait() {
        assertEquals(842f / 595f, PdfPages.aspect(595, 842), 1e-6f)
        assertEquals(1.4142135f, PdfPages.aspect(0, 0), 1e-6f)
    }

    @Test
    fun pageLabelIsOneBased() {
        assertEquals("1 / 12쪽", PdfPages.pageLabel(0, 12))
        assertEquals("12 / 12쪽", PdfPages.pageLabel(11, 12))
    }

    @Test
    fun zoomIsClamped() {
        assertEquals(1f, PdfPages.clampZoom(0.3f))
        assertEquals(2.5f, PdfPages.clampZoom(2.5f))
        assertEquals(4f, PdfPages.clampZoom(9f))
    }
}
