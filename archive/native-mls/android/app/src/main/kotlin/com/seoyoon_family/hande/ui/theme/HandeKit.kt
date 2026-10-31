// 한데 디자인 2차-A(2026-10-31) 공용 조각 — iOS `OnboardingKit.swift`·`Theme.swift` 의 Material 3 판(docs/design/HANDE-DESIGN-SYSTEM.md §A1~A6).
// 진행 막대 4칸(3dp) · 워드마크 · 제목 28/600 · 입력 칸 52dp/반경 14 · 카드 반경 16 · 「자세히」 접힘 · 지문 1열(행 42dp, 번호 13 + 모노 19, 표시 원 22dp) ·
// 주/보조/위험/크림 버튼 · 설정 칸(머리·카드·행) · 경고 상자 · 배너 · 토스트 · 밤/낮불 칩 · 빈 상태 그림. 색은 전부 `LocalHandeColors` 토큰 — 낮불에서도 그대로 동작.
// 새 의존성 없음: BasicTextField·Canvas·PathParser 등 Compose 안정 API 만 쓴다(ModalBottomSheet 같은 실험 API 는 쓰지 않는다).
package com.seoyoon_family.hande.ui.theme

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.RowScope
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.defaultMinSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.selection.selectable
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.SolidColor
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
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.TextUnit
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.em
import androidx.compose.ui.unit.sp
import com.seoyoon_family.hande.ui.Strings

/** 반경 토큰(S 10 · M 16) — `HandeShapes` 와 같은 값. */
private val KitRadiusS: Dp = 10.dp
private val KitRadiusM: Dp = 16.dp

// ---- 온보딩 조각(§A2) ----

/** 상단 진행 막대: `of` 칸 · 3dp · 반경 2 · 켜짐 = 불, 꺼짐 = #FFBF78 18%(낮불은 불 25%). 접근성 「4단계 중 n단계」. */
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
            Box(Modifier.weight(1f).height(3.dp).clip(RoundedCornerShape(2.dp)).background(if (i < step) colors.ember else off))
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

/** 입력 칸 위 라벨 13/500 보조색. */
@Composable
fun FieldLabel(text: String, modifier: Modifier = Modifier) {
    Text(text, modifier.padding(horizontal = 4.dp), color = LocalHandeColors.current.inkDim, fontSize = 13.sp, fontWeight = FontWeight.Medium)
}

/**
 * 입력 칸: 52dp · 반경 14 · 면 + 선(불 30%, 낮불은 먹; 형식 오류면 warn 1.5dp) · 모노 선택 · 비밀 값(점) 선택. 자동 대문자 없음.
 * M3 `OutlinedTextField` 대신 `BasicTextField` — 라벨이 떠다니지 않고 높이·선 색을 토큰대로 둘 수 있다.
 */
@Composable
fun HandeField(
    value: String,
    onValueChange: (String) -> Unit,
    modifier: Modifier = Modifier,
    placeholder: String? = null,
    mono: Boolean = false,
    invalid: Boolean = false,
    secure: Boolean = false,
    enabled: Boolean = true,
    keyboardType: KeyboardType = KeyboardType.Text,
    onDone: (() -> Unit)? = null,
) {
    val colors = LocalHandeColors.current
    val shape = RoundedCornerShape(14.dp)
    val family = if (mono) FontFamily.Monospace else FontFamily.Default
    val strokeColor = when {
        invalid -> colors.warn
        colors.isDay -> colors.stroke
        else -> colors.ember.copy(alpha = 0.3f)
    }
    val strokeWidth = if (invalid) 1.5.dp else colors.lineWidth
    BasicTextField(
        value = value,
        onValueChange = onValueChange,
        modifier = modifier.fillMaxWidth(),
        enabled = enabled,
        singleLine = true,
        textStyle = TextStyle(color = colors.ink, fontSize = 17.sp, fontFamily = family),
        keyboardOptions = KeyboardOptions(
            capitalization = KeyboardCapitalization.None,
            keyboardType = if (secure) KeyboardType.Password else keyboardType,
            imeAction = if (onDone != null) ImeAction.Done else ImeAction.Default,
        ),
        keyboardActions = KeyboardActions(onDone = { onDone?.invoke() }),
        visualTransformation = if (secure) PasswordVisualTransformation() else VisualTransformation.None,
        cursorBrush = SolidColor(colors.ember),
        decorationBox = { inner ->
            Box(
                Modifier
                    .alpha(if (enabled) 1f else 0.6f)
                    .fillMaxWidth()
                    .height(52.dp)
                    .clip(shape)
                    .background(colors.surface)
                    .border(strokeWidth, strokeColor, shape)
                    .padding(horizontal = 16.dp),
                contentAlignment = Alignment.CenterStart,
            ) {
                if (value.isEmpty() && placeholder != null) {
                    Text(placeholder, color = colors.inkDim, fontSize = 17.sp, fontFamily = family, maxLines = 1, overflow = TextOverflow.Ellipsis)
                }
                inner()
            }
        },
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

/** 1줄 안내 + 「자세히」(불 색 링크, 펼치면 「접기」) → 아래 카드(14sp 보조색). 설명은 1줄 + 자세히 규칙(2차-A). `hint` 가 null 이면 링크만. */
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
                color = colors.ember, fontSize = hintSize, lineHeight = lineHeight, fontWeight = FontWeight.Medium,
            )
        }
        if (expanded) {
            HandeCard(padding = 12.dp) { Text(detail, color = colors.inkDim, fontSize = 14.sp, lineHeight = 21.sp) }
        }
    }
}

