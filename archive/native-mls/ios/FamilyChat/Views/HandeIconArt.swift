// 한데 고유 UI 아이콘 세트의 path 정본(디자인 2차-B B2, 2026-10-31) — docs/design/icons/ui/*.svg 의 `d` 문자열을 그대로 복사했다.
// 24 뷰박스 · 선 1.6 둥근 끝/모서리 · `fill="none" stroke="currentColor"`. `data-role` 채움은 테마 토큰(ember/ember-deep/person/agent/ink)으로 칠한다
// (밤: 불 #F59E42 · 깊은 불 #E8833A · 크림 #FFD79A · 파랑 #61A6FA · 먹 / 낮불: ember·ember-deep·person·ink = 먹 #1A1510, agent = #2F6FC4).
// 불 세기: 켜진 갈래 = 채움, 꺼진 갈래 = 선만(밤 먹 35% / 낮불 먹 선). 1 = 가운데, 2 = 가운데+왼쪽, 3 = 모두.
// 낮불 `seat` 의 에이전트 점은 ◆(회전 네모 — 반대각 1.7)로 바꿔 그린다(`Fill.dayDiamond`).
// SwiftUI 없이 순수 데이터만 둔다(파서 SVGPathData 가 호 `a` 까지 읽으므로 Linux 에서도 검사 가능). 그리기는 Theme.swift HandeIconView.
import Foundation

enum HandeIconArt {
    /// `data-role` 채움색 역할.
    enum Role: Equatable, CaseIterable {
        case ember, emberDeep, person, agent, ink
    }

    /// 채움 path 하나. `dayDiamond` 가 있으면 낮불에서 그 path(◆)를 대신 그린다(seat 의 에이전트 점).
    struct Fill: Equatable {
        let d: String
        let role: Role
        var dayDiamond: String? = nil
    }

    /// 아이콘 하나 = 선 path 들 + 역할색 채움들.
    struct Icon: Equatable {
        let id: String
        let strokes: [String]
        var fills: [Fill] = []
        var paths: [String] { strokes + fills.map(\.d) + fills.compactMap(\.dayDiamond) }
    }

    /// 불꽃 세 갈래(왼쪽·가운데·오른쪽). `litFrom` 단계부터 켜진다(채움), 그 전엔 선만.
    struct Tongue: Equatable {
        let d: String
        let role: Role
        let litFrom: Int
    }

    // MARK: 불 세기(flame-1/2/3) — 갈래는 셋이 같은 모양, 단계마다 켜진 수만 다르다.

    static let flameLeft = "M5.5 20.5c-1.7 0-2.7-1.2-2.7-2.8 0-1.9 1.6-3 2.7-5.2 1.1 2.2 2.7 3.3 2.7 5.2 0 1.6-1 2.8-2.7 2.8Z"
    static let flameCenter = "M12 20.5c-2.1 0-3.4-1.6-3.4-3.7 0-2.9 2.2-4.8 3.4-8.8 1.2 4 3.4 5.9 3.4 8.8 0 2.1-1.3 3.7-3.4 3.7Z"
    static let flameRight = "M18.5 20.5c-1.7 0-2.7-1.2-2.7-2.8 0-1.9 1.6-3 2.7-5.2 1.1 2.2 2.7 3.3 2.7 5.2 0 1.6-1 2.8-2.7 2.8Z"

    /// 1 = 가운데, 2 = 가운데+왼쪽, 3 = 모두.
    static let tongues: [Tongue] = [
        Tongue(d: flameLeft, role: .emberDeep, litFrom: 2),
        Tongue(d: flameCenter, role: .ember, litFrom: 1),
        Tongue(d: flameRight, role: .emberDeep, litFrom: 3),
    ]

    // MARK: 그 밖의 아이콘

    /// 꺼진 자리: 엇갈린 장작 둘 + 둥근 끝 + 연기 두 줄.
    static let embersOut = Icon(id: "hande.embers-out", strokes: [
        "M3.5 19.5L20.5 14.5",
        "M3.5 14.5L20.5 19.5",
        "M2.1 19.5a1.4 1.4 0 1 0 2.8 0a1.4 1.4 0 1 0 -2.8 0Z",
        "M19.1 14.5a1.4 1.4 0 1 0 2.8 0a1.4 1.4 0 1 0 -2.8 0Z",
        "M12 11.5c-1.4-1.4 1.4-2.8 0-4.2",
        "M15 10c-.9-.9.9-1.8 0-2.7",
    ])

    /// 불지기: 사람 실루엣 + 작은 ◆ 불티(로봇 얼굴 금지).
    static let keeper = Icon(id: "hande.keeper", strokes: [
        "M6.8 8a3.2 3.2 0 1 0 6.4 0a3.2 3.2 0 1 0 -6.4 0Z",
        "M4 20.5c0-3.7 2.7-6.2 6-6.2s6 2.5 6 6.2",
    ], fills: [
        Fill(d: "M18.5 3.5l2 2-2 2-2-2Z", role: .agent),
    ])

