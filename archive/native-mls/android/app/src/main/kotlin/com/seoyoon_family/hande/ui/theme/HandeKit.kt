// 한데 디자인 2차-A(2026-10-31) 공용 조각 — iOS `OnboardingKit.swift`·`Theme.swift` 의 Material 3 판(docs/design/HANDE-DESIGN-SYSTEM.md §A1~A6).
// 3차-A(Android Material 3 관용구): 입력 칸 = M3 `OutlinedTextField`(56dp · 반경 14 · 떠 있는 라벨 · 포커스 2dp 크림 · 오류 = isError + supportingText) ·
//   버튼 = M3 `Button`/`OutlinedButton`/`TextButton`(높이 48 · 알약 = M3 기본 모양) · 화면 고르기 = `SingleChoiceSegmentedButtonRow`(40dp) — 색은 전부 토큰(`LocalHandeColors`).
// 2차-B(낮불 세부): 비활성 = 투명도 대신 종이 면 + 회색 #8A8178 선·글자(원문 점선 — M3 `BorderStroke` 는 점선을 못 그려 실선 1.5, 문서화) · 표시 원 = 먹 채움 + 종이 ✓ ·
//   표시 행 면 #EFE9DC + 굵게 · 경고 상자 2px + 네모 표지 · 링크 밑줄 600 · 토스트 먹 면 + 종이 글자. 눌림 색은 M3 리플(토큰 `pressed` 는 직접 그리는 곳용).
// 새 의존성 없음: Compose 안정 API 만 쓴다(ModalBottomSheet 같은 실험 API 는 쓰지 않는다; SegmentedButton 은 material3 1.3 에서 안정).
package com.seoyoon_family.hande.ui.theme

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.RowScope
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.defaultMinSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.OutlinedTextFieldDefaults
import androidx.compose.material3.SegmentedButton
import androidx.compose.material3.SegmentedButtonDefaults
import androidx.compose.material3.SingleChoiceSegmentedButtonRow
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.StrokeJoin
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.drawscope.scale
import androidx.compose.ui.graphics.vector.PathParser
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.input.VisualTransformation
import androidx.compose.ui.text.style.TextDecoration
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.TextUnit
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.em
import androidx.compose.ui.unit.sp
import com.seoyoon_family.hande.ui.Strings

/** 반경 토큰(M 16) — `HandeShapes.medium` 과 같은 값. */
private val KitRadiusM: Dp = 16.dp

/** 낮불 표시 행 면(2차-B: 표시한 행은 #EFE9DC + 굵게). */
private val DayTickedRow: Color = Color(0xFFEFE9DC)

// ---- 온보딩 조각(§A2) ----

/** 상단 진행 막대: `of` 칸 · 4dp · 반경 2 · 켜짐 = 불, 꺼짐 = #FFBF78 18%(낮불은 불 25%). 접근성 「4단계 중 n단계」. */
@Composable
fun StepBar(step: Int, of: Int = 4, modifier: Modifier = Modifier) {
    val colors = LocalHandeColors.current
    val off = if (colors.isDay) colors.ember.copy(alpha = 0.25f) else Color(0xFFFFBF78).copy(alpha = 0.18f)
    val label = Strings.onboardingStep(step, of)
    Row(
        modifier.fillMaxWidth().semantics(mergeDescendants = true) { contentDescription = label },
        horizontalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        repeat(of) { i ->
            Box(Modifier.weight(1f).height(4.dp).clip(RoundedCornerShape(2.dp)).background(if (i < step) colors.ember else off))
        }
    }
}

/** 워드마크 `hande`: Questrial 은 번들하지 않으므로 시스템 산세리프 가는 굵기 + 자간 0.04em. */
@Composable
fun HandeWordmark(size: TextUnit = 30.sp, modifier: Modifier = Modifier) {
    Text(
        Strings.wordmark, modifier,
        color = LocalHandeColors.current.ink, fontSize = size, fontFamily = FontFamily.SansSerif, fontWeight = FontWeight.Light, letterSpacing = 0.04.em,
    )
}