// ---- 지문 1열(§A1 ①) ----

/**
 * 지문 1열: 행 42dp · 번호 13(28dp 칸) · 값 모노 19. `ticked` 를 주면 행마다 눌러 표시(표시 원 22dp, 표시된 행 면 불 8%).
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
            Row(
                Modifier
                    .fillMaxWidth()
                    .height(42.dp)
                    .then(tap)
                    .background(if (on == true) colors.ember.copy(alpha = 0.08f) else Color.Transparent)
                    .padding(horizontal = 14.dp)
                    .semantics(mergeDescendants = true) { contentDescription = label },
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Text("${index + 1}", Modifier.width(28.dp), color = colors.inkDim, fontSize = 13.sp)
                Text(value, Modifier.weight(1f), color = colors.ink, fontSize = 19.sp, fontFamily = FontFamily.Monospace, maxLines = 1, overflow = TextOverflow.Ellipsis)
                if (on != null) TickCircle(on)
            }
        }
    }
}

/** 표시 원 22dp: 빈 원(먹 45% · 1.5dp) / 켜짐(불 채움 + ✓ 불 위 글자). */
@Composable
fun TickCircle(on: Boolean, modifier: Modifier = Modifier) {
    val colors = LocalHandeColors.current
    val ring = colors.ink.copy(alpha = 0.45f)
    Box(
        modifier.size(22.dp).drawBehind {
            if (on) {
                drawCircle(colors.ember)
            } else {
                val w = 1.5.dp.toPx()
                drawCircle(ring, radius = size.minDimension / 2f - w / 2f, style = Stroke(width = w))
            }
        },
        contentAlignment = Alignment.Center,
    ) {
        if (on) Text("✓", color = colors.onEmber, fontSize = 12.sp, fontWeight = FontWeight.Bold)
    }
}

/** 점 N개(고정 — #601: 움직이는 점은 일하는 중을 암시하므로 대기 문구 옆에는 고정). */
@Composable
fun DotsRow(color: Color, size: Dp = 6.dp, count: Int = 3, modifier: Modifier = Modifier) {
    Row(modifier, horizontalArrangement = Arrangement.spacedBy(size / 2), verticalAlignment = Alignment.CenterVertically) {
        repeat(count) { Box(Modifier.size(size).clip(CircleShape).background(color)) }
    }
}

// ---- 버튼 ----

@Composable
private fun KitButton(
    text: String,
    modifier: Modifier,
    enabled: Boolean,
    height: Dp,
    fill: Color,
    textColor: Color,
    stroke: Color?,
    strokeWidth: Dp,
    fontSize: TextUnit,
    weight: FontWeight,
    disabledAlpha: Float,
    onClick: () -> Unit,
) {
    val shape = RoundedCornerShape(KitRadiusM)
    Box(
        modifier
            .fillMaxWidth()
            .alpha(if (enabled) 1f else disabledAlpha)
            .height(height)
            .clip(shape)
            .background(fill)
            .then(if (stroke != null) Modifier.border(strokeWidth, stroke, shape) else Modifier)
            .clickable(enabled = enabled, role = Role.Button, onClick = onClick),
        contentAlignment = Alignment.Center,
    ) {
        Text(
            text, Modifier.padding(horizontal = 12.dp),
            color = textColor, fontSize = fontSize, fontWeight = weight, textAlign = TextAlign.Center, maxLines = 1, overflow = TextOverflow.Ellipsis,
        )
    }
}

