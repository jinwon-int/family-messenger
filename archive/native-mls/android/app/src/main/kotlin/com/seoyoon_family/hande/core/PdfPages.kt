// 받은 PDF 를 앱 안에서 보기(#698 C3)의 순수 규칙 — 앱 안 뷰어로 열 첨부인가 · 페이지를 그릴 비트맵 크기 · 쪽 표시.
// `PdfRenderer`·비트맵·임시 파일은 `ui/PdfViewer.kt`. android.* 없이 JVM 에서 돈다(`PdfPagesTest`).
package com.seoyoon_family.hande.core

object PdfPages {
    /** 내용 판별(`fileV2Sniff`·`sniff_mime`)이 PDF(`%PDF-`)라고 한 MIME. 보낸 쪽 MIME·파일명 힌트는 보지 않는다(#698 보안 원칙). */
    const val MIME = "application/pdf"

    /** 페이지 비트맵 너비 상한(px). 화면 폭 × 확대 배율이 이보다 커도 여기서 멈춘다. */
    const val MAX_WIDTH_PX = 2048

    /** 페이지 비트맵 하나의 픽셀 상한(ARGB_8888 기준 약 32 MiB). 아주 긴 페이지는 너비를 줄여 이 안에 넣는다. */
    const val MAX_PIXELS = 8L * 1024 * 1024

    /** 그릴 때 화면 폭보다 크게 그리는 배율 — 두 배까지 확대해도 흐려지지 않게. */
    const val RENDER_SCALE = 2f

    /** 확대 범위. */
    const val MIN_ZOOM = 1f
    const val MAX_ZOOM = 4f

    /** 앱 안 PDF 뷰어로 열 첨부인가 — 받은 바이트로 정한 [mime] 만 본다. */
    fun opensInApp(mime: String): Boolean = mime == MIME

    /**
     * 페이지 하나를 그릴 비트맵 크기(px). [pageWidth]·[pageHeight] = `PdfRenderer.Page` 크기(1/72 inch),
     * [viewWidthPx] = 화면에 보일 폭. 폭은 `viewWidthPx × RENDER_SCALE` 를 [MAX_WIDTH_PX] 로 자르고, 높이는 비율대로.
     * 넓이가 [MAX_PIXELS] 를 넘으면 비율을 지킨 채 줄인다. 페이지 크기가 0 이하이거나 폭이 0 이하면 null(그리지 않는다).
     */
    fun renderSize(pageWidth: Int, pageHeight: Int, viewWidthPx: Int): Pair<Int, Int>? {
        if (pageWidth <= 0 || pageHeight <= 0 || viewWidthPx <= 0) return null
        var w = minOf(MAX_WIDTH_PX, Math.round(viewWidthPx * RENDER_SCALE)).coerceAtLeast(1)
        var h = heightFor(w, pageWidth, pageHeight)
        if (w.toLong() * h > MAX_PIXELS) {
            val shrink = Math.sqrt(MAX_PIXELS.toDouble() / (w.toLong() * h))
            w = (w * shrink).toInt().coerceAtLeast(1)
            h = heightFor(w, pageWidth, pageHeight)
            while (w > 1 && w.toLong() * h > MAX_PIXELS) {
                w -= 1
                h = heightFor(w, pageWidth, pageHeight)
            }
        }
        return w to h
    }

    private fun heightFor(w: Int, pageWidth: Int, pageHeight: Int): Int =
        Math.round(w.toDouble() * pageHeight / pageWidth).toInt().coerceAtLeast(1)

    /** 화면에서 페이지가 차지할 세로:가로 비(높이 ÷ 폭). 페이지 크기가 잘못이면 A4 세로(√2). */
    fun aspect(pageWidth: Int, pageHeight: Int): Float =
        if (pageWidth > 0 && pageHeight > 0) pageHeight.toFloat() / pageWidth else 1.4142135f

    /** 화면 낭독·표시용 쪽 번호 — 「3 / 12쪽」. [index] 는 0부터. */
    fun pageLabel(index: Int, count: Int): String = "${index + 1} / ${count}쪽"

    /** 확대 배율을 [MIN_ZOOM]..[MAX_ZOOM] 안으로. */
    fun clampZoom(zoom: Float): Float = zoom.coerceIn(MIN_ZOOM, MAX_ZOOM)
}