/** 온보딩 제목 28/600(두 줄 허용). */
@Composable
fun OnboardingTitle(text: String, modifier: Modifier = Modifier) {
    Text(text, modifier, color = LocalHandeColors.current.ink, fontSize = 28.sp, lineHeight = 35.sp, fontWeight = FontWeight.SemiBold)
}

/** 카드·목록 위 라벨 13/500 보조색(입력 칸의 라벨은 M3 떠 있는 라벨이 맡는다). */
@Composable
fun FieldLabel(text: String, modifier: Modifier = Modifier) {
    Text(text, modifier.padding(horizontal = 4.dp), color = LocalHandeColors.current.inkDim, fontSize = 13.sp, fontWeight = FontWeight.Medium)
}

/**
 * 입력 칸(3차-A): M3 `OutlinedTextField` 56dp · 반경 14 · 라벨이 선 위에 뜸(12~13sp) · 포커스 2dp 크림 #FFD79A(낮불 먹) · 평소 선 outline(#FFBF78 40% / 낮불 먹 1dp) ·
 * 커서 불(낮불 먹) · 오류 = `isError` + `supportingText` 주의 글자색(#F08A70 / 낮불 #A8321C) · 비활성 = 회색 선·글자. 모노 선택 · 비밀 값(점) 선택. 자동 대문자 없음.
 * 도움말(`supporting`)은 오류가 없을 때만 보조색으로 아래에.
 */
@Composable
fun HandeOutlinedField(
    value: String,
    onValueChange: (String) -> Unit,
    label: String,
    modifier: Modifier = Modifier,
    placeholder: String? = null,
    mono: Boolean = false,
    error: String? = null,
    supporting: String? = null,
    secure: Boolean = false,
    enabled: Boolean = true,
    keyboardType: KeyboardType = KeyboardType.Text,
    onDone: (() -> Unit)? = null,
) {
    val c = LocalHandeColors.current
    val outline = MaterialTheme.colorScheme.outline
    val family = if (mono) FontFamily.Monospace else FontFamily.Default
    val help = error ?: supporting
    OutlinedTextField(
        value = value,
        onValueChange = onValueChange,
        modifier = modifier.fillMaxWidth(),
        enabled = enabled,
        textStyle = TextStyle(fontSize = 17.sp, fontFamily = family),
        label = { Text(label) },
        placeholder = placeholder?.let { { Text(it, fontFamily = family, maxLines = 1, overflow = TextOverflow.Ellipsis) } },
        supportingText = help?.let { { Text(it, fontSize = 13.sp, lineHeight = 18.sp) } },
        isError = error != null,
        visualTransformation = if (secure) PasswordVisualTransformation() else VisualTransformation.None,
        keyboardOptions = KeyboardOptions(
            capitalization = KeyboardCapitalization.None,
            keyboardType = if (secure) KeyboardType.Password else keyboardType,
            imeAction = if (onDone != null) ImeAction.Done else ImeAction.Default,
        ),
        keyboardActions = KeyboardActions(onDone = { onDone?.invoke() }),
        singleLine = true,
        shape = RoundedCornerShape(14.dp),
        colors = OutlinedTextFieldDefaults.colors(
            focusedTextColor = c.ink, unfocusedTextColor = c.ink, disabledTextColor = c.disabledText, errorTextColor = c.ink,
            focusedContainerColor = Color.Transparent, unfocusedContainerColor = Color.Transparent,
            disabledContainerColor = Color.Transparent, errorContainerColor = Color.Transparent,
            cursorColor = if (c.isDay) c.ink else c.ember, errorCursorColor = if (c.isDay) c.ink else c.ember,
            focusedBorderColor = c.focus, unfocusedBorderColor = outline, disabledBorderColor = c.disabledStroke, errorBorderColor = c.warn,
            focusedLabelColor = c.focus, unfocusedLabelColor = c.inkDim, disabledLabelColor = c.disabledText, errorLabelColor = c.warnText,
            focusedPlaceholderColor = c.inkDim, unfocusedPlaceholderColor = c.inkDim, disabledPlaceholderColor = c.disabledText, errorPlaceholderColor = c.inkDim,
            focusedSupportingTextColor = c.inkDim, unfocusedSupportingTextColor = c.inkDim, disabledSupportingTextColor = c.disabledText, errorSupportingTextColor = c.warnText,
        ),
    )
}

