// 에이전트 말풍선 아래의 스킬 칩 줄(#887 3단계, 웹 `ui.js skillChips` · `styles.css .skill-chips` 와 같은 구성).
// 이름은 `core/AgentSkills.split` 이 거른 식별자뿐이고 Text 로만 그린다. 칩이 많으면 여러 줄로 넘어간다.
// 높이를 고정하지 않는다(#886) — 글자 크기는 sp, 간격만 dp. 낮불은 투명도 없이 면 + 선.
package com.seoyoon_family.hande.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.layout.Layout
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Constraints
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.seoyoon_family.hande.ui.theme.LocalHandeColors

/**
 * 답이 쓴 스킬들: `📘 이름` 알약을 왼쪽부터 놓고 자리가 모자라면 다음 줄로 넘긴다. 이름 하나가 줄보다 길면 말줄임.
 * 색은 에이전트 말풍선과 같은 짝(밤 = 파랑 10% 면 + 35% 선 · 낮불 = 흰 면 + 파랑 선).
 */
@Composable
internal fun AgentSkillChips(skills: List<String>, modifier: Modifier = Modifier) {
    val colors = LocalHandeColors.current
    val shape = RoundedCornerShape(50)
    val chip = if (colors.isDay) {
        Modifier.background(colors.surface).border(colors.lineWidth, colors.agent, shape)
    } else {
        Modifier.background(colors.agent.copy(alpha = 0.10f)).border(1.dp, colors.agent.copy(alpha = 0.35f), shape)
    }
    WrapRow(
        modifier.semantics(mergeDescendants = true) { contentDescription = Strings.skillsLabel(skills) },
        gap = 4.dp,
    ) {
        for (name in skills) {
            Text(
                "📘 $name",
                Modifier.clip(shape).then(chip).padding(horizontal = 8.dp, vertical = 2.dp),
                color = colors.agentText, fontSize = 13.sp, lineHeight = 18.sp, maxLines = 1, overflow = TextOverflow.Ellipsis,
            )
        }
    }
}

/**
 * 왼쪽부터 놓고 넘치면 줄을 바꾸는 배치(Compose 의 FlowRow 는 아직 실험 API 라 쓰지 않는다 — 필요한 것은 이것뿐이다).
 * 칸마다 줄 너비까지만 재므로, 줄보다 긴 칸은 제 안에서 말줄임한다.
 */
@Composable
private fun WrapRow(modifier: Modifier, gap: Dp, content: @Composable () -> Unit) {
    Layout(content = content, modifier = modifier) { measurables, constraints ->
        val gapPx = gap.roundToPx()
        val maxWidth = constraints.maxWidth
        val placeables = measurables.map { it.measure(Constraints(maxWidth = maxWidth)) }
        val xs = IntArray(placeables.size)
        val ys = IntArray(placeables.size)
        var x = 0
        var y = 0
        var rowHeight = 0
        var width = 0
        placeables.forEachIndexed { i, placeable ->
            if (x > 0 && x + placeable.width > maxWidth) {
                x = 0
                y += rowHeight + gapPx
                rowHeight = 0
            }
            xs[i] = x
            ys[i] = y
            x += placeable.width + gapPx
            rowHeight = maxOf(rowHeight, placeable.height)
            width = maxOf(width, x - gapPx)
        }
        layout(width.coerceIn(constraints.minWidth, maxWidth), maxOf(y + rowHeight, constraints.minHeight)) {
            placeables.forEachIndexed { i, placeable -> placeable.place(xs[i], ys[i]) }
        }
    }
}
