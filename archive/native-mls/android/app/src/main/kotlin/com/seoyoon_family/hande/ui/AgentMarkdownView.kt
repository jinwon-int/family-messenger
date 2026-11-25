// 에이전트 말풍선의 마크다운 표시(#887 1단계) — 웹 `ui.js markdownBlock` · `styles.css .body.md` 와 같은 구성.
// 파서(`core/AgentMarkdown`)가 돌려준 문자열을 Text 로만 그린다: 받은 글을 HTML·그림으로 해석하지 않고, 링크는 파서가 걸러 준 http(s) 주소뿐이다.
// 큰 글자 설정에서 잘리지 않게 높이를 고정하지 않는다(#886) — 글자 크기는 sp, 간격만 dp. 낮불은 투명도 없이 선·면으로 구분한다.
// 범위(#887): 1단계 = 제목 · 문단 · 목록 · 인용 · 구분선 · 코드 블록 · 줄 안 굵게/기울임/취소선/코드/링크. 2단계 = 표(열 너비를 내용에 맞추고 넘치면 가로 스크롤).
// 스킬 칩은 3단계.
package com.seoyoon_family.hande.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.layout.Layout
import androidx.compose.ui.layout.layout
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.LinkAnnotation
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.TextLinkStyles
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.style.TextDecoration
import androidx.compose.ui.unit.Constraints
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.seoyoon_family.hande.core.AgentMarkdown
import com.seoyoon_family.hande.ui.theme.HandeColors
import com.seoyoon_family.hande.ui.theme.LocalHandeColors

/**
 * 서식 글 말풍선의 안쪽: 블록을 위에서 아래로. [modifier] 는 말풍선 모양(면·선·안쪽 여백)이다 — 호출하는 쪽이 평문 말풍선과 같은 것을 넘긴다.
 * 블록마다 그릴 글은 `remember` 로 붙잡는다(긴 대화에서 다시 그릴 때마다 줄 안 서식을 다시 나누지 않게).
 */
@Composable
internal fun AgentMarkdownBody(blocks: List<AgentMarkdown.Block>, modifier: Modifier = Modifier, textColor: Color = LocalHandeColors.current.ink) {
    val colors = LocalHandeColors.current
    val base = MaterialTheme.typography.bodyLarge
    Column(modifier, verticalArrangement = Arrangement.spacedBy(8.dp)) {
        blocks.forEachIndexed { index, block ->
            when (block) {
                is AgentMarkdown.Block.Heading -> {
                    // 웹과 같이 3단계까지만 크기를 나눈다(4~6 은 3 과 같다). 셋째 단계는 에이전트 글자색으로 구분.
                    val level = minOf(block.level, 3)
                    Text(
                        remember(block, colors) { inlineText(block.text, colors) },
                        // 앞에 다른 블록이 있으면 제목 위를 조금 더 띄운다.
                        Modifier.padding(top = if (index > 0) 4.dp else 0.dp).semantics { heading() },
                        color = if (level == 3) colors.agentText else textColor,
                        style = base.copy(
                            fontWeight = FontWeight.Bold,
                            fontSize = when (level) { 1 -> 21.sp; 2 -> 19.sp; else -> 17.sp },
                            lineHeight = when (level) { 1 -> 28.sp; 2 -> 26.sp; else -> 24.sp },
                        ),
                    )
                }
                is AgentMarkdown.Block.Paragraph -> Text(remember(block, colors) { inlineText(block.text, colors) }, color = textColor, style = base)
                is AgentMarkdown.Block.Items -> Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                    for (item in block.items) {
                        // 들여쓰기 단계(0~4)마다 16dp. 표시(• 또는 `1.`)와 글은 첫 줄 기준선을 맞춘다 — 글이 여러 줄이어도 표시는 첫 줄 옆.
                        Row(Modifier.padding(start = (16 * item.level).dp)) {
                            Text(item.marker ?: "•", Modifier.alignByBaseline().widthIn(min = 18.dp), color = colors.agentText, style = base, textAlign = TextAlign.End)
                            Spacer(Modifier.width(8.dp))
                            Text(remember(item, colors) { inlineText(item.text, colors) }, Modifier.alignByBaseline().weight(1f, fill = false), color = textColor, style = base)
                        }
                    }
                }
                is AgentMarkdown.Block.Quote -> Text(
                    remember(block, colors) { inlineText(block.text, colors) },
                    // 왼쪽 세로줄 3dp(글 높이만큼 — 높이를 따로 재지 않고 글 뒤에 그린다) + 보조 글자색.
                    Modifier.drawBehind { drawRect(colors.agent, size = Size(3.dp.toPx(), size.height)) }.padding(start = 12.dp),
                    color = colors.inkDim, style = base,
                )
                AgentMarkdown.Block.Rule -> Box(Modifier.fillMaxWidth().height(colors.lineWidth).background(colors.stroke))
                is AgentMarkdown.Block.Code -> CodeBlock(block.text, colors, textColor)
                is AgentMarkdown.Block.Table -> TableBlock(block, colors, textColor)
            }
        }
    }
}

