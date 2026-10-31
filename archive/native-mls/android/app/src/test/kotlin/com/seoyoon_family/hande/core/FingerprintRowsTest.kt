// 지문 행 만들기 고정(한데 디자인 2차-A §A1 ①) — iOS `FingerprintRows.make` 와 같은 규칙: 64 hex → 「xxxx xxxx」 8행, 같은 번호 순서.
// android.* 없이 JVM 에서 돈다.
package com.seoyoon_family.hande.core

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

class FingerprintRowsTest {
    private val hex = "0123456789abcdef".repeat(4) // 64 hex

    @Test fun sixtyFourHexMakesEightRowsOfTwoGroups() {
        val rows = FingerprintRows.make(hex)
        assertEquals(8, rows.size)
        for (row in rows) {
            assertEquals(9, row.length, "「xxxx xxxx」: $row")
            assertTrue(Regex("^[0-9a-f]{4} [0-9a-f]{4}$").matches(row), row)
        }
        assertEquals("0123 4567", rows[0])
        assertEquals("89ab cdef", rows[1])
        assertEquals(hex, FingerprintRows.join(rows), "행을 다시 붙이면 원래 hex")
    }

    @Test fun groupedFingerprintGivesTheSameRows() {
        // 공백·줄바꿈이 든 사람용 표기(4줄)를 넣어도 같은 행 — 등록 화면과 승인 화면이 같은 입력을 쓰지 않아도 어긋나지 않는다.
        assertEquals(FingerprintRows.make(hex), FingerprintRows.make(SelfService.groupedFingerprint(hex)))
        assertEquals(FingerprintRows.make(hex), FingerprintRows.make(" $hex\n"))
    }

    @Test fun shortInputIsNotPadded() {
        assertEquals(emptyList<String>(), FingerprintRows.make(""))
        assertEquals(emptyList<String>(), FingerprintRows.make("  \n"))
        assertEquals(listOf("abcd"), FingerprintRows.make("abcd"))
        assertEquals(listOf("abcd ef"), FingerprintRows.make("abcdef"))
        assertEquals(listOf("abcd ef01", "2345"), FingerprintRows.make("abcdef012345"))
    }
}