/** 카드: 반경 16 · 면 + 선(기본 토큰; 선언 카드·오류 카드는 색·굵기를 넘긴다). 안은 세로 배치. */
@Composable
fun HandeCard(
    modifier: Modifier = Modifier,
    fill: Color? = null,
    stroke: Color? = null,
    lineWidth: Dp? = null,
    padding: Dp = 14.dp,
    content: @Composable ColumnScope.() -> Unit,
) {
    val colors = LocalHandeColors.current
    val shape = RoundedCornerShape(KitRadiusM)
    Column(
        modifier
            .fillMaxWidth()
            .clip(shape)
            .background(fill ?: colors.surface)
            .border(lineWidth ?: colors.lineWidth, stroke ?: colors.stroke, shape)
            .padding(padding),
        content = content,
    )
}

/**
 * 1줄 안내 + 「자세히」(불 색 링크 — 낮불은 먹 + 밑줄 600, 펼치면 「접기」) → 아래로 펼침(시트 아님, 3차-A). 설명은 1줄 + 자세히 규칙(2차-A). `hint` 가 null 이면 링크만.
 */
@Composable
fun DetailDisclosure(hint: String?, detail: String, modifier: Modifier = Modifier, hintSize: TextUnit = 14.sp, hintColor: Color? = null) {
    val colors = LocalHandeColors.current
    var expanded by rememberSaveable { mutableStateOf(false) }
    val lineHeight = hintSize * 1.45f
    Column(modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Row(Modifier.padding(horizontal = 4.dp), verticalAlignment = Alignment.Top) {
            if (hint != null) {
                Text(hint, Modifier.weight(1f, fill = false), color = hintColor ?: colors.inkDim, fontSize = hintSize, lineHeight = lineHeight)
                Spacer(Modifier.width(6.dp))
            }
            Text(
                if (expanded) Strings.onboardingLess else Strings.onboardingMore,
                Modifier.clip(RoundedCornerShape(6.dp)).clickable(role = Role.Button) { expanded = !expanded }.padding(horizontal = 2.dp),
                color = if (colors.isDay) colors.ink else colors.ember, fontSize = hintSize, lineHeight = lineHeight,
                fontWeight = if (colors.isDay) FontWeight.SemiBold else FontWeight.Medium,
                textDecoration = if (colors.isDay) TextDecoration.Underline else null,
            )
        }
        if (expanded) {
            HandeCard(padding = 12.dp) { Text(detail, color = colors.inkDim, fontSize = 14.sp, lineHeight = 21.sp) }
        }
    }
}

// ---- 지문 1열(§A1 ①) ----

/**
 * 지문 1열: 행 42dp · 번호 13(28dp 칸) · 값 모노 19 자간 .06em(`HandeType.fingerprint`). `ticked` 를 주면 행마다 눌러 표시(표시 원 22dp, 표시된 행 면 불 8% — 낮불 #EFE9DC + 굵게).
 * 등록 화면(표시 없음)과 승인 화면(표시 있음)이 같은 행·같은 번호를 보인다. 접근성 「N번, 값, 맞춤 표시 됨/안 됨」.
 */
