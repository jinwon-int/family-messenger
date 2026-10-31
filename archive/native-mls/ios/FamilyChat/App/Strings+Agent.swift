// 에이전트 대화 문구(#405 P1). 화면 전용 — Linux 스모크 복사 목록에 넣지 않는다.
import Foundation
import FamilyMLSCore
extension Strings {
    // 에이전트·사람 닉네임 표(agentNames·peopleNames)는 Strings+Names.swift — NSE 와 공유.
    /// AI 에이전트 = 불지기(모닥불 용어, 오너 승인). 설정 설명문에는 「불지기(AI 에이전트)」 병기.
    static let agentBadge = "불지기"
    static let agentBadgePlain = "불지기(AI 에이전트)"
    /// 내 글 뒤 에이전트 답이 아직 없을 때(`AgentThinking` — 앱 추정, 에이전트 쪽 신호 없음). 작업 중이라고 단정하지 않는다(#601):
    /// 봇·브리지가 멈춰도 같은 조건이 성립하므로 "생각하는 중"이 아니라 내 쪽 상태(기다림)만 말한다.
    static func agentAwaitingReply(_ name: String) -> String { "\(name)의 답 기다리는 중" }
    static func approvalTitle(_ name: String) -> String { "\(name)\(subjectParticle(name)) 허락을 구합니다" }
    // subjectParticle 은 Strings.swift(타닥타닥 라벨과 공용).
    /// 허락 카드 본문 줄 머리(디자인 1차: 대상·내용·영향 3줄 고정 — 봇이 아직 한 줄 요약만 보내므로 「내용」 한 줄, 나머지는 봇 쪽 후속).
    static let approvalSummaryLabel = "내용"
    static let approvalAllow = "허락"
    static let approvalDeny = "거절"
    static let approvalAllowed = "허락했습니다"
    static let approvalDenied = "거절했습니다"
    static let approvalSending = "답을 보냈습니다 · 처리 기다리는 중"
    static let approvalClosed = "더는 답할 수 없는 요청입니다"
    /// 버튼이 대신 보내는 글 — 봇이 알아듣는 형식(native-mls-bot `parse_approval_reply`).
    static func approvalReply(_ number: Int, allow: Bool) -> String { allow ? "승인 \(number)" : "거절 \(number)" }
    static let lastSentLabel = "내 마지막 말"
    static func lastSentReplies(_ count: Int) -> String { count == 0 ? "아직 답 없음" : "답 \(count)개" }

    // agent-choices-v1(#620): 에이전트 선택지 카드.
    /// 보내기 버튼이 대신 보내는 글 — 손으로 치는 답과 같은 `N`(봇·브리지 무변경).
    static func choiceReply(_ number: Int) -> String { "\(number)" }
    static let choiceSend = "보내기"
    static let choiceRecommended = "권장"
    /// 답한 뒤 카드 대신 한 줄.
    static func choiceAnswered(_ number: Int, label: String) -> String { "✓ \(number)번 선택 — \(label)" }
    /// 접근성: 행 = 「N번: 라벨」(+ 「, 권장」).
    static func choiceRowA11y(_ number: Int, label: String, recommended: Bool) -> String {
        recommended ? "\(number)번: \(label), \(choiceRecommended)" : "\(number)번: \(label)"
    }
    /// 접근성: 보내기 버튼 = 「N번 보내기」(선택 없음 = 「보내기」).
    static func choiceSendA11y(_ number: Int?) -> String { number.map { "\($0)번 보내기" } ?? choiceSend }
    static let choiceA11yHint = "눌러서 고르고 보내기를 누르세요"
}

