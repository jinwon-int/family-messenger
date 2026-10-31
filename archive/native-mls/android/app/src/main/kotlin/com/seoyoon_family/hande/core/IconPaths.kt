// 한데 고유 UI 아이콘 세트(2차-B B2) 의 경로 정본 — `docs/design/icons/ui/hande-<id>.svg` 의 `d` 문자열을 글자 그대로 옮긴 것(24 뷰박스 · 선 1.6 · 둥근 끝).
// android.*·Compose 없음 → JVM 단위 테스트(`IconPathsTest`)로 14종·경로 비어 있지 않음을 고정한다. 그리는 쪽은 `ui/theme/HandeIcons.kt`(ImageVector).
// `role` = SVG 의 `data-role`: null 이면 선(currentColor), `unlit` 은 선만(밤 35% / 낮불 먹), 나머지는 역할색 채움(ember · ember-deep · person · agent · ink).
package com.seoyoon_family.hande.core

object IconPaths {
    const val ROLE_EMBER = "ember"
    const val ROLE_EMBER_DEEP = "ember-deep"
    const val ROLE_PERSON = "person"
    const val ROLE_AGENT = "agent"
    const val ROLE_INK = "ink"
    const val ROLE_UNLIT = "unlit"

    /** 경로 하나: `d` + 역할(null = 선). */
    data class Part(val d: String, val role: String? = null)

    // 불꽃 3갈래(왼쪽 · 가운데 · 오른쪽). 켜진 갈래 수 = 단계(1 = 가운데, 2 = 가운데+왼쪽, 3 = 모두).
    const val FLAME_LEFT = "M5.5 20.5c-1.7 0-2.7-1.2-2.7-2.8 0-1.9 1.6-3 2.7-5.2 1.1 2.2 2.7 3.3 2.7 5.2 0 1.6-1 2.8-2.7 2.8Z"
    const val FLAME_CENTER = "M12 20.5c-2.1 0-3.4-1.6-3.4-3.7 0-2.9 2.2-4.8 3.4-8.8 1.2 4 3.4 5.9 3.4 8.8 0 2.1-1.3 3.7-3.4 3.7Z"
    const val FLAME_RIGHT = "M18.5 20.5c-1.7 0-2.7-1.2-2.7-2.8 0-1.9 1.6-3 2.7-5.2 1.1 2.2 2.7 3.3 2.7 5.2 0 1.6-1 2.8-2.7 2.8Z"

    /** 불 세기 `level`(1~3)의 세 갈래 — 켜진 갈래는 역할색(가운데 ember · 양옆 ember-deep), 꺼진 갈래는 `unlit`. */
    fun flame(level: Int): List<Part> {
        val lv = level.coerceIn(1, 3)
        return listOf(
            Part(FLAME_LEFT, if (lv >= 2) ROLE_EMBER_DEEP else ROLE_UNLIT),
            Part(FLAME_CENTER, if (lv >= 1) ROLE_EMBER else ROLE_UNLIT),
            Part(FLAME_RIGHT, if (lv >= 3) ROLE_EMBER_DEEP else ROLE_UNLIT),
        )
    }

    val flame1: List<Part> = flame(1)
    val flame2: List<Part> = flame(2)
    val flame3: List<Part> = flame(3)

    /** 꺼진 자리(장작 둘 + 연기 둘). */
    val embersOut: List<Part> = listOf(
        Part("M3.5 19.5L20.5 14.5"),
        Part("M3.5 14.5L20.5 19.5"),
        Part("M2.1 19.5a1.4 1.4 0 1 0 2.8 0a1.4 1.4 0 1 0 -2.8 0Z"),
        Part("M19.1 14.5a1.4 1.4 0 1 0 2.8 0a1.4 1.4 0 1 0 -2.8 0Z"),
        Part("M12 11.5c-1.4-1.4 1.4-2.8 0-4.2"),
        Part("M15 10c-.9-.9.9-1.8 0-2.7"),
    )

    /** 불지기 — 사람 실루엣 + 작은 ◆ 불티(agent 채움). 로봇 얼굴 금지. */
    val keeper: List<Part> = listOf(
        Part("M6.8 8a3.2 3.2 0 1 0 6.4 0a3.2 3.2 0 1 0 -6.4 0Z"),
        Part("M4 20.5c0-3.7 2.7-6.2 6-6.2s6 2.5 6 6.2"),
        Part("M18.5 3.5l2 2-2 2-2-2Z", ROLE_AGENT),
    )

    /** 지문(대조) — 8행 묶음 모양(자물쇠·방패·생체 지문 곡선 금지). */
    val fingerprintRows: List<Part> = listOf(
        Part("M5 3.5h14a1.5 1.5 0 0 1 1.5 1.5v14a1.5 1.5 0 0 1-1.5 1.5H5A1.5 1.5 0 0 1 3.5 19V5A1.5 1.5 0 0 1 5 3.5Z"),
        Part("M7 7.5h4M13 7.5h4M7 10.5h4M13 10.5h4M7 13.5h4M13 13.5h4M7 16.5h4M13 16.5h4"),
    )

