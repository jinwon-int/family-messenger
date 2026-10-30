// 테마 키 ↔ 모드 변환 고정(한데 디자인 1차): 없거나 모르는 값은 밤(기본·고정). android.*·Compose 없이 JVM 에서 돈다.
package com.seoyoon_family.hande.core

import kotlin.test.Test
import kotlin.test.assertEquals

class HandeThemeModeTest {
    @Test fun nightIsTheDefault() {
        assertEquals(HandeThemeMode.NIGHT, HandeThemeMode.fromKey(null))
        assertEquals(HandeThemeMode.NIGHT, HandeThemeMode.fromKey(""))
        assertEquals(HandeThemeMode.NIGHT, HandeThemeMode.fromKey("night"))
        assertEquals(HandeThemeMode.NIGHT, HandeThemeMode.fromKey("garbage"))
    }

    @Test fun dayKeyRoundTrips() {
        assertEquals(HandeThemeMode.DAY, HandeThemeMode.fromKey("day"))
        assertEquals(HandeThemeMode.DAY, HandeThemeMode.fromKey(" Day "), "공백·대소문자는 너그럽게")
        for (mode in HandeThemeMode.entries) assertEquals(mode, HandeThemeMode.fromKey(mode.key))
    }
}
