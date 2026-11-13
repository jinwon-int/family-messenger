// 말풍선 사진 썸네일(#698 C2)의 순수 규칙 — 미리 받아 볼 첨부인가 · 디코드 표본 크기 · 줄일 크기 · 말풍선 자리 크기.
// 바이트 받기·디코드·메모리 LRU 는 `ui/AttachmentThumbs.kt`. android.* 없이 JVM 에서 돈다(`ThumbnailSizingTest`).
package com.seoyoon_family.hande.core

object ThumbnailSizing {
    /** 디코드 목표 긴 변(dp) — 실제 px 은 × density. */
    const val LONG_SIDE_DP = 360
    /** 말풍선 사진 자리의 최대 너비·높이(dp). 너비는 말풍선(화면 82%) 안에 들게. */
    const val BOX_MAX_WIDTH_DP = 260f
    const val BOX_MAX_HEIGHT_DP = 360f
    /**
     * 화면에 보이면 저절로 받아 볼 file-v2 첨부 크기 상한(웹 `IMAGE_PREVIEW_MAX` 20 MiB, #499 4단계 ③). 그보다 크면 눌러서 열 때만 받는다.
     * v1 첨부(바이트가 이력에 있음)는 상한 없이 판별한다.
     */
    const val PREVIEW_MAX_BYTES: Long = 20L * 1024 * 1024
    /** 설명자 w/h 힌트의 범위(FILE-V2 §1 `MAX_DIMENSION`). 밖이면 힌트 없음. */
    const val MAX_HINT = 20_000L

    /**
     * 썸네일을 시도할지 + 자리 크기 힌트. [candidate] 는 「받아서 판별해 볼 만한가」일 뿐이다 — 사진으로 그릴지는 받은 바이트의
     * 내용 판별(`fileV2Sniff`)과 디코드 성공으로만 정한다(FILE-V2 §4.4). [w]·[h] = 검증한 힌트(둘 다 있거나 둘 다 null).
     */
    data class Preview(val candidate: Boolean, val w: Int? = null, val h: Int? = null)

    /** w/h 힌트 → 둘 다 1..[MAX_HINT] 면 (w, h), 아니면 null. */
    fun hint(w: Long?, h: Long?): Pair<Int, Int>? =
        if (w != null && h != null && w in 1..MAX_HINT && h in 1..MAX_HINT) w.toInt() to h.toInt() else null

    /**
     * file-v2 첨부의 [Preview]: 크기 1..[PREVIEW_MAX_BYTES] 이고, 보낸 쪽 MIME 힌트가 없거나 `image/` 일 때만 받아 본다
     * (힌트는 저절로 받을 범위를 **좁히는** 데만 쓴다 — PDF 를 보이는 대로 내려받지 않게. 무엇으로 그릴지는 정하지 않는다).
     */
    fun fileV2(size: Long, mime: String?, w: Long?, h: Long?): Preview {
        val dims = hint(w, h)
        val imageHint = mime == null || mime.trim().lowercase().startsWith("image/")
        return Preview(candidate = size in 1..PREVIEW_MAX_BYTES && imageHint, w = dims?.first, h = dims?.second)
    }

    /** 디코드 목표 긴 변(px) = [LONG_SIDE_DP] × density(최소 1). */
    fun targetLongSidePx(density: Float): Int = maxOf(1, Math.round(LONG_SIDE_DP * density))

    /**
     * `inSampleSize`(BitmapFactory) · `setTargetSampleSize`(ImageDecoder): 2 의 거듭제곱 중, 표본 디코드의 긴 변이 아직 [target] 이상인
     * 가장 큰 값(최소 1). 긴 변으로만 정하므로 회전(EXIF) 여부와 무관하다. 크기를 모르면(≤ 0) 1.
     */
    fun sampleSize(width: Int, height: Int, target: Int): Int {
        val long = maxOf(width, height)
        if (long <= 0 || target <= 0) return 1
        var sample = 1
        while (sample <= Int.MAX_VALUE / 2 && long / (sample * 2) >= target) sample *= 2
        return sample
    }

    /** 표본 디코드 결과를 긴 변 [target] 으로 줄인 크기(비율 유지, 키우지 않음, 각 변 최소 1). */
    fun scaledSize(width: Int, height: Int, target: Int): Pair<Int, Int> {
        val long = maxOf(width, height)
        if (long <= target || long <= 0 || target <= 0) return width to height
        val scale = target.toDouble() / long
        return maxOf(1, Math.round(width * scale).toInt()) to maxOf(1, Math.round(height * scale).toInt())
    }

    /**
     * 말풍선 사진 자리(dp): 비율을 지켜 [BOX_MAX_WIDTH_DP]×[BOX_MAX_HEIGHT_DP] 안에 들게 줄이고 키우지는 않는다(원본 px 을 dp 상한으로 —
     * 웹 #647 `max-width`·`max-height` 와 같은 계산). 받기 전에는 설명자 w/h 힌트로, 받은 뒤에는 디코드한 크기로 같은 계산을 한다.
     * 정수 dp 로 반올림(각 변 최소 1). 크기를 모르면 null.
     */
    fun box(width: Int, height: Int, maxWidth: Float = BOX_MAX_WIDTH_DP, maxHeight: Float = BOX_MAX_HEIGHT_DP): Pair<Int, Int>? {
        if (width <= 0 || height <= 0) return null
        val scale = minOf(1.0, maxWidth.toDouble() / width, maxHeight.toDouble() / height)
        return maxOf(1, Math.round(width * scale).toInt()) to maxOf(1, Math.round(height * scale).toInt())
    }
}