@Composable
fun FingerprintList(
    rows: List<String>,
    modifier: Modifier = Modifier,
    ticked: Set<Int>? = null,
    enabled: Boolean = true,
    onToggle: ((Int) -> Unit)? = null,
) {
    val colors = LocalHandeColors.current
    val shape = RoundedCornerShape(KitRadiusM)
    Column(modifier.fillMaxWidth().clip(shape).background(colors.surface).border(colors.lineWidth, colors.stroke, shape)) {
        rows.forEachIndexed { index, value ->
            if (index > 0) Box(Modifier.fillMaxWidth().height(colors.lineWidth).background(colors.stroke))
            val on: Boolean? = ticked?.contains(index)
            val label = Strings.fingerprintRowLabel(index + 1, value, on)
            val tap = if (ticked != null && onToggle != null) Modifier.clickable(enabled = enabled, role = Role.Checkbox) { onToggle(index) } else Modifier
            val rowFill = when {
                on != true -> Color.Transparent
                colors.isDay -> DayTickedRow
                else -> colors.ember.copy(alpha = 0.08f)
            }
            Row(
                Modifier
                    .fillMaxWidth()
                    .height(42.dp)
                    .then(tap)
                    .background(rowFill)
                    .padding(horizontal = 14.dp)
                    .semantics(mergeDescendants = true) { contentDescription = label },
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Text("${index + 1}", Modifier.width(28.dp), color = colors.inkDim, fontSize = 13.sp)
                Text(
                    value, Modifier.weight(1f), color = colors.ink, style = HandeType.fingerprint,
                    fontWeight = if (on == true && colors.isDay) FontWeight.Bold else FontWeight.Normal, maxLines = 1, overflow = TextOverflow.Ellipsis,
                )
                if (on != null) TickCircle(on)
            }
        }
    }
}

/** 표시 원 22dp: 빈 원(먹 45% · 1.5dp — 낮불 먹) / 켜짐(불 채움 + ✓ 불 위 글자 — 낮불 먹 채움 + 종이 ✓: 주황은 주 버튼 1곳). */
@Composable
fun TickCircle(on: Boolean, modifier: Modifier = Modifier) {
    val colors = LocalHandeColors.current
    val ring = if (colors.isDay) colors.ink else colors.ink.copy(alpha = 0.45f)
    val fill = if (colors.isDay) colors.ink else colors.ember
    val mark = if (colors.isDay) colors.bgTop else colors.onEmber
    Box(
        modifier.size(22.dp).drawBehind {
            if (on) {
                drawCircle(fill)
            } else {
                val w = 1.5.dp.toPx()
                drawCircle(ring, radius = size.minDimension / 2f - w / 2f, style = Stroke(width = w))
            }
        },
        contentAlignment = Alignment.Center,
    ) {
        if (on) Text("✓", color = mark, fontSize = 12.sp, fontWeight = FontWeight.Bold)
    }
}

/** 점 N개(고정 — #601: 움직이는 점은 일하는 중을 암시하므로 대기 문구 옆에는 고정). */
@Composable
fun DotsRow(color: Color, size: Dp = 6.dp, count: Int = 3, modifier: Modifier = Modifier) {
    Row(modifier, horizontalArrangement = Arrangement.spacedBy(size / 2), verticalAlignment = Alignment.CenterVertically) {
        repeat(count) { Box(Modifier.size(size).clip(CircleShape).background(color)) }
    }
}

// ---- 버튼(3차-A: M3 Button/OutlinedButton/TextButton — 알약은 M3 기본 모양, 높이 48; 글자 labelLarge 15) ----

@Composable
private fun ButtonLabel(text: String, weight: FontWeight, size: TextUnit = 15.sp) {
    Text(text, fontSize = size, fontWeight = weight, letterSpacing = 0.01.em, maxLines = 1, overflow = TextOverflow.Ellipsis)
}

/**
 * 주 버튼 = M3 Filled 48dp: 불 면 + 불 위 글자 15/600(낮불 700 + 먹 선 1.5). 꺼짐 = 면 불 18% · 글자 45%(흐림 대신 색으로 — `enabled = false`; 낮불 종이 면 + 회색 선·글자)
 * + `disabledText`(예: 「8줄을 모두 맞춰 보세요」). 눌림은 M3 리플.
 */
