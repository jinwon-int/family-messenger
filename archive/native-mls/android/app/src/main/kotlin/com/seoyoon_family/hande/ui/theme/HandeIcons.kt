// 한데 고유 UI 아이콘(2차-B B2) 의 Compose 판 — `core/IconPaths` 의 SVG `d` 문자열을 `ImageVector.Builder` 로 그린다(24 뷰박스 · 선 1.6 · 둥근 끝/모서리).
// 역할색 채움(`data-role`)은 현재 `HandeColors` 로 칠한다: 밤 = ember #F59E42 · ember-deep #E8833A · person 크림 · agent 파랑 / 낮불 = agent 만 파랑, 나머지 먹.
// 불꽃은 켜진 갈래 = 채움(낮불은 먹 채움 + 먹 선), 꺼진 갈래 = 선만(밤 먹 35% / 낮불 먹). 낮불 `seat` 의 에이전트 점은 ◆. 색이 들어 있으므로
// `Icon(imageVector, contentDescription, tint = Color.Unspecified)` 로 그린다(tint 를 주면 역할색이 덮인다). VectorDrawable 리소스·아이콘 라이브러리 의존 없음.
// 아래 「글리프」(뒤로·닫기·설정·더하기·보내기·공유·복사·열기·펼침)는 Material Symbols 짝의 선 그림 — 역할색 없이 한 가지 색(선 1.8~2.4).
package com.seoyoon_family.hande.ui.theme

import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.StrokeJoin
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.graphics.vector.PathParser
import androidx.compose.ui.unit.dp
import com.seoyoon_family.hande.core.IconPaths

object HandeIcons {
    /** SVG 원본의 선 굵기(뷰박스 24 기준). */
    private const val STROKE = 1.6f

    private fun builder(name: String): ImageVector.Builder =
        ImageVector.Builder(name = name, defaultWidth = 24.dp, defaultHeight = 24.dp, viewportWidth = 24f, viewportHeight = 24f)

    private fun ImageVector.Builder.strokePath(d: String, color: Color, width: Float = STROKE, alpha: Float = 1f): ImageVector.Builder =
        addPath(
            pathData = PathParser().parsePathString(d).toNodes(),
            stroke = SolidColor(color), strokeAlpha = alpha, strokeLineWidth = width,
            strokeLineCap = StrokeCap.Round, strokeLineJoin = StrokeJoin.Round,
        )

    private fun ImageVector.Builder.fillPath(d: String, color: Color, outline: Color? = null): ImageVector.Builder =
        addPath(
            pathData = PathParser().parsePathString(d).toNodes(),
            fill = SolidColor(color),
            stroke = outline?.let { SolidColor(it) }, strokeLineWidth = if (outline != null) STROKE else 0f,
            strokeLineCap = StrokeCap.Round, strokeLineJoin = StrokeJoin.Round,
        )

    /** `data-role` 채움색: 밤은 토큰 그대로, 낮불은 agent 만 파랑(나머지 먹 — 색 없이 채움·기호로 읽힌다). */
    private fun roleColor(role: String, c: HandeColors): Color = when (role) {
        IconPaths.ROLE_AGENT -> c.agent
        IconPaths.ROLE_PERSON -> c.person
        IconPaths.ROLE_EMBER -> if (c.isDay) c.ink else c.ember
        IconPaths.ROLE_EMBER_DEEP -> if (c.isDay) c.ink else c.emberDeep
        else -> c.ink
    }

    /** 선(currentColor)은 `line`, 역할색은 토큰으로. */
    private fun lineIcon(name: String, parts: List<IconPaths.Part>, c: HandeColors, line: Color): ImageVector {
        val b = builder(name)
        for (p in parts) {
            val role = p.role
            if (role == null) b.strokePath(p.d, line) else b.fillPath(p.d, roleColor(role, c))
        }
        return b.build()
    }

    /**
     * 불 세기 1~3단 불꽃: 켜진 갈래 = 채움(밤 ember/ember-deep · 낮불 먹 채움 + 먹 선), 꺼진 갈래 = 선만(밤 먹 35% · 낮불 먹 선).
     * `dim`(꺼진 자리)이면 켜진 갈래도 `ash`.
     */
    fun flame(level: Int, c: HandeColors, dim: Boolean = false): ImageVector {
        val b = builder("hande.flame-${level.coerceIn(1, 3)}")
        for (p in IconPaths.flame(level)) {
            val role = p.role
            if (role == IconPaths.ROLE_UNLIT || role == null) {
                if (c.isDay) b.strokePath(p.d, c.ink) else b.strokePath(p.d, c.ink, alpha = 0.35f)
            } else {
                val fill = if (dim) c.ash else roleColor(role, c)
                b.fillPath(p.d, fill, outline = if (c.isDay) (if (dim) c.ash else c.ink) else null)
            }
        }
        return b.build()
    }

    /** 꺼진 자리 — 장작(기본 `ash`). */
    fun embersOut(c: HandeColors, line: Color = c.ash): ImageVector = lineIcon("hande.embers-out", IconPaths.embersOut, c, line)

