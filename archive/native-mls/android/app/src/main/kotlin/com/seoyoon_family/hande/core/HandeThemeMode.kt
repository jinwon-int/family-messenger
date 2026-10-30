// 화면 테마 모드(한데 디자인 1차, docs/design/hande-tokens.json): 밤(기본·고정 — 시스템 라이트 모드를 따르지 않는다) · 낮불(e-ink·밝은 곳, 설정에서 고른다).
// Compose 의존 없음 — `Settings.theme` 의 키 ↔ enum 변환만. JVM 테스트 `HandeThemeModeTest`.
package com.seoyoon_family.hande.core

enum class HandeThemeMode(val key: String) {
    NIGHT("night"),
    DAY("day");

    companion object {
        /** 저장된 키 → 모드. 없거나 모르는 값은 밤(기본). */
        fun fromKey(key: String?): HandeThemeMode {
            val k = key?.trim()?.lowercase() ?: return NIGHT
            return entries.firstOrNull { it.key == k } ?: NIGHT
        }
    }
}