    /// 지문(대조): 8행 묶음 모양(자물쇠·방패·생체 지문 곡선 금지).
    static let fingerprintRows = Icon(id: "hande.fingerprint-rows", strokes: [
        "M5 3.5h14a1.5 1.5 0 0 1 1.5 1.5v14a1.5 1.5 0 0 1-1.5 1.5H5A1.5 1.5 0 0 1 3.5 19V5A1.5 1.5 0 0 1 5 3.5Z",
        "M7 7.5h4M13 7.5h4M7 10.5h4M13 10.5h4M7 13.5h4M13 13.5h4M7 16.5h4M13 16.5h4",
    ])

    /// 기기 몸체(iPhone·Android 공용).
    static let deviceBody = "M8 3h8a2 2 0 0 1 2 2v14a2 2 0 0 1-2 2H8a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2Z"

    static let deviceIPhone = Icon(id: "hande.device-iphone", strokes: [deviceBody, "M10.5 5.5h3"])

    static let deviceAndroid = Icon(id: "hande.device-android", strokes: [deviceBody, "M10 18.5h4"], fills: [
        Fill(d: "M11.1 6a0.9 0.9 0 1 0 1.8 0a0.9 0.9 0 1 0 -1.8 0Z", role: .ink),
    ])

    static let devicePC = Icon(id: "hande.device-pc", strokes: [
        "M5 4.5h14a1.5 1.5 0 0 1 1.5 1.5v8.5a1.5 1.5 0 0 1-1.5 1.5H5a1.5 1.5 0 0 1-1.5-1.5V6A1.5 1.5 0 0 1 5 4.5Z",
        "M12 16v3.5M8.5 19.5h7",
    ])

    static let deviceWeb = Icon(id: "hande.device-web", strokes: [
        "M5 4.5h14a1.5 1.5 0 0 1 1.5 1.5v12a1.5 1.5 0 0 1-1.5 1.5H5A1.5 1.5 0 0 1 3.5 18V6A1.5 1.5 0 0 1 5 4.5Z",
        "M3.5 8.5h17",
        "M6.5 6.5h.01M9 6.5h.01",
    ])

    /// 자리(둘러앉음): 작은 불 + 둘러앉은 점 5(크림·파랑 교대). 낮불 에이전트 점은 ◆.
    static let seat = Icon(id: "hande.seat", strokes: [
        "M12 14.5c-1.3 0-2.1-.9-2.1-2.1 0-1.5 1.3-2.5 2.1-4.6.8 2.1 2.1 3.1 2.1 4.6 0 1.2-.8 2.1-2.1 2.1Z",
    ], fills: [
        Fill(d: "M2.6 13.5a1.4 1.4 0 1 0 2.8 0a1.4 1.4 0 1 0 -2.8 0Z", role: .person),
        Fill(d: "M5.199999999999999 18.5a1.4 1.4 0 1 0 2.8 0a1.4 1.4 0 1 0 -2.8 0Z", role: .agent,
             dayDiamond: "M6.6 16.8l1.7 1.7-1.7 1.7-1.7-1.7Z"),
        Fill(d: "M10.6 20.5a1.4 1.4 0 1 0 2.8 0a1.4 1.4 0 1 0 -2.8 0Z", role: .person),
        Fill(d: "M15.999999999999998 18.5a1.4 1.4 0 1 0 2.8 0a1.4 1.4 0 1 0 -2.8 0Z", role: .agent,
             dayDiamond: "M17.4 16.8l1.7 1.7-1.7 1.7-1.7-1.7Z"),
        Fill(d: "M18.6 13.5a1.4 1.4 0 1 0 2.8 0a1.4 1.4 0 1 0 -2.8 0Z", role: .person),
    ])

    static let inviteBell = Icon(id: "hande.invite-bell", strokes: [
        "M6 10a6 6 0 0 1 12 0v4l1.5 2.5h-15L6 14Z",
        "M10 19.5a2 2 0 0 0 4 0",
    ])

    static let reorder = Icon(id: "hande.reorder", strokes: [
        "M4 7h10M4 12h10M4 17h10",
        "M19 5v14",
        "M17 7l2-2 2 2M17 17l2 2 2-2",
    ])

    /// 덮어 두기: 불 위에 뚜껑.
    static let cover = Icon(id: "hande.cover", strokes: [
        "M4 16a8 8 0 0 1 16 0Z",
        "M3 19h18",
        "M12 8V6.5",
        "M12 14c-.8 0-1.3-.5-1.3-1.2 0-.9.8-1.5 1.3-2.8.5 1.3 1.3 1.9 1.3 2.8 0 .7-.5 1.2-1.3 1.2Z",
    ])

    /// 불꽃을 뺀 아이콘 11종(정본 순서).
    static let icons: [Icon] = [embersOut, keeper, fingerprintRows, deviceIPhone, deviceAndroid, devicePC, deviceWeb, seat, inviteBell, reorder, cover]

    /// 모든 path 문자열(불꽃 세 갈래 + 아이콘 11종의 선·채움·낮불 ◆) — 파서 검사용.
    static var allPaths: [String] { tongues.map(\.d) + icons.flatMap(\.paths) }
}
