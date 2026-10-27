// 이름 표(#422 · 결정 2026-10-19 ③): 에이전트·사람 닉네임과 대화방 이름 = **Matrix 와 동일**.
// 정본은 Matrix profile displayname · m.room.name(2026-10-21 실측). 웹 `web/hande/strings.js` 의 같은 표와 함께 고친다.
// 앱과 알림 확장(NSE)이 함께 쓴다 — UIKit 의존 없음(project.yml FamilyChatNSE sources · scripts/linux-smoke.sh 복사 목록).
import Foundation

extension Strings {
    /// 에이전트 노드 이름(옛 봇 기기 `bot-<node>` 의 <node>, 새 봇 기기 `<node>-<suffix>` 의 actor) → Matrix 닉네임(한글 + 계정 마커).
    static let agentNames: [String: String] = [
        "bangtong": "방통✳️", "daegyo": "대교✴️", "dungae": "등애✳️", "gongmyoung": "공명✴️",
        "gongyung": "공융✴️", "gwakga": "곽가✳️", "jingun": "진군✳️", "nosuk": "노숙✳️",
        "seoseo": "서서✴️", "sogyo": "소교✴️", "soonwook": "순욱✴️", "yukson": "육손✳️",
    ]
    /// 사람 actor → Matrix 닉네임. 없으면 actor 그대로.
    static let peopleNames: [String: String] = [
        "owner": "jinon86",
        "jungin": "쩡이🍎",
    ]
    /// 대화방 ID → Matrix 방 이름. 노드 개인방(ID = 노드 이름)은 그 노드 닉네임. `family-acc` = 오너 ↔ 공명 에이전트 방.
    static let roomNames: [String: String] = [
        "family": "가족",
        "family-acc": "공명✴️",
        "family-card": "💳 가족 카드 알림",
        "fleet-alerts": "🔔 플릿 알림",
    ]
    /// 알림 전용 서비스 봇 actor → 보여 줄 이름(사람도 에이전트도 아님 — FC_AGENT_ACTORS 에 넣지 않는다). 웹 `serviceNames` 와 같은 표.
    /// `card` = 카드 결제 알림 봇(기기 `card-bot`, 방 `family-card` — Matrix 「💳 가족 카드 알림」과 같은 알림).
    static let serviceNames: [String: String] = [
        "card": "💳 카드 알림",
        "fleet": "🔔 플릿 알림",
    ]
    /// 보여 줄 방 이름. 모르는 방은 ID 그대로.
    static func roomLabel(_ room: String) -> String { roomNames[room] ?? agentNames[room] ?? room }
}