// #405 P2 모닥불 테마 문구.
extension Strings {
    static let campfireSubtitle = "오늘 밤, 모닥불에 한데 모여"
    /// 영문 이름(뒤로 가기·내비게이션 제목). 오프닝·목록 머리 워드마크는 같은 글자를 윤곽으로 그린다(HandeWordmarkArt).
    static let wordmark = "hande"
    static let campfireEmpty = "아직 피운 모닥불이 없습니다"
    static let roomClosedPreview = "불이 꺼진 자리"
    /// 운영자가 닫은 방(`SyncHaltReason.roomClosed`) — 방 행 보조 글자.
    static let roomClosedByOperator = "불이 꺼진 자리 · 운영자가 닫음"
    static let roomNoMessages = "아직 아무도 말하지 않았어요"
    /// 오늘의 불 세기(방 행 아이콘 불꽃 1~3단, 숫자 없음) — VoiceOver 만 말로.
    static func fireLevelLabel(_ level: Int) -> String {
        switch level {
        case ...1: return "오늘의 불 세기 조용함"
        case 2: return "오늘의 불 세기 보통"
        default: return "오늘의 불 세기 활발"
        }
    }
    /// 대화방 제목 아래 자리 요약: ●●● 가족 3 · ● 불지기 공명
    static func seatPeople(_ count: Int) -> String { "가족 \(count)" }
    static func seatAgents(_ names: [String]) -> String { "\(agentBadge) \(names.joined(separator: ", "))" }
    /// 설정 「화면」 — 테마(밤 고정이 기본, 낮불은 e-ink·밝은 곳용 고대비).
    static let themeSection = "화면"
    static let themeLabel = "테마"
    static let themeNight = "밤 (기본)"
    static let themeDay = "낮불 — e-ink·밝은 곳"
    static let themeHint = "낮불은 e-ink 태블릿과 밝은 곳에서 읽기 쉬운 고대비 화면입니다. 사람은 ●, 불지기(AI 에이전트)는 ◆ 로 구별합니다."
    /// 기기 종류(기기 ID 둘째 마디) → 표시. 없으면 표시하지 않는다.
    static let deviceKinds: [String: String] = [
        "iphone": "아이폰", "ipad": "아이패드", "pc": "PC", "web": "웹", "android": "안드로이드", "mac": "맥",
    ]
    /// 다른 사람 말풍선 위 이름줄: 오너 · PC
    static func senderLabel(device: String) -> String {
        let name = AgentRosterNames.person(device)
        guard let kind = DeviceKindName.of(device) else { return name }
        return "\(name) · \(kind)"
    }
    /// 목록 미리보기 한 줄: 줄바꿈·마크다운 기호(**, `, 줄 앞 #·>·|)는 걷어 낸다.
    static func previewLine(name: String, body: String) -> String {
        let lines = body.split(separator: "\n").map { line -> String in
            var s = line.trimmingCharacters(in: .whitespaces)
            while let c = s.first, "#>|".contains(c) { s = String(s.dropFirst()).trimmingCharacters(in: .whitespaces) }
            return s
        }.filter { !$0.isEmpty }
        let flat = lines.joined(separator: " ").replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "`", with: "")
        return name.isEmpty ? flat : "\(name): \(flat)"  // 이름이 비면 접두 없이(1:1 방 — 웹 previewLine 과 같다)
    }
}

/// 이름 찾기(Core AgentRoster.displayName + 위 표).
enum AgentRosterNames {
    static func person(_ device: String) -> String {
        AgentRoster.displayName(device: device, names: Strings.peopleNames.merging(Strings.agentNames) { a, _ in a }.merging(Strings.serviceNames) { a, _ in a })
    }
}

enum DeviceKindName {
    static func of(_ device: String) -> String? { DeviceLabel.kind(device).flatMap { Strings.deviceKinds[$0] } }
}

// #405 P3 키보드·편의 문구.
extension Strings {
    static let unreadLabel = "안 읽은 글"
    static let shortcutReadTimeline = "대화 읽기"
    static let shortcutPreviousRoom = "이전 자리"
    static let shortcutNextRoom = "다음 자리"
    static let shortcutRoomList = "자리 목록"
}

// #405 메시지 시간 표시.
extension Strings {
    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ko_KR")
        f.dateFormat = "a h:mm"
        return f
    }()
    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ko_KR")
        f.dateFormat = "M월 d일 EEEE"
        return f
    }()
    private static let dayYearFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ko_KR")
        f.dateFormat = "yyyy년 M월 d일 EEEE"
        return f
    }()

    /// 말풍선 옆 시간: 오후 3:58
    static func messageTime(_ date: Date) -> String { timeFormatter.string(from: date) }

    /// 날짜 구분선: 오늘 · 어제 · 10월 18일 토요일 · (다른 해) 2025년 10월 18일 토요일
    static func dayLabel(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        if calendar.isDate(date, inSameDayAs: now) { return "오늘" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) { return "어제" }
        let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
        return (sameYear ? dayFormatter : dayYearFormatter).string(from: date)
    }

    private static let shortDayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ko_KR")
        f.dateFormat = "M월 d일"
        return f
    }()
    private static let shortDayYearFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ko_KR")
        f.dateFormat = "yyyy년 M월 d일"
        return f
    }()

    /// 방 목록 카드 오른쪽: 마지막 말이 언제였나(오너 2026-10-30) — 방금 · N분 전 · N시간 전 · N일 전(7일 미만) · 10월 18일 · 2025년 10월 18일.
    /// 기준은 `MessageRecord.receivedAt`(동기화된 글 = 릴레이 기록 시각). 시계가 어긋나 미래 시각이면 「방금」.
    static func relativeTime(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        let seconds = now.timeIntervalSince(date)
        if seconds < 60 { return "방금" }
        if seconds < 3_600 { return "\(Int(seconds / 60))분 전" }
        if seconds < 86_400 { return "\(Int(seconds / 3_600))시간 전" }
        if seconds < 7 * 86_400 { return "\(Int(seconds / 86_400))일 전" }
        let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
        return (sameYear ? shortDayFormatter : shortDayYearFormatter).string(from: date)
    }
}

// #414 오프닝 화면.
extension Strings {
    static let openingKorean = "한데"
    static let openingTagline = "모닥불가에 한데 모여 이야기를 나눠요"
    static let openingAccessibility = "한데 — 모닥불가에 한데 모여 이야기를 나눠요. 준비 중"
}