/** 주 버튼 52dp: 불 면 + 불 위 글자 17/600. 꺼짐 = 면 불 18% · 글자 45%(흐림 대신 색으로) + `disabledText`(예: 「8줄을 모두 맞춰 보세요」). */
@Composable
fun PrimaryButton(text: String, modifier: Modifier = Modifier, enabled: Boolean = true, height: Dp = 52.dp, disabledText: String? = null, onClick: () -> Unit) {
    val c = LocalHandeColors.current
    KitButton(
        text = if (enabled) text else (disabledText ?: text), modifier = modifier, enabled = enabled, height = height,
        fill = if (enabled) c.ember else c.ember.copy(alpha = 0.18f),
        textColor = if (enabled) c.onEmber else c.ink.copy(alpha = 0.45f),
        stroke = if (c.isDay) c.stroke else null, strokeWidth = c.lineWidth,
        fontSize = 17.sp, weight = FontWeight.SemiBold, disabledAlpha = 1f, onClick = onClick,
    )
}

/** 보조 버튼 48dp: 면 + 선 · 글자 17/500. */
@Composable
fun SecondaryButton(text: String, modifier: Modifier = Modifier, enabled: Boolean = true, height: Dp = 48.dp, onClick: () -> Unit) {
    val c = LocalHandeColors.current
    KitButton(
        text = text, modifier = modifier, enabled = enabled, height = height, fill = c.surface, textColor = c.ink,
        stroke = c.stroke, strokeWidth = c.lineWidth, fontSize = 17.sp, weight = FontWeight.Medium, disabledAlpha = 0.45f, onClick = onClick,
    )
}

/** 위험 버튼 46dp(「다릅니다」·「이 기기 지우기」): 면 warn 8% · 선 1.5dp warn 60% · 글자 warn 16/600. */
@Composable
fun DangerButton(text: String, modifier: Modifier = Modifier, enabled: Boolean = true, height: Dp = 46.dp, onClick: () -> Unit) {
    val c = LocalHandeColors.current
    KitButton(
        text = text, modifier = modifier, enabled = enabled, height = height, fill = c.warn.copy(alpha = 0.08f), textColor = c.warn,
        stroke = c.warn.copy(alpha = 0.6f), strokeWidth = 1.5.dp, fontSize = 16.sp, weight = FontWeight.SemiBold, disabledAlpha = 0.45f, onClick = onClick,
    )
}

/** 크림 면 주 버튼 52dp(로그인 — 화면의 할 일이 하나라 주황 대신 크림 면 + 진한 글자). 낮불은 불 면. */
@Composable
fun CreamButton(text: String, modifier: Modifier = Modifier, enabled: Boolean = true, onClick: () -> Unit) {
    val c = LocalHandeColors.current
    KitButton(
        text = text, modifier = modifier, enabled = enabled, height = 52.dp, fill = if (c.isDay) c.ember else c.ink, textColor = c.onEmber,
        stroke = if (c.isDay) c.stroke else null, strokeWidth = c.lineWidth, fontSize = 17.sp, weight = FontWeight.SemiBold, disabledAlpha = 0.45f, onClick = onClick,
    )
}

/** 불 색 글자 링크(「자세히」·「복사」·「등록 확인」). 터치 높이 36 이상. */
@Composable
fun LinkButton(text: String, modifier: Modifier = Modifier, size: TextUnit = 15.sp, enabled: Boolean = true, color: Color? = null, onClick: () -> Unit) {
    val c = LocalHandeColors.current
    Box(
        modifier
            .clip(RoundedCornerShape(8.dp))
            .clickable(enabled = enabled, role = Role.Button, onClick = onClick)
            .defaultMinSize(minHeight = 36.dp)
            .padding(horizontal = 4.dp)
            .alpha(if (enabled) 1f else 0.45f),
        contentAlignment = Alignment.Center,
    ) {
        Text(text, color = color ?: c.ember, fontSize = size, fontWeight = FontWeight.Medium)
    }
}

// ---- 설정 칸(§A5) ----

/** 칸 머리 13/600 보조색(위험 구역은 warn). */
@Composable
fun SectionHeader(text: String, modifier: Modifier = Modifier, color: Color? = null) {
    Text(
        text, modifier.fillMaxWidth().padding(start = 20.dp, end = 20.dp, bottom = 8.dp),
        color = color ?: LocalHandeColors.current.inkDim, fontSize = 13.sp, fontWeight = FontWeight.SemiBold, letterSpacing = 0.02.em,
    )
}

/** 칸 카드(좌우 16 여백 · 반경 16 · 면 + 선) — 안에 `SectionRow` 를 쌓는다. */
@Composable
fun SectionCard(modifier: Modifier = Modifier, content: @Composable ColumnScope.() -> Unit) {
    val c = LocalHandeColors.current
    val shape = RoundedCornerShape(KitRadiusM)
    Column(modifier.fillMaxWidth().padding(horizontal = 16.dp).clip(shape).background(c.surface).border(c.lineWidth, c.stroke, shape), content = content)
}