    /** 불지기(사람 실루엣 + ◆ agent). */
    fun keeper(c: HandeColors, line: Color = c.ink): ImageVector = lineIcon("hande.keeper", IconPaths.keeper, c, line)

    /** 지문(대조). */
    fun fingerprintRows(c: HandeColors, line: Color = c.ink): ImageVector = lineIcon("hande.fingerprint-rows", IconPaths.fingerprintRows, c, line)

    fun deviceIphone(c: HandeColors, line: Color = c.ink): ImageVector = lineIcon("hande.device-iphone", IconPaths.deviceIphone, c, line)
    fun deviceAndroid(c: HandeColors, line: Color = c.ink): ImageVector = lineIcon("hande.device-android", IconPaths.deviceAndroid, c, line)
    fun devicePc(c: HandeColors, line: Color = c.ink): ImageVector = lineIcon("hande.device-pc", IconPaths.devicePc, c, line)
    fun deviceWeb(c: HandeColors, line: Color = c.ink): ImageVector = lineIcon("hande.device-web", IconPaths.deviceWeb, c, line)

    /** 자리(둘러앉음): 사람 ● / 에이전트 — 밤 ● 파랑, 낮불 ◆ 파랑. */
    fun seat(c: HandeColors, line: Color = c.ink): ImageVector {
        val b = builder("hande.seat")
        var agentIndex = 0
        for (p in IconPaths.seat) {
            val role = p.role
            when {
                role == null -> b.strokePath(p.d, line)
                role == IconPaths.ROLE_AGENT && c.isDay -> {
                    val diamond = IconPaths.seatAgentDiamonds.getOrNull(agentIndex) ?: p.d
                    agentIndex++
                    b.fillPath(diamond, c.agent)
                }
                else -> b.fillPath(p.d, roleColor(role, c))
            }
        }
        return b.build()
    }

    fun inviteBell(c: HandeColors, line: Color = c.ink): ImageVector = lineIcon("hande.invite-bell", IconPaths.inviteBell, c, line)
    fun reorder(c: HandeColors, line: Color = c.ink): ImageVector = lineIcon("hande.reorder", IconPaths.reorder, c, line)
    fun cover(c: HandeColors, line: Color = c.ink): ImageVector = lineIcon("hande.cover", IconPaths.cover, c, line)

    // ---- 글리프(Material Symbols 짝 — arrow_back · close · settings · add · arrow_upward · share · content_copy · open_in_new · expand_more). 디자인 3차-A 원문의 선 그림.

    private fun glyph(name: String, d: String, color: Color, width: Float): ImageVector = builder(name).strokePath(d, color, width).build()

    fun back(color: Color): ImageVector = glyph("hande.glyph.back", "M20 12H5M11 6l-6 6 6 6", color, 2f)
    fun close(color: Color): ImageVector = glyph("hande.glyph.close", "M6 6l12 12M18 6L6 18", color, 2f)
    fun settings(color: Color): ImageVector = glyph(
        "hande.glyph.settings",
        "M12 15a3 3 0 1 0 0-6 3 3 0 0 0 0 6ZM19.4 13.5l1.6 1.2-1.8 3.1-1.9-.7a7 7 0 0 1-2.1 1.2l-.3 2h-3.6l-.3-2a7 7 0 0 1-2.1-1.2l-1.9.7-1.8-3.1 1.6-1.2a7 7 0 0 1 0-3l-1.6-1.2 1.8-3.1 1.9.7a7 7 0 0 1 2.1-1.2l.3-2h3.6l.3 2a7 7 0 0 1 2.1 1.2l1.9-.7 1.8 3.1-1.6 1.2a7 7 0 0 1 0 3Z",
        color, 1.6f,
    )
    fun add(color: Color): ImageVector = glyph("hande.glyph.add", "M12 5v14M5 12h14", color, 2.2f)
    fun send(color: Color): ImageVector = glyph("hande.glyph.send", "M12 19V5M5 12l7-7 7 7", color, 2.4f)
    fun share(color: Color): ImageVector = glyph(
        "hande.glyph.share",
        "M18 8a3 3 0 1 0 0-6 3 3 0 0 0 0 6ZM6 15a3 3 0 1 0 0-6 3 3 0 0 0 0 6ZM18 22a3 3 0 1 0 0-6 3 3 0 0 0 0 6ZM8.6 13.5l6.8 4M15.4 6.5l-6.8 4",
        color, 1.6f,
    )
    fun copy(color: Color): ImageVector = glyph("hande.glyph.copy", "M9 9h10v12H9zM5 15V3h10", color, 1.8f)
    fun openInNew(color: Color): ImageVector = glyph("hande.glyph.open-in-new", "M14 4h6v6M20 4l-9 9M18 14v6H4V6h6", color, 1.8f)
    fun expandMore(color: Color): ImageVector = glyph("hande.glyph.expand-more", "M6 9l6 6 6-6", color, 2f)
}