// 디자인 2차-A(2026-10-31) 2c~2f 화면 문구 — 화면 전용(AppModel 이 쓰는 문구는 Strings.swift).
extension Strings {
    // 2c 대화 목록 빈 상태 · 순서 편집
    static let emptyRoomsHint = "운영자가 초대하면 여기에 자리가 생겨요."
    /// 초대가 있을 때 빈 상태 아래 안내 카드 — 건수 숫자 대신 「있어요」.
    static let invitesInBellPlain = "받은 초대가 있어요 — 오른쪽 위 알림에서 수락하세요"
    static let orderModeTitle = "자리 순서"
    /// 순서 모드 첫 행의 보조 글자(고정 핀이 켜진 자리).
    static let orderPinnedNote = "맨 위 고정"

    // 2d 대화방 상태
    static let relayUnreachableBanner = "릴레이에 닿지 않아요 — 연결되면 보낼게요"
    /// 운영자가 닫은 자리(`SyncHaltReason.roomClosed`) — 입력창 자리의 안내 상자.
    static let roomClosedTitle = "운영자가 이 자리를 닫았어요"
    static let roomClosedBody = "지난 이야기는 읽을 수 있지만 더 쓸 수는 없어요. 다시 열려면 운영자에게 말해 주세요."

    // 2e 설정
    static let settingsThisDevice = "이 기기"
    static let settingsDeviceManage = "기기 관리"
    static let settingsAccount = "계정"
    static let settingsDanger = "위험 구역"
    static let settingsAbout = "정보"
    static let serverChangeShort = "바꾸기"
    static let themeChipNight = "밤"
    static let themeChipDay = "낮불"
    static let themeNightHint = "밤이 기본이에요. 시스템 다크/라이트를 따르지 않습니다."
    static let themeDayHint = "밝은 곳·e-ink 화면용. 종이 바탕에 먹 글자, 움직임이 꺼집니다."
    static let pushLabel = "새 메시지 알림"
    /// 설정 행 값(짧게). 긴 설명판 `lockPreview(_:)` 는 측정 기록·접근성용으로 남긴다.
    static func lockPreviewShort(_ value: LockScreenPreview) -> String {
        switch value {
        case .unknown: return "확인 전"
        case .off: return "꺼짐"
        case .whenUnlocked: return "잠금 해제 시"
        case .never: return "안 함"
        case .always: return "항상"
        }
    }
    static let lockPreviewWarningBodyShort = "「잠금 해제 시」로 바꾸면 잠금화면엔 「새 메시지」만 보여요."
    static let copyAction = "복사"
    static let operatorInfo = "운영자용 정보"
    static let relayLabel = "릴레이"
    static let lobbyHintPlain = "로비 키는 이 기기의 공개 키 묶음이에요. 앱을 열 때마다 채웁니다."
    static let logoutHintPlain = "세션만 지워요. 다시 로그인하면 같은 기기로 이어집니다."
    static let wipeDangerBody = "이 기기의 키와 대화가 모두 지워집니다. 되돌릴 수 없어요."
    /// 정보 칸의 링크 이름(목적지는 `PolicyLinks.deleteAccount` 그대로).
    static let deleteDataGuide = "데이터 삭제 안내"
    static let versionShort = "버전"

    // 2e 알림함
    static let notifyCopyLogsShort = "기록 복사"
    static let notifyEmptyBody = "받은 초대와 수락 상태가 여기 모입니다."
    static let inviteKicker = "새 자리 초대"
    /// 카드 머리: 「새 자리 초대 · 방금」 — 시각을 모르면 「새 자리 초대」만.
    static func inviteKickerLine(_ when: String?) -> String {
        guard let when, !when.isEmpty else { return inviteKicker }
        return "\(inviteKicker) · \(when)"
    }
    static func inviteCardBody(_ room: String) -> String { "운영자가 「\(room)」 자리에 이 기기를 초대했어요." }
    static func inviteFailedTitle(_ room: String) -> String { "「\(room)」 자리에 들어가지 못했어요." }
    /// 실패 횟수를 사람 말로(한·두·세 번, 넷부터는 숫자). 기술 사유는 진단 기록으로.
    static func inviteAutoFailedPlain(_ tries: Int) -> String {
        "자동 수락이 \(countWord(tries)) 안 됐어요 — 키는 그대로라 다시 시도할 수 있어요."
    }
    static func countWord(_ n: Int) -> String {
        switch n {
        case ...1: return "한 번"
        case 2: return "두 번"
        case 3: return "세 번"
        default: return "\(n)번"
        }
    }

    // 2f 정지된 기기
    static let haltedDeviceTitle = "이 기기의 대화가\n멈췄어요"
    static let haltedDeviceHint = "운영자에게 알려 주세요. 아래 기록을 붙여 보내면 원인을 찾을 수 있어요."
}
