// 한데 디자인 1차(2026-10-31) — 색·타이포·반경 토큰과 모닥불 배경·좌석 점·불꽃/장작 아이콘.
// 값의 정본은 `docs/design/hande-tokens.json`(iOS `Hande.*`·웹 `styles.css` `:root` 와 같은 값이어야 한다). 밤이 기본·고정, 낮불은 설정에서 고른다(`Settings.theme`).
// Material3 `colorScheme` 매핑은 M3 위젯(버튼·텍스트필드·대화상자·스낵바)이 토큰 색을 따르게 하는 다리 — 화면 코드는 되도록 `LocalHandeColors` 를 직접 쓴다.
// 3차-A A4 Compose 인계 노트(2026-10-31)대로 정렬: secondary = person · tertiary = agent · primaryContainer = 잉걸불 · surface = bgTop 은 그대로 두되
//   surfaceContainer(#202433 = white 7% 합성) / surfaceContainerHigh(#1C2136) 를 채워 M3 Card·Dialog·Snackbar 가 배경에 묻히지 않게 한다(디자이너 질문에 대한 답: 예).
//   outline = #FFBF78 40% / outlineVariant 14% · error = warn · onError = 불 위 글자(낮불 종이). 2차-B 상태표의 주의 글자·비활성·눌림 색은 `HandeColors` 에 더했다.
package com.seoyoon_family.hande.ui.theme

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxScope
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.ColorScheme
import androidx.compose.material3.Icon
import androidx.compose.material3.LocalContentColor
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Shapes
import androidx.compose.material3.Typography
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.Immutable
import androidx.compose.runtime.remember
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.draw.rotate
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.em
import androidx.compose.ui.unit.sp
import com.seoyoon_family.hande.core.HandeThemeMode

/** 색 토큰 한 벌(`hande-tokens.json` `color.night` / `color.day`). `bgGlow` 가 null 이면 그라데이션 없음(낮불). */
@Immutable
data class HandeColors(
    /** 배경 위 · 밤하늘(낮불: 종이). */
    val bgTop: Color,
    /** 배경 아래 · 불빛이 닿은 땅 — radial 45%→0. 낮불은 null(그라데이션 금지). */
    val bgGlow: Color?,
    /** 불 · 1차 강조 — 주 버튼·내 말풍선·포커스. */
    val ember: Color,
    /** 진한 불 — 눌림. */
    val emberDeep: Color,
    /** 불 위 글자. */
    val onEmber: Color,
    /** 사람 점 ●(밤 크림 / 낮불 먹). 사람은 어떤 화면에서도 이 색. */
    val person: Color,
    /** 에이전트 점·카드(밤 ● 빛남 / 낮불 ◆). 에이전트는 항상 파랑. */
    val agent: Color,
    /** 에이전트 라벨 글자. */
    val agentText: Color,
    /** 글자(순백 금지). */
    val ink: Color,
    /** 보조 글자. */
    val inkDim: Color,
    /** 면 — 카드·남의 말풍선·입력창(밤 반투명 / 낮불 불투명). */
    val surface: Color,
    /** 선(밤 따뜻한 색 14% / 낮불 먹). */
    val stroke: Color,
    /** 상태 · 주의/실패(선·면) — 반드시 글자 동반. */
    val warn: Color,
    /** 주의 글자색(밤 #F08A70 — 어두운 면 위에서 `warn` 보다 밝게 / 낮불은 `warn` 과 같은 #A8321C). 2차-B `warnT`. */
    val warnText: Color,
    /** 상태 · 정지/꺼짐 — 꺼진 재. */
    val ash: Color,
    /** 포커스 2px 바깥선. */
    val focus: Color,
    /** 비활성 면(밤 불 18% / 낮불 종이). 2차-B 상태표 「비활성」. */
    val disabledFill: Color,
    /** 비활성 선(밤 따뜻한 선 14% / 낮불 회색 #8A8178 — 원문은 점선이지만 M3 `BorderStroke` 는 점선을 못 그려 실선 1.5). */
    val disabledStroke: Color,
    /** 비활성 글자(밤 먹 45% / 낮불 회색 #8A8178). */
    val disabledText: Color,
    /** 눌림 면(밤 white 13% / 낮불 #E9E4DA) — M3 리플 대신 직접 그릴 때. */
    val pressed: Color,
    val isDay: Boolean,
    /** 선 굵기(밤 1 / 낮불 1.5 — e-ink 1px 끊김 방지). */
    val lineWidth: Dp,
) {
    companion object {
        val Night = HandeColors(
            bgTop = Color(0xFF0F1324),
            bgGlow = Color(0xFF5A2C12),
            ember = Color(0xFFF59E42),
            emberDeep = Color(0xFFE8833A),
            onEmber = Color(0xFF1B0F06),
            person = Color(0xFFFFD79A),
            agent = Color(0xFF61A6FA),
            agentText = Color(0xFF9CC8FF),
            ink = Color(0xFFF3E6D3),
            inkDim = Color(0xFFC9B89C),
            surface = Color(0xFFFFFFFF).copy(alpha = 0.07f),
            stroke = Color(0xFFFFBF78).copy(alpha = 0.14f),
            warn = Color(0xFFD9583B),
            warnText = Color(0xFFF08A70),
            ash = Color(0xFF6B5A48),
            focus = Color(0xFFFFD79A),
            disabledFill = Color(0xFFF59E42).copy(alpha = 0.18f),
            disabledStroke = Color(0xFFFFBF78).copy(alpha = 0.14f),
            disabledText = Color(0xFFF3E6D3).copy(alpha = 0.45f),
            pressed = Color(0xFFFFFFFF).copy(alpha = 0.13f),
            isDay = false,
            lineWidth = 1.dp,
        )

        val Day = HandeColors(
            bgTop = Color(0xFFF7F3EA),
            bgGlow = null,
            ember = Color(0xFFD97A1E),
            emberDeep = Color(0xFFB8650F),
            onEmber = Color(0xFF1A1510),
            person = Color(0xFF1A1510),
            agent = Color(0xFF2F6FC4),
            agentText = Color(0xFF2F6FC4),
            ink = Color(0xFF1A1510),
            inkDim = Color(0xFF3A322B),
            surface = Color(0xFFFFFFFF),
            stroke = Color(0xFF1A1510),
            warn = Color(0xFFA8321C),
            warnText = Color(0xFFA8321C),
            ash = Color(0xFF8A8178),
            focus = Color(0xFF1A1510),
            disabledFill = Color(0xFFF7F3EA),
            disabledStroke = Color(0xFF8A8178),
            disabledText = Color(0xFF8A8178),
            pressed = Color(0xFFE9E4DA),
            isDay = true,
            lineWidth = 1.5.dp,
        )
    }
}