@Composable
fun PrimaryButton(text: String, modifier: Modifier = Modifier, enabled: Boolean = true, height: Dp = 48.dp, disabledText: String? = null, onClick: () -> Unit) {
    val c = LocalHandeColors.current
    Button(
        onClick = onClick,
        modifier = modifier.fillMaxWidth().height(height),
        enabled = enabled,
        colors = ButtonDefaults.buttonColors(
            containerColor = c.ember, contentColor = c.onEmber,
            disabledContainerColor = c.disabledFill, disabledContentColor = c.disabledText,
        ),
        border = when {
            !c.isDay -> null
            enabled -> BorderStroke(c.lineWidth, c.stroke)
            else -> BorderStroke(c.lineWidth, c.disabledStroke)
        },
    ) {
        ButtonLabel(if (enabled) text else (disabledText ?: text), if (c.isDay) FontWeight.Bold else FontWeight.SemiBold)
    }
}

/** 보조 버튼 = M3 Outlined 48dp: 선 #FFBF78 40%(낮불 흰 면 + 먹 1.5) · 글자 15/500. `icon` 을 주면 글자 앞에(「등록 정보 공유」의 share). */
@Composable
fun SecondaryButton(text: String, modifier: Modifier = Modifier, enabled: Boolean = true, height: Dp = 48.dp, icon: (@Composable () -> Unit)? = null, onClick: () -> Unit) {
    val c = LocalHandeColors.current
    val outline = MaterialTheme.colorScheme.outline
    OutlinedButton(
        onClick = onClick,
        modifier = modifier.fillMaxWidth().height(height),
        enabled = enabled,
        colors = ButtonDefaults.outlinedButtonColors(
            containerColor = if (c.isDay) c.surface else Color.Transparent, contentColor = c.ink,
            disabledContainerColor = if (c.isDay) c.disabledFill else Color.Transparent, disabledContentColor = c.disabledText,
        ),
        border = BorderStroke(c.lineWidth, if (!enabled) c.disabledStroke else if (c.isDay) c.stroke else outline),
    ) {
        if (icon != null) {
            icon()
            Spacer(Modifier.width(8.dp))
        }
        ButtonLabel(text, FontWeight.Medium)
    }
}

/** 위험 버튼 = M3 Outlined + error 색 46dp(「다릅니다」·「이 기기 지우기」): 면 warn 8% · 선 1.5dp warn 60% · 글자 주의색 15/600. 낮불 = 흰 면 + 2px #A8321C + 같은 글자. */
@Composable
fun DangerButton(text: String, modifier: Modifier = Modifier, enabled: Boolean = true, height: Dp = 46.dp, onClick: () -> Unit) {
    val c = LocalHandeColors.current
    OutlinedButton(
        onClick = onClick,
        modifier = modifier.fillMaxWidth().height(height),
        enabled = enabled,
        colors = ButtonDefaults.outlinedButtonColors(
            containerColor = if (c.isDay) c.surface else c.warn.copy(alpha = 0.08f), contentColor = c.warnText,
            disabledContainerColor = if (c.isDay) c.disabledFill else Color.Transparent,
            disabledContentColor = if (c.isDay) c.disabledText else c.warnText.copy(alpha = 0.4f),
        ),
        border = BorderStroke(
            if (c.isDay) 2.dp else 1.5.dp,
            when {
                !enabled -> if (c.isDay) c.disabledStroke else c.warn.copy(alpha = 0.25f)
                c.isDay -> c.warn
                else -> c.warn.copy(alpha = 0.6f)
            },
        ),
    ) {
        ButtonLabel(text, FontWeight.SemiBold)
    }
}