/**
 * 코드 블록: 고정폭 · 줄바꿈 없이 그대로 · 말풍선보다 넓으면 그 안에서 가로 스크롤(면 + 선으로 구분 — 낮불도 같은 구성).
 * 넘치지 않는 블록은 스크롤을 켜지 않는다 — 그래야 그 위에서 시작한 「밀어서 답장」(#880)이 그대로 동작한다.
 */
@Composable
private fun CodeBlock(text: String, colors: HandeColors, textColor: Color) {
    val scroll = rememberScrollState()
    val shape = RoundedCornerShape(8.dp)
    Box(
        Modifier
            .clip(shape)
            .background(colors.pressed)
            .border(colors.lineWidth, colors.stroke, shape)
            // maxValue 는 첫 배치 전에는 Int.MAX_VALUE — 재어 본 뒤 실제로 넘칠 때만 켠다.
            .horizontalScroll(scroll, enabled = scroll.maxValue in 1 until Int.MAX_VALUE)
            .padding(horizontal = 10.dp, vertical = 8.dp),
    ) {
        Text(text, color = textColor, softWrap = false, fontFamily = FontFamily.Monospace, fontSize = 14.sp, lineHeight = 20.sp)
    }
}

/** 글 한 덩어리(문단·제목·목록 항목·인용·표 칸) → 서식과 링크를 입힌 글. 토막 나누기는 `AgentMarkdown.runs`(순수 로직, JVM 테스트). */
private fun inlineText(text: String, colors: HandeColors): AnnotatedString = buildAnnotatedString { appendRuns(text, colors) }

private fun AnnotatedString.Builder.appendRuns(text: String, colors: HandeColors) {
    for (run in AgentMarkdown.runs(text)) {
        if (run.text.isEmpty()) continue
        val start = length
        append(run.text)
        if (run.strong || run.em || run.del || run.code) {
            addStyle(
                SpanStyle(
                    fontWeight = if (run.strong) FontWeight.Bold else null,
                    fontStyle = if (run.em) FontStyle.Italic else null,
                    textDecoration = if (run.del) TextDecoration.LineThrough else null,
                    color = if (run.del) colors.inkDim else Color.Unspecified,
                    fontFamily = if (run.code) FontFamily.Monospace else null,
                    // 줄 안 코드는 면으로 구분(낮불 #E9E4DA 불투명 · 밤 흰 13%).
                    background = if (run.code) colors.pressed else Color.Unspecified,
                ),
                start, length,
            )
        }
        run.href?.let { href ->
            // 평문 말풍선의 링크와 같은 모양(밑줄). 취소선 안의 링크는 두 줄을 함께 긋는다.
            val line = if (run.del) TextDecoration.combine(listOf(TextDecoration.Underline, TextDecoration.LineThrough)) else TextDecoration.Underline
            addLink(LinkAnnotation.Url(href, TextLinkStyles(SpanStyle(textDecoration = line))), start, length)
        }
    }
}

/** 표 글자: 본문보다 한 단계 작게(웹 `--text-s` 와 같은 뜻) — 좁은 화면에서 열이 하나라도 더 들어가게. 크기는 sp 라 큰 글자 설정을 따른다. */
private val TableFontSize = 15.sp
private val TableLineHeight = 21.sp
/** 한 열의 최대 너비 = 글자 14자 분량(+ 칸 안쪽 여백). 그보다 긴 칸은 그 열 안에서 줄바꿈한다 — 긴 칸 하나가 표 전체를 옆으로 밀지 않게. */
private const val TableColumnEms = 14

/**
 * 표(#887 2단계): 열 너비는 내용에 맞추고(`AgentMarkdown.columnWidths` — 한 열은 14자 분량까지, 자리가 남으면 더 준다), 행 높이는 그 행에서 가장 큰 칸.
 * 말풍선보다 넓으면 그 안에서 가로 스크롤한다. 머리 행 = 면 + 굵게, 칸 사이는 선(낮불도 같은 구성 — 투명도 없이 선·면).
 * 높이를 고정하지 않는다(#886): 칸 높이는 글에서 나온다. 열·행 상한(8 · 60)과 넘친 행의 `…` 행은 파서가 이미 정리해 준다.
 * 넘치지 않는 표는 스크롤을 켜지 않는다 — 코드 블록과 같이, 그 위에서 시작한 「밀어서 답장」(#880)이 그대로 동작하게.
 */