    private const val PHONE_BODY = "M8 3h8a2 2 0 0 1 2 2v14a2 2 0 0 1-2 2H8a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2Z"

    val deviceIphone: List<Part> = listOf(Part(PHONE_BODY), Part("M10.5 5.5h3"))
    val deviceAndroid: List<Part> = listOf(
        Part(PHONE_BODY),
        Part("M10 18.5h4"),
        Part("M11.1 6a0.9 0.9 0 1 0 1.8 0a0.9 0.9 0 1 0 -1.8 0Z", ROLE_INK),
    )
    val devicePc: List<Part> = listOf(
        Part("M5 4.5h14a1.5 1.5 0 0 1 1.5 1.5v8.5a1.5 1.5 0 0 1-1.5 1.5H5a1.5 1.5 0 0 1-1.5-1.5V6A1.5 1.5 0 0 1 5 4.5Z"),
        Part("M12 16v3.5M8.5 19.5h7"),
    )
    val deviceWeb: List<Part> = listOf(
        Part("M5 4.5h14a1.5 1.5 0 0 1 1.5 1.5v12a1.5 1.5 0 0 1-1.5 1.5H5A1.5 1.5 0 0 1 3.5 18V6A1.5 1.5 0 0 1 5 4.5Z"),
        Part("M3.5 8.5h17"),
        Part("M6.5 6.5h.01M9 6.5h.01"),
    )

    /** 자리(둘러앉음) — 작은 불 + 점 5(크림 · 파랑 교대). 낮불의 에이전트 점은 `seatAgentDiamonds`(◆)로 바꿔 그린다. */
    val seat: List<Part> = listOf(
        Part("M12 14.5c-1.3 0-2.1-.9-2.1-2.1 0-1.5 1.3-2.5 2.1-4.6.8 2.1 2.1 3.1 2.1 4.6 0 1.2-.8 2.1-2.1 2.1Z"),
        Part("M2.6 13.5a1.4 1.4 0 1 0 2.8 0a1.4 1.4 0 1 0 -2.8 0Z", ROLE_PERSON),
        Part("M5.199999999999999 18.5a1.4 1.4 0 1 0 2.8 0a1.4 1.4 0 1 0 -2.8 0Z", ROLE_AGENT),
        Part("M10.6 20.5a1.4 1.4 0 1 0 2.8 0a1.4 1.4 0 1 0 -2.8 0Z", ROLE_PERSON),
        Part("M15.999999999999998 18.5a1.4 1.4 0 1 0 2.8 0a1.4 1.4 0 1 0 -2.8 0Z", ROLE_AGENT),
        Part("M18.6 13.5a1.4 1.4 0 1 0 2.8 0a1.4 1.4 0 1 0 -2.8 0Z", ROLE_PERSON),
    )

    /** 낮불 `seat` 의 에이전트 점 ◆(원 중심 (6.6, 18.5) · (17.4, 18.5), 반지름 1.7 회전 네모) — SVG 원본의 `drawIcon` 치환 규칙과 같은 값. */
    val seatAgentDiamonds: List<String> = listOf("M6.6 16.8l1.7 1.7-1.7 1.7-1.7-1.7Z", "M17.4 16.8l1.7 1.7-1.7 1.7-1.7-1.7Z")

    val inviteBell: List<Part> = listOf(Part("M6 10a6 6 0 0 1 12 0v4l1.5 2.5h-15L6 14Z"), Part("M10 19.5a2 2 0 0 0 4 0"))
    val reorder: List<Part> = listOf(Part("M4 7h10M4 12h10M4 17h10"), Part("M19 5v14"), Part("M17 7l2-2 2 2M17 17l2 2 2-2"))
    val cover: List<Part> = listOf(
        Part("M4 16a8 8 0 0 1 16 0Z"),
        Part("M3 19h18"),
        Part("M12 8V6.5"),
        Part("M12 14c-.8 0-1.3-.5-1.3-1.2 0-.9.8-1.5 1.3-2.8.5 1.3 1.3 1.9 1.3 2.8 0 .7-.5 1.2-1.3 1.2Z"),
    )

    /** 14종 전부 — 키는 SVG 파일 이름의 `<id>`(`hande-<id>.svg`). */
    val all: Map<String, List<Part>> = linkedMapOf(
        "flame-1" to flame1,
        "flame-2" to flame2,
        "flame-3" to flame3,
        "embers-out" to embersOut,
        "keeper" to keeper,
        "fingerprint-rows" to fingerprintRows,
        "device-iphone" to deviceIphone,
        "device-android" to deviceAndroid,
        "device-pc" to devicePc,
        "device-web" to deviceWeb,
        "seat" to seat,
        "invite-bell" to inviteBell,
        "reorder" to reorder,
        "cover" to cover,
    )
}
