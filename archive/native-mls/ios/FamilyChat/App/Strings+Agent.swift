// 에이전트 대화 문구(#405 P1). 화면 전용 — Linux 스모크 복사 목록에 넣지 않는다.
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