val LocalHandeColors = staticCompositionLocalOf { HandeColors.Night }

// ---- Material3 매핑(3차-A A4 인계 노트): 반투명 토큰(면·선)은 밤하늘 위에 합성한 불투명 값으로 둔다(M3 면 색은 겹쳐 쓰여 반투명이면 탁해진다).
//      primary = 불 · secondary = 사람(자리 점·섹션 머리·포커스 선) · tertiary = 에이전트 · surface = bgTop · surfaceContainer = #202433 · surfaceContainerHigh = #1C2136(Dialog·Snackbar).
private val NightScheme: ColorScheme = darkColorScheme(
    primary = HandeColors.Night.ember,
    onPrimary = HandeColors.Night.onEmber,
    // 잉걸불(bgGlow) — 불 위에 얹는 면이 아니라 불빛이 닿은 땅.
    primaryContainer = Color(0xFF5A2C12),
    onPrimaryContainer = HandeColors.Night.ink,
    inversePrimary = HandeColors.Night.emberDeep,
    secondary = HandeColors.Night.person,
    onSecondary = HandeColors.Night.onEmber,
    // 불 22% 를 #0F1324 위에 합성한 값(SegmentedButton 선택 면).
    secondaryContainer = Color(0xFF42322B),
    onSecondaryContainer = HandeColors.Night.person,
    tertiary = HandeColors.Night.agent,
    onTertiary = HandeColors.Night.bgTop,
    tertiaryContainer = Color(0xFF1E3350),
    onTertiaryContainer = HandeColors.Night.agentText,
    background = HandeColors.Night.bgTop,
    onBackground = HandeColors.Night.ink,
    surface = HandeColors.Night.bgTop,
    onSurface = HandeColors.Night.ink,
    // white 7% 를 #0F1324 위에 합성한 값.
    surfaceVariant = Color(0xFF202433),
    onSurfaceVariant = HandeColors.Night.inkDim,
    surfaceTint = HandeColors.Night.ember,
    inverseSurface = HandeColors.Night.ink,
    inverseOnSurface = HandeColors.Night.bgTop,
    error = HandeColors.Night.warn,
    onError = HandeColors.Night.onEmber,
    // warn 10% 를 #0F1324 위에 합성한 값.
    errorContainer = Color(0xFF231A26),
    onErrorContainer = HandeColors.Night.warnText,
    // #FFBF78 40% / 14% — 밤하늘 위 합성은 M3 가 그릴 때 한다(선은 겹치지 않아 반투명이어도 된다).
    outline = Color(0x66FFBF78),
    outlineVariant = Color(0x24FFBF78),
    scrim = Color.Black,
    surfaceBright = Color(0xFF262A3D),
    surfaceDim = HandeColors.Night.bgTop,
    surfaceContainer = Color(0xFF202433),
    surfaceContainerHigh = Color(0xFF1C2136),
    surfaceContainerHighest = Color(0xFF262A3D),
    surfaceContainerLow = Color(0xFF161A2C),
    surfaceContainerLowest = HandeColors.Night.bgTop,
)