@Composable
private fun TableBlock(table: AgentMarkdown.Block.Table, colors: HandeColors, textColor: Color) {
    val columns = table.header.size
    // 머리 행 + 본문 행. 파서가 모든 행을 머리 폭에 맞춰 주므로(`normalize`) 칸 수는 행마다 같다.
    val cells = remember(table, colors) { (listOf(table.header) + table.rows).map { row -> row.map { inlineText(it, colors) } } }
    val style = MaterialTheme.typography.bodyLarge.copy(fontSize = TableFontSize, lineHeight = TableLineHeight)
    val headerStyle = remember(style) { style.copy(fontWeight = FontWeight.Bold) }
    val cap = with(LocalDensity.current) { (TableFontSize.toPx() * TableColumnEms).toInt() + (CellPadH * 2).roundToPx() }
    val scroll = rememberScrollState()
    val shape = RoundedCornerShape(8.dp)
    // 말풍선 안에서 쓸 수 있는 너비. 가로 스크롤 안쪽은 너비 제한이 없어 알 수 없으므로, 스크롤 바깥에서 받은 제한을 적어 두고 안쪽 배치가 읽는다
    // (같은 배치 단계에서 바깥이 먼저 재어지므로 값은 늘 최신이고, 제한이 바뀌면 안쪽도 다시 잰다).
    var available by remember { mutableIntStateOf(Int.MAX_VALUE) }
    Layout(
        content = {
            cells.forEachIndexed { r, row ->
                row.forEachIndexed { c, text ->
                    TableCell(
                        text = text, header = r == 0, lastColumn = c == columns - 1, lastRow = r == cells.size - 1,
                        colors = colors, textColor = textColor, style = if (r == 0) headerStyle else style,
                    )
                }
            }
        },
        modifier = Modifier
            .layout { measurable, constraints ->
                available = if (constraints.hasBoundedWidth) constraints.maxWidth else Int.MAX_VALUE
                val placeable = measurable.measure(constraints)
                layout(placeable.width, placeable.height) { placeable.place(0, 0) }
            }
            .clip(shape)
            .border(colors.lineWidth, colors.stroke, shape)
            .horizontalScroll(scroll, enabled = scroll.maxValue in 1 until Int.MAX_VALUE),
    ) { measurables, _ ->
        val rows = measurables.size / columns
        // 열의 내용 너비 = 그 열 칸들의 「줄바꿈 없이 그렸을 때」 너비 중 가장 큰 것.
        val natural = IntArray(columns) { c -> (0 until rows).maxOf { r -> measurables[r * columns + c].maxIntrinsicWidth(Constraints.Infinity) } }
        val widths = AgentMarkdown.columnWidths(natural, cap, available)
        val heights = IntArray(rows) { r -> (0 until columns).maxOf { c -> measurables[r * columns + c].minIntrinsicHeight(widths[c]) } }
        val placeables = measurables.mapIndexed { i, m -> m.measure(Constraints.fixed(widths[i % columns], heights[i / columns])) }
        layout(widths.sum(), heights.sum()) {
            var y = 0
            for (r in 0 until rows) {
                var x = 0
                for (c in 0 until columns) {
                    placeables[r * columns + c].place(x, y)
                    x += widths[c]
                }
                y += heights[r]
            }
        }
    }
}

private val CellPadH = 10.dp
private val CellPadV = 6.dp

/** 표의 한 칸: 안쪽 여백 + 글. 오른쪽·아래 칸과의 사이에만 선을 긋는다(바깥 테두리는 표가 그린다). 칸 안의 줄 안 서식·링크는 그대로. */
@Composable
private fun TableCell(text: AnnotatedString, header: Boolean, lastColumn: Boolean, lastRow: Boolean, colors: HandeColors, textColor: Color, style: TextStyle) {
    Box(
        Modifier
            .then(if (header) Modifier.background(colors.pressed) else Modifier)
            .drawBehind {
                val line = colors.lineWidth.toPx()
                if (!lastColumn) drawRect(colors.stroke, topLeft = Offset(size.width - line, 0f), size = Size(line, size.height))
                if (!lastRow) drawRect(colors.stroke, topLeft = Offset(0f, size.height - line), size = Size(size.width, line))
            }
            .padding(horizontal = CellPadH, vertical = CellPadV),
    ) {
        Text(text, color = textColor, style = style)
    }
}
