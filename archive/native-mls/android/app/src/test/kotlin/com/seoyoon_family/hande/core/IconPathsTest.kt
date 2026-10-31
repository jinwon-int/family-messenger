// 한데 고유 UI 아이콘 경로 정본 고정(2차-B B2): 14종 · 경로 비어 있지 않음 · 불 세기 켜진 갈래 수 = 단계 · 자리 점 5(사람 3 · 에이전트 2).
// Android 런타임 없이 JVM 에서 돈다(ImageVector 를 만드는 `HandeIcons` 는 Compose 라 여기서 못 돌린다 — `d` 문자열만 고정).
package com.seoyoon_family.hande.core

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

class IconPathsTest {
    @Test fun fourteenIconsWithNonEmptyPaths() {
        assertEquals(14, IconPaths.all.size)
        assertEquals(
            listOf(
                "flame-1", "flame-2", "flame-3", "embers-out", "keeper", "fingerprint-rows",
                "device-iphone", "device-android", "device-pc", "device-web", "seat", "invite-bell", "reorder", "cover",
            ),
            IconPaths.all.keys.toList(),
            "docs/design/icons/ui/hande-<id>.svg 와 같은 id·순서",
        )
        for ((id, parts) in IconPaths.all) {
            assertTrue(parts.isNotEmpty(), id)
            for (p in parts) {
                assertTrue(p.d.isNotBlank(), "$id: 빈 경로")
                assertTrue(p.d.startsWith("M"), "$id: 경로는 M 으로 시작 — ${p.d}")
                assertTrue(!p.d.contains('"') && !p.d.contains('<'), "$id: SVG 마크업이 섞임 — ${p.d}")
            }
        }
    }

    @Test fun flameLitCountEqualsLevel() {
        for (level in 1..3) {
            val parts = IconPaths.flame(level)
            assertEquals(3, parts.size)
            assertEquals(level, parts.count { it.role != IconPaths.ROLE_UNLIT }, "불 세기 $level")
        }
        assertEquals(IconPaths.ROLE_EMBER, IconPaths.flame(1)[1].role, "1단은 가운데만")
        assertEquals(IconPaths.ROLE_EMBER_DEEP, IconPaths.flame(2)[0].role, "2단은 가운데+왼쪽")
        assertEquals(IconPaths.ROLE_UNLIT, IconPaths.flame(2)[2].role)
        assertEquals(IconPaths.flame(3), IconPaths.flame(9), "범위 밖은 3단으로")
        assertEquals(IconPaths.flame(1), IconPaths.flame(0))
    }

    @Test fun seatHasFivePersonAndAgentDotsAndTwoDayDiamonds() {
        val fills = IconPaths.seat.filter { it.role != null }
        assertEquals(5, fills.size)
        assertEquals(3, fills.count { it.role == IconPaths.ROLE_PERSON })
        assertEquals(2, fills.count { it.role == IconPaths.ROLE_AGENT })
        assertEquals(2, IconPaths.seatAgentDiamonds.size, "낮불 ◆ 는 에이전트 점 수만큼")
        assertEquals(IconPaths.ROLE_AGENT, IconPaths.keeper.last().role, "불지기의 ◆ 불티는 agent 색")
    }
}