/** 크림 면 주 버튼 52dp(로그인 — 화면의 할 일이 하나라 주황 대신 크림 면 + 진한 글자 16/600, 알약 반경 26). 낮불 = 흰 면 + 2px 먹 + 먹 글자(2차-B). */
@Composable
fun CreamButton(text: String, modifier: Modifier = Modifier, enabled: Boolean = true, onClick: () -> Unit) {
    val c = LocalHandeColors.current
    Button(
        onClick = onClick,
        modifier = modifier.fillMaxWidth().height(52.dp),
        enabled = enabled,
        colors = ButtonDefaults.buttonColors(
            containerColor = if (c.isDay) c.surface else c.ink, contentColor = if (c.isDay) c.ink else c.onEmber,
            disabledContainerColor = if (c.isDay) c.disabledFill else c.ink.copy(alpha = 0.18f), disabledContentColor = c.disabledText,
        ),
        border = if (c.isDay) BorderStroke(2.dp, if (enabled) c.stroke else c.disabledStroke) else null,
    ) {
        ButtonLabel(text, FontWeight.SemiBold, 16.sp)
    }
}

/** 글자 링크 = M3 TextButton(「자세히」·「복사」·「등록 확인」): 불 색 글자 15/500 — 낮불은 먹 + 밑줄 600(색 대신). 터치 높이 40. */
@Composable
fun LinkButton(text: String, modifier: Modifier = Modifier, size: TextUnit = 15.sp, enabled: Boolean = true, color: Color? = null, onClick: () -> Unit) {
    val c = LocalHandeColors.current
    TextButton(
        onClick = onClick,
        modifier = modifier,
        enabled = enabled,
        colors = ButtonDefaults.textButtonColors(contentColor = color ?: (if (c.isDay) c.ink else c.ember), disabledContentColor = c.disabledText),
        contentPadding = PaddingValues(horizontal = 8.dp, vertical = 4.dp),
    ) {
        Text(
            text, fontSize = size, fontWeight = if (c.isDay) FontWeight.SemiBold else FontWeight.Medium,
            textDecoration = if (c.isDay) TextDecoration.Underline else null, maxLines = 1, overflow = TextOverflow.Ellipsis,
        )
    }
}

// ---- 설정 칸(§A5) ----

/** 칸 머리 14/500 강조색 — M3 관례대로 강조색(여기선 크림 `person` — 주황은 행동에만; 낮불 먹). 위험 구역은 `color = warnText`. */
@Composable
fun SectionHeader(text: String, modifier: Modifier = Modifier, color: Color? = null) {
    Text(
        text, modifier.fillMaxWidth().padding(start = 20.dp, end = 20.dp, bottom = 8.dp),
        color = color ?: LocalHandeColors.current.person, fontSize = 14.sp, fontWeight = FontWeight.Medium, letterSpacing = 0.02.em,
    )
}

/** 칸 카드(좌우 16 여백 · 반경 16 · 면 + 선) — 안에 `SectionRow` 를 쌓는다. */
@Composable
fun SectionCard(modifier: Modifier = Modifier, content: @Composable ColumnScope.() -> Unit) {
    val c = LocalHandeColors.current
    val shape = RoundedCornerShape(KitRadiusM)
    Column(modifier.fillMaxWidth().padding(horizontal = 16.dp).clip(shape).background(c.surface).border(c.lineWidth, c.stroke, shape), content = content)
}

