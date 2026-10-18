// 에이전트 대화 문구(#405 P1). 화면 전용 — Linux 스모크 복사 목록에 넣지 않는다.
import Foundation
import FamilyMLSCore
extension Strings {
    /// 에이전트 노드 이름(봇 기기 `bot-<node>` 의 <node>) → 보여 줄 이름. 없으면 <node> 그대로.
    static let agentNames: [String: String] = [
        "gongmyoung": "공명",
    ]
    static let agentBadge = "에이전트"
    static func agentThinking(_ name: String) -> String { "\(name)\(subjectParticle(name)) 생각하는 중" }
    static func approvalTitle(_ name: String) -> String { "\(name)\(subjectParticle(name)) 허락을 구합니다" }
    /// 받침 있으면 "이", 없으면 "가"(공명이 · 루나가). 한글 음절이 아니면 "이(가)".
    static func subjectParticle(_ name: String) -> String {
        guard let last = name.unicodeScalars.last, (0xAC00...0xD7A3).contains(last.value) else { return "이(가)" }
        return (last.value - 0xAC00) % 28 == 0 ? "가" : "이"
    }
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
}

// #405 P2 모닥불 테마 문구.
extension Strings {
    static let campfireSubtitle = "오늘 밤, 불가에 모인 자리"
    static let campfireEmpty = "아직 피운 모닥불이 없습니다"
    static let roomClosedPreview = "불이 꺼진 자리"
    static let roomNoMessages = "아직 아무도 말하지 않았어요"
    /// 사람 actor → 보여 줄 이름. 없으면 actor 그대로.
    static let peopleNames: [String: String] = [
        "owner": "오너",
        "jungin": "정인",
    ]
    /// 기기 종류(기기 ID 둘째 마디) → 표시. 없으면 표시하지 않는다.
    static let deviceKinds: [String: String] = [
        "iphone": "아이폰", "ipad": "아이패드", "pc": "PC", "web": "웹", "android": "안드로이드", "mac": "맥",
    ]
    static func composerPlaceholderAgent(_ name: String) -> String { "\(name)에게 말 걸기…" }
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
        return "\(name): \(flat)"
    }
}

/// 이름 찾기(Core AgentRoster.displayName + 위 표).
enum AgentRosterNames {
    static func person(_ device: String) -> String {
        AgentRoster.displayName(device: device, names: Strings.peopleNames.merging(Strings.agentNames) { a, _ in a })
    }
}

enum DeviceKindName {
    static func of(_ device: String) -> String? { DeviceLabel.kind(device).flatMap { Strings.deviceKinds[$0] } }
}

// #405 P3 키보드·편의 문구.
extension Strings {
    /// 에이전트 방 작성창 위 칩 — 누르면 작성창에 채운다. 끝이 ": " 이면 뒤에 이어 쓰라는 뜻.
    static let quickSay = ["방 상태 알려줘", "지금 뭐 하고 있어?", "방금 대화 요약해줘", "새 방 만들어줘: ", "초대해줘: "]
    static let unreadLabel = "안 읽은 글"
    static let shortcutReadTimeline = "대화 읽기"
    static let shortcutPreviousRoom = "이전 대화방"
    static let shortcutNextRoom = "다음 대화방"
    static let shortcutRoomList = "대화 목록"
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
}