private val DayScheme: ColorScheme = lightColorScheme(
    primary = HandeColors.Day.ember,
    onPrimary = HandeColors.Day.onEmber,
    primaryContainer = HandeColors.Day.ember,
    onPrimaryContainer = HandeColors.Day.onEmber,
    inversePrimary = HandeColors.Day.emberDeep,
    secondary = HandeColors.Day.person,
    onSecondary = HandeColors.Day.bgTop,
    // 낮불 세그먼트 선택 = 먹 면 + 종이 글자(색 없이 채움·기호로).
    secondaryContainer = HandeColors.Day.ink,
    onSecondaryContainer = HandeColors.Day.bgTop,
    tertiary = HandeColors.Day.agent,
    onTertiary = HandeColors.Day.bgTop,
    tertiaryContainer = Color(0xFFFFFFFF),
    onTertiaryContainer = HandeColors.Day.agent,
    background = HandeColors.Day.bgTop,
    onBackground = HandeColors.Day.ink,
    surface = HandeColors.Day.bgTop,
    onSurface = HandeColors.Day.ink,
    surfaceVariant = Color(0xFFF2EDE3),
    onSurfaceVariant = HandeColors.Day.inkDim,
    surfaceTint = HandeColors.Day.ember,
    inverseSurface = HandeColors.Day.ink,
    inverseOnSurface = HandeColors.Day.bgTop,
    error = HandeColors.Day.warn,
    onError = HandeColors.Day.bgTop,
    errorContainer = Color(0xFFFFFFFF),
    onErrorContainer = HandeColors.Day.warn,
    // 낮불 선은 전부 먹(1.5dp 는 호출처가).
    outline = HandeColors.Day.stroke,
    outlineVariant = HandeColors.Day.stroke,
    scrim = Color.Black,
    surfaceBright = Color(0xFFFFFFFF),
    surfaceDim = Color(0xFFEBE5D9),
    surfaceContainer = Color(0xFFFFFFFF),
    surfaceContainerHigh = Color(0xFFFFFFFF),
    surfaceContainerHighest = Color(0xFFF2EDE3),
    surfaceContainerLow = Color(0xFFFFFFFF),
    surfaceContainerLowest = Color(0xFFFFFFFF),
)

// ---- 타이포(인계 노트): displaySmall 32/600 · titleLarge 22/600 · bodyLarge 17/400 행간 24 · labelLarge 15/500 · bodySmall 13/400. 나머지 슬롯은 M3 기본.
//      sp 단위 — 시스템 글꼴 크기 설정을 따른다. 글꼴은 FontFamily.Default = Roboto + Noto Sans KR(시스템) — Pretendard 번들 안 함.
private val HandeTypography: Typography = Typography().let { base ->
    base.copy(
        displaySmall = base.displaySmall.copy(fontSize = 32.sp, lineHeight = 40.sp, fontWeight = FontWeight.SemiBold),
        headlineLarge = base.headlineLarge.copy(fontSize = 32.sp, lineHeight = 40.sp, fontWeight = FontWeight.SemiBold),
        titleLarge = base.titleLarge.copy(fontSize = 22.sp, lineHeight = 28.sp, fontWeight = FontWeight.SemiBold),
        bodyLarge = base.bodyLarge.copy(fontSize = 17.sp, lineHeight = 24.sp, fontWeight = FontWeight.Normal),
        labelLarge = base.labelLarge.copy(fontSize = 15.sp, lineHeight = 20.sp, fontWeight = FontWeight.Medium),
        bodySmall = base.bodySmall.copy(fontSize = 13.sp, lineHeight = 18.sp, fontWeight = FontWeight.Normal),
        labelSmall = base.labelSmall.copy(fontSize = 13.sp, lineHeight = 18.sp, fontWeight = FontWeight.Normal),
    )
}

/** M3 슬롯 밖의 글자 스타일: 지문 모노 19 자간 .06em(등록·승인 화면의 8행) · 기기 ID 모노 13. */
object HandeType {
    val fingerprint: TextStyle = TextStyle(fontFamily = FontFamily.Monospace, fontSize = 19.sp, letterSpacing = 0.06.em)
    val mono: TextStyle = TextStyle(fontFamily = FontFamily.Monospace, fontSize = 13.sp)
}