/** 칸 행(M3 ListItem 크기): 높이 56 이상 · 좌우 16 · 위에 구분선(첫 행은 `divider = false`). `onClick` 을 주면 행 전체가 눌린다. */
@Composable
fun SectionRow(divider: Boolean = true, onClick: (() -> Unit)? = null, modifier: Modifier = Modifier, content: @Composable RowScope.() -> Unit) {
    val c = LocalHandeColors.current
    Column(modifier.fillMaxWidth()) {
        if (divider) Box(Modifier.fillMaxWidth().height(c.lineWidth).background(c.stroke))
        Row(
            Modifier
                .fillMaxWidth()
                .then(if (onClick != null) Modifier.clickable(onClick = onClick) else Modifier)
                .defaultMinSize(minHeight = 56.dp)
                .padding(horizontal = 16.dp, vertical = 8.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(12.dp),
            content = content,
        )
    }
}

/** 오른쪽(›) / 아래(⌄) 꺾쇠 16dp — 행 끝·접힘 표시. 이미지 리소스 없이 선으로 그린다. */
@Composable
fun Chevron(down: Boolean = false, modifier: Modifier = Modifier, color: Color? = null) {
    val tint = color ?: LocalHandeColors.current.inkDim
    Canvas(modifier.size(16.dp)) {
        val w = size.width
        val h = size.height
        val p = Path()
        if (down) {
            p.moveTo(w * 0.25f, h * 0.38f); p.lineTo(w * 0.5f, h * 0.62f); p.lineTo(w * 0.75f, h * 0.38f)
        } else {
            p.moveTo(w * 0.38f, h * 0.25f); p.lineTo(w * 0.62f, h * 0.5f); p.lineTo(w * 0.38f, h * 0.75f)
        }
        drawPath(p, tint, style = Stroke(width = 2.dp.toPx(), cap = StrokeCap.Round, join = StrokeJoin.Round))
    }
}

/**
 * 밤/낮불 고르기 = M3 `SingleChoiceSegmentedButtonRow` 40dp: 선택 = ✓(M3 기본 아이콘) + 불 22% 면 + 크림 글자 14/600 · 선 #FFBF78 40%.
 * 낮불 = 먹 면 + 종이 글자 + ✓ · 먹 선 1.5 · 반경 12(알약 아님 — 2차-B).
 */
@Composable
fun HandeSegmented(options: List<String>, selected: Int, modifier: Modifier = Modifier, onSelect: (Int) -> Unit) {
    val c = LocalHandeColors.current
    val border = if (c.isDay) c.stroke else MaterialTheme.colorScheme.outline
    val colors = SegmentedButtonDefaults.colors(
        activeContainerColor = if (c.isDay) c.ink else c.ember.copy(alpha = 0.22f),
        activeContentColor = if (c.isDay) c.bgTop else c.person,
        activeBorderColor = border,
        inactiveContainerColor = Color.Transparent,
        inactiveContentColor = c.ink,
        inactiveBorderColor = border,
    )
    SingleChoiceSegmentedButtonRow(modifier.fillMaxWidth().height(40.dp)) {
        options.forEachIndexed { i, label ->
            val on = i == selected
            SegmentedButton(
                selected = on,
                onClick = { onSelect(i) },
                shape = if (c.isDay) SegmentedButtonDefaults.itemShape(index = i, count = options.size, baseShape = RoundedCornerShape(12.dp))
                else SegmentedButtonDefaults.itemShape(index = i, count = options.size),
                colors = colors,
                border = SegmentedButtonDefaults.borderStroke(border, c.lineWidth),
                label = { Text(label, fontSize = 14.sp, fontWeight = if (on) FontWeight.SemiBold else FontWeight.Medium) },
            )
        }
    }
}

// ---- 경고 · 배너 · 토스트 ----

/** 경고 상자: 선 1.5dp warn 55% · 면 7% · 점 8dp + 글자 15/500. 낮불 = 흰 면 + 2px #A8321C + 네모 표지 9dp(사람 ●·에이전트 ◆와 다른 모양) + 글자 600. 문구 고정, 닫기 없음. */
@Composable
fun WarnBox(text: String, modifier: Modifier = Modifier) {
    val c = LocalHandeColors.current
    val shape = RoundedCornerShape(14.dp)
    Row(
        modifier
            .fillMaxWidth()
            .clip(shape)
            .background(if (c.isDay) c.surface else c.warn.copy(alpha = 0.07f))
            .border(if (c.isDay) 2.dp else 1.5.dp, if (c.isDay) c.warn else c.warn.copy(alpha = 0.55f), shape)
            .padding(horizontal = 14.dp, vertical = 12.dp),
        horizontalArrangement = Arrangement.spacedBy(10.dp),
        verticalAlignment = Alignment.Top,
    ) {
        if (c.isDay) {
            Box(Modifier.padding(top = 7.dp).size(9.dp).background(c.warn))
        } else {
            Box(Modifier.padding(top = 7.dp).size(8.dp).clip(CircleShape).background(c.warn))
        }
        Text(text, color = c.ink, fontSize = 15.sp, lineHeight = 22.sp, fontWeight = if (c.isDay) FontWeight.SemiBold else FontWeight.Medium)
    }
}

/** 배너(반경 12): 연결 중 = 면 7% + 선 · 주의(`warn = true`) = warn 10% 면 + 선 45%(낮불 흰 면 + 2px). 점 3개 + 글자 14. */
@Composable
fun HandeBanner(text: String, warn: Boolean = false, modifier: Modifier = Modifier) {
    val c = LocalHandeColors.current
    val shape = RoundedCornerShape(12.dp)
    Row(
        modifier
            .fillMaxWidth()
            .clip(shape)
            .background(if (warn && !c.isDay) c.warn.copy(alpha = 0.10f) else c.surface)
            .border(
                if (warn && c.isDay) 2.dp else c.lineWidth,
                if (warn) (if (c.isDay) c.warn else c.warn.copy(alpha = 0.45f)) else c.stroke,
                shape,
            )
            .padding(horizontal = 14.dp, vertical = 9.dp),
        horizontalArrangement = Arrangement.spacedBy(10.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        DotsRow(if (warn) c.warn else c.person)
        Text(text, color = c.ink, fontSize = 14.sp, fontWeight = if (warn && c.isDay) FontWeight.SemiBold else FontWeight.Normal)
    }
}

/** 토스트 한 줄(「복사했어요」 등): 면 surfaceContainerHigh #1C2136 + 따뜻한 선 30% · 반경 20(2차-B). 낮불 = 먹 면 + 종이 글자, 선 없음. 사라짐은 호출처가(`NoticeHost`). */
@Composable
fun HandeToast(text: String, modifier: Modifier = Modifier) {
    val c = LocalHandeColors.current
    val shape = RoundedCornerShape(20.dp)
    Box(
        modifier
            .padding(12.dp)
            .fillMaxWidth()
            .clip(shape)
            .background(if (c.isDay) c.ink else MaterialTheme.colorScheme.surfaceContainerHigh)
            .then(if (c.isDay) Modifier else Modifier.border(1.dp, Color(0xFFFFBF78).copy(alpha = 0.30f), shape))
            .padding(horizontal = 16.dp, vertical = 11.dp),
    ) {
        Text(text, color = if (c.isDay) c.bgTop else c.ink, fontSize = 14.sp)
    }
}

// ---- 빈 상태 그림(§A3) ----

/** 디자인 원문 SVG(96×64): 꺼진 장작 2 + 가지 2(선 3, `ash`) + 남은 불씨 1점(불 70%) + 둘러앉을 자리 점 2(크림·파랑 50%). 불 그림은 목록 빈 상태에만. */
private const val EMPTY_LOGS_PATH = "M18 50h60M22 58h52M30 46l14-12M66 46L52 34"

@Composable
fun EmptyCampfireArt(modifier: Modifier = Modifier) {
    val c = LocalHandeColors.current
    val logs = remember { PathParser().parsePathString(EMPTY_LOGS_PATH).toPath() }
    Canvas(modifier.size(96.dp, 64.dp)) {
        val s = size.width / 96f
        scale(s, s, pivot = Offset.Zero) {
            drawPath(logs, c.ash, style = Stroke(width = 3f, cap = StrokeCap.Round))
            drawCircle(c.ember.copy(alpha = 0.7f), radius = 3f, center = Offset(48f, 30f))
            drawCircle(c.person.copy(alpha = 0.5f), radius = 4f, center = Offset(20f, 40f))
            drawCircle(c.agent.copy(alpha = 0.5f), radius = 4f, center = Offset(76f, 40f))
        }
    }
}