/** 칸 행: 높이 48 이상 · 좌우 16 · 위에 구분선(첫 행은 `divider = false`). `onClick` 을 주면 행 전체가 눌린다. */
@Composable
fun SectionRow(divider: Boolean = true, onClick: (() -> Unit)? = null, modifier: Modifier = Modifier, content: @Composable RowScope.() -> Unit) {
    val c = LocalHandeColors.current
    Column(modifier.fillMaxWidth()) {
        if (divider) Box(Modifier.fillMaxWidth().height(c.lineWidth).background(c.stroke))
        Row(
            Modifier
                .fillMaxWidth()
                .then(if (onClick != null) Modifier.clickable(onClick = onClick) else Modifier)
                .defaultMinSize(minHeight = 48.dp)
                .padding(horizontal = 16.dp, vertical = 10.dp),
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

/** 밤/낮불 칩 탭: 높이 36 · 반경 10 · 켜짐 = 불 면 + 불 위 글자(낮불은 먹 선). 바깥 반경 12 · 글자색 5% 면. */
@Composable
fun ChipTabs(options: List<String>, selected: Int, modifier: Modifier = Modifier, onSelect: (Int) -> Unit) {
    val c = LocalHandeColors.current
    Row(
        modifier.fillMaxWidth().clip(RoundedCornerShape(12.dp)).background(c.ink.copy(alpha = 0.05f)).padding(3.dp),
        horizontalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        options.forEachIndexed { i, label ->
            val on = i == selected
            val shape = RoundedCornerShape(KitRadiusS)
            Box(
                Modifier
                    .weight(1f)
                    .height(36.dp)
                    .clip(shape)
                    .background(if (on) c.ember else Color.Transparent)
                    .then(if (on && c.isDay) Modifier.border(c.lineWidth, c.stroke, shape) else Modifier)
                    .selectable(selected = on, role = Role.Tab) { onSelect(i) },
                contentAlignment = Alignment.Center,
            ) {
                Text(label, color = if (on) c.onEmber else c.inkDim, fontSize = 15.sp, fontWeight = if (on) FontWeight.SemiBold else FontWeight.Normal)
            }
        }
    }
}

// ---- 경고 · 배너 · 토스트 ----

/** 경고 상자: 선 1.5dp warn 55% · 면 7% · 점 8dp + 글자 15/500. 문구 고정, 닫기 없음. */
@Composable
fun WarnBox(text: String, modifier: Modifier = Modifier) {
    val c = LocalHandeColors.current
    val shape = RoundedCornerShape(14.dp)
    Row(
        modifier.fillMaxWidth().clip(shape).background(c.warn.copy(alpha = 0.07f)).border(1.5.dp, c.warn.copy(alpha = 0.55f), shape).padding(horizontal = 14.dp, vertical = 12.dp),
        horizontalArrangement = Arrangement.spacedBy(10.dp),
        verticalAlignment = Alignment.Top,
    ) {
        Box(Modifier.padding(top = 7.dp).size(8.dp).clip(CircleShape).background(c.warn))
        Text(text, color = c.ink, fontSize = 15.sp, lineHeight = 22.sp, fontWeight = FontWeight.Medium)
    }
}

/** 배너(반경 12): 연결 중 = 면 7% + 선 · 주의(`warn = true`) = warn 10% 면 + 선 45%. 점 3개 + 글자 14. */
@Composable
fun HandeBanner(text: String, warn: Boolean = false, modifier: Modifier = Modifier) {
    val c = LocalHandeColors.current
    val shape = RoundedCornerShape(12.dp)
    Row(
        modifier
            .fillMaxWidth()
            .clip(shape)
            .background(if (warn) c.warn.copy(alpha = 0.10f) else c.surface)
            .border(c.lineWidth, if (warn) c.warn.copy(alpha = 0.45f) else c.stroke, shape)
            .padding(horizontal = 14.dp, vertical = 9.dp),
        horizontalArrangement = Arrangement.spacedBy(10.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        DotsRow(if (warn) c.warn else c.person)
        Text(text, color = c.ink, fontSize = 14.sp)
    }
}

/** 토스트 한 줄(「복사했어요」 등): 면 #1C2136(낮불은 종이 면) · 따뜻한 선 · 반경 12. 사라짐은 호출처가(`NoticeHost`). */
@Composable
fun HandeToast(text: String, modifier: Modifier = Modifier) {
    val c = LocalHandeColors.current
    val shape = RoundedCornerShape(12.dp)
    Box(
        modifier
            .padding(12.dp)
            .fillMaxWidth()
            .clip(shape)
            .background(if (c.isDay) c.surface else Color(0xFF1C2136))
            .border(c.lineWidth, c.stroke, shape)
            .padding(horizontal = 16.dp, vertical = 12.dp),
    ) {
        Text(text, color = c.ink, fontSize = 15.sp)
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