// ---- 반경(토큰 `radius`): small 10 · medium 16 · large 24 · extraLarge 28(AlertDialog). 버튼·FAB 는 M3 기본(알약 / FAB 는 호출처가 16)을 쓴다.
private val HandeShapes: Shapes = Shapes(
    small = RoundedCornerShape(10.dp),
    medium = RoundedCornerShape(16.dp),
    large = RoundedCornerShape(24.dp),
    extraLarge = RoundedCornerShape(28.dp),
)

/** 토큰(`LocalHandeColors`)과 M3 테마를 함께 제공한다. `LocalContentColor` 도 글자색(ink)으로 — `Scaffold(containerColor = Transparent)` 아래 글자가 검정으로 떨어지지 않게. */
@Composable
fun HandeTheme(mode: HandeThemeMode, content: @Composable () -> Unit) {
    val colors = if (mode == HandeThemeMode.DAY) HandeColors.Day else HandeColors.Night
    CompositionLocalProvider(LocalHandeColors provides colors, LocalContentColor provides colors.ink) {
        MaterialTheme(
            colorScheme = if (colors.isDay) DayScheme else NightScheme,
            typography = HandeTypography,
            shapes = HandeShapes,
            content = content,
        )
    }
}

/**
 * 모닥불 배경: 밤하늘(`bgTop`) 위에 아래 가운데에서 번지는 잉걸불(`bgGlow` 45% → 0, 중심은 화면 아래 8% 밖, 반지름은 높이의 62%).
 * 낮불은 `bgGlow == null` 이라 단색 종이(그라데이션 금지).
 */
@Composable
fun CampfireBackground(modifier: Modifier = Modifier, content: @Composable BoxScope.() -> Unit) {
    val colors = LocalHandeColors.current
    val glow = colors.bgGlow
    Box(
        modifier
            .fillMaxSize()
            .background(colors.bgTop)
            .drawBehind {
                if (glow != null && size.height > 0f && size.width > 0f) {
                    drawRect(
                        Brush.radialGradient(
                            0f to glow,
                            0.45f to glow.copy(alpha = 0.45f),
                            1f to Color.Transparent,
                            center = Offset(size.width / 2f, size.height * 1.08f),
                            radius = size.height * 0.62f,
                        ),
                    )
                }
            },
        content = content,
    )
}

/**
 * 좌석 점: 사람 ●(`person`) / 에이전트 — 밤 ●(`agent`, 은은한 빛남), 낮불 ◆(`agent`, 빛남 없음 — 색과 모양 둘 다 다르게).
 * `size` 는 점의 지름(◆ 는 같은 칸 안에 맞춘다).
 */
@Composable
fun SeatDot(agent: Boolean, size: Dp = 8.dp, modifier: Modifier = Modifier) {
    val colors = LocalHandeColors.current
    val color = if (agent) colors.agent else colors.person
    if (agent && colors.isDay) {
        Box(modifier.size(size), contentAlignment = Alignment.Center) {
            Box(Modifier.size(size * 0.72f).rotate(45f).background(color))
        }
    } else {
        val glow = agent && !colors.isDay
        Box(
            modifier
                .size(size)
                .drawBehind { if (glow) drawCircle(color.copy(alpha = 0.30f), radius = this.size.minDimension * 0.9f) }
                .clip(CircleShape)
                .background(color),
        )
    }
}

/**
 * 「오늘의 불 세기」 1~3단 불꽃(숫자 없음) — 2차-B 아이콘 `flame-1/2/3`(`HandeIcons.flame`). 1단 = 가운데 불꽃만, 2단 = 가운데+왼쪽, 3단 = 셋 다.
 * 켜진 갈래 = 채움(밤 ember/ember-deep · 낮불 먹), 꺼진 갈래 = 선만. `dim`(꺼진 자리)이면 켜진 갈래도 `ash`. 접근성 문구는 `contentDescription` 으로(조용함/보통/활발).
 */
@Composable
fun FlameIcon(level: Int, dim: Boolean, size: Dp = 26.dp, contentDescription: String? = null, modifier: Modifier = Modifier) {
    val colors = LocalHandeColors.current
    val icon = remember(colors, level, dim) { HandeIcons.flame(level, colors, dim) }
    Icon(imageVector = icon, contentDescription = contentDescription, modifier = modifier.size(size), tint = Color.Unspecified)
}

/** 꺼진 자리의 장작 — 2차-B 아이콘 `embers-out`(선 1.6, `ash`). */
@Composable
fun LogIcon(size: Dp = 24.dp, modifier: Modifier = Modifier) {
    val colors = LocalHandeColors.current
    val icon = remember(colors) { HandeIcons.embersOut(colors) }
    Icon(imageVector = icon, contentDescription = null, modifier = modifier.size(size), tint = Color.Unspecified)
}
