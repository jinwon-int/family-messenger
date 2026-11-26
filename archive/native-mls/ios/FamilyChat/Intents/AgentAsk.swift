// Siri·단축어 「공명에게 묻기」·「공명에게 기록 맡기기」의 순수 규칙(AppIntents 없이 시험한다): 금지어 거절 · `[Siri·…]` 머리글 ·
// 길이 · 답 기다리기 흐름 · 결과 문구. 송신과 답 찾기는 주입받는다(앱은 `AppModel.shortcutSend` · `awaitAgentReply`, 시험은 가짜).
//
// 안전: Siri 의 언어 모델이 「PR 머지하라고 해」를 그대로 질문으로 넘길 수 있다. 그래서
//   1) 앱에서 막는다 — 승인·머지·배포·삭제·보내기·결제 같은 말이 있으면 **보내지 않고** 거절한다(확인 창에 기대지 않는다).
//   2) 머리글 — Siri 에서 온 글은 `[Siri·질문]` / `[Siri·기록]` 으로 시작한다. 에이전트 쪽이 이 머리글이 붙은 글을
//      읽기·덧붙이기로만 다루게 하는 규칙은 에이전트 쪽 별도 변경이다(이 앱은 머리글만 붙인다).
// 이 파일은 Linux 스모크(scripts/linux-smoke.sh) 복사 대상이 아니다 — macOS(ios-build) 시험이 돈다.
import Foundation

enum AgentAsk {
    enum Kind: Equatable {
        /// 묻기 — 답을 잠시 기다린다.
        case question
        /// 기록 맡기기 — 접수만 알린다(답을 기다리지 않는다).
        case note

        var header: String {
            switch self {
            case .question: return "[Siri·질문]"
            case .note: return "[Siri·기록]"
            }
        }

        /// 글자 수 상한(질문 500 · 기록 1000).
        var limit: Int {
            switch self {
            case .question: return 500
            case .note: return 1000
            }
        }
    }

    /// 대상을 고르지 않았을 때의 방(오너 ↔ 공명 에이전트 방).
    static let defaultRoom = "family-acc"
    /// 답을 기다리는 시간(초, 기본 20 s). 넘으면 「답은 방으로 옵니다」로 성공 반환.
    static let replyTimeout: TimeInterval = 20
    /// Siri 결과에 보일 답 앞부분 길이(글자).
    static let snippetLimit = 300

    // MARK: - 금지어

    /// 한국어 금지어(부분 일치). 보내기·삭제·결제 계열 + 승인·머지·배포·재시작 계열.
    static let riskyKorean: [String] = [
        "승인", "허락", "머지", "병합", "배포", "릴리스", "재시작", "재부팅",
        "보내", "보낼", "전송", "발송", "답장", "회신", "공유", "게시",
        "삭제", "지워", "지우", "비워", "휴지통", "취소",
        "결제", "구매", "주문", "송금", "이체",
        "로그아웃", "초기화", "재설정", "전화", "통화",
    ]

    /// 영어 금지어(낱말 단위, 대소문자 무시). 낱말 = 연속한 로마자 — `merge해줘` 처럼 한글이 바로 붙어도 잡힌다.
    /// 흔한 어미(-s/-es/-ed/-d/-ing, e 탈락)도 같은 말로 본다. `emergency`·`postgres` 처럼 다른 낱말 안에 든 것은 걸지 않는다.
    static let riskyEnglish: [String] = [
        "approve", "approval", "merge", "deploy", "release", "publish", "restart", "reboot",
        "send", "share", "post", "reply", "forward",
        "delete", "remove", "erase", "trash", "unsend", "cancel",
        "pay", "paid", "buy", "purchase", "order", "transfer",
        "logout", "signout", "reset", "call", "dial", "facetime", "unsubscribe",
    ]

    /// 글에 든 금지어(한국어는 목록 순, 영어는 글 순 · 중복 없음). 빈 배열 = 보내도 된다.
    static func riskyWords(in text: String) -> [String] {
        var found: [String] = []
        for word in riskyKorean where text.contains(word) && !found.contains(word) { found.append(word) }
        let tokens = latinWords(text.lowercased())
        // `log out` · `sign out` 처럼 띄어 쓴 두 낱말도 한 말로 본다.
        let joined = zip(tokens, tokens.dropFirst()).map { $0 + $1 }
        for token in tokens + joined {
            if let word = riskyEnglish.first(where: { matches(token, $0) }), !found.contains(word) { found.append(word) }
        }
        return found
    }

    private static func latinWords(_ text: String) -> [String] {
        var words: [String] = []
        var current = ""
        for scalar in text.unicodeScalars {
            if (97...122).contains(scalar.value) {   // a–z (소문자로 바꾼 뒤)
                current.unicodeScalars.append(scalar)
            } else if !current.isEmpty {
                words.append(current)
                current = ""
            }
        }
        if !current.isEmpty { words.append(current) }
        return words
    }

    private static func matches(_ token: String, _ word: String) -> Bool {
        var forms: Set<String> = [word, word + "s", word + "es", word + "ed", word + "ing"]
        if word.hasSuffix("e") {
            let stem = String(word.dropLast())
            forms.formUnion([word + "d", stem + "ing"])
        }
        if word.hasSuffix("l") { forms.formUnion([word + "led", word + "ling"]) }   // cancelled · cancelling
        return forms.contains(token)
    }

    // MARK: - 검사 · 머리글

    /// 보내기 전 검사. nil = 보내도 된다. 값 = 사람이 읽는 거절 사유(아무것도 보내지 않는다).
    static func refusal(_ kind: Kind, _ text: String) -> String? {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if body.isEmpty { return Strings.shortcutEmpty }
        if body.count > kind.limit { return Strings.siriTooLong(kind.limit) }
        if !riskyWords(in: body).isEmpty { return Strings.siriRisky }
        return nil
    }

    /// 방에 보낼 글: `[Siri·질문] …` / `[Siri·기록] …`.
    static func compose(_ kind: Kind, _ text: String) -> String {
        "\(kind.header) \(text.trimmingCharacters(in: .whitespacesAndNewlines))"
    }

    /// 답 앞부분(앞뒤 공백 정리, `snippetLimit` 자 넘으면 자르고 「전체는 한데에서」).
    static func snippet(_ reply: String) -> String {
        let body = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        guard body.count > snippetLimit else { return body }
        return String(body.prefix(snippetLimit)) + Strings.siriMoreInApp
    }

    // MARK: - 흐름

    enum Outcome: Equatable {
        /// 검사에 걸려 보내지 않았다(사유).
        case refused(String)
        /// 보내지 못했다(준비 전 · 모르는 방 등, 사유).
        case failed(String)
        /// 릴레이에 닿지 않아 보관 — 연결되면 보낸다. 답은 기다리지 않는다.
        case queued
        /// 기록을 맡겼다(기록 맡기기).
        case noted
        /// 시간 안에 온 답(전문).
        case answered(String)
        /// 보냈고 시간 안에 답이 없었다 — 답은 방과 알림으로 온다.
        case waiting
    }

    /// 검사 → `[Siri·…]` 머리글을 붙여 송신 → (묻기면) 내 글 seq 뒤의 답을 `timeout` 초까지 기다린다. 늦어도 다시 보내지 않는다.
    @MainActor
    static func run(_ kind: Kind, text: String, timeout: TimeInterval = replyTimeout,
                    send: (String) async -> AppModel.ShortcutReceipt,
                    awaitReply: (_ after: Int64, _ timeout: TimeInterval) async -> String?) async -> Outcome {
        if let reason = refusal(kind, text) { return .refused(reason) }
        let receipt = await send(compose(kind, text))
        switch receipt.result {
        case .failed(let reason): return .failed(reason)
        case .queued: return .queued
        case .sent:
            guard kind == .question else { return .noted }
            guard let seq = receipt.seq else { return .waiting }
            if let reply = await awaitReply(seq, timeout) { return .answered(reply) }
            return .waiting
        }
    }

    /// 단축어를 멈출 실패 사유(거절·송신 실패). nil = 성공으로 끝낸다.
    static func failure(_ outcome: Outcome) -> String? {
        switch outcome {
        case .refused(let reason), .failed(let reason): return reason
        case .queued, .noted, .answered, .waiting: return nil
        }
    }

    /// Siri·단축어에 보일 문장.
    static func dialog(_ outcome: Outcome, room: String) -> String {
        switch outcome {
        case .refused(let reason), .failed(let reason): return reason
        case .queued: return Strings.shortcutQueued(room)
        case .noted: return Strings.siriNoted(room)
        case .answered(let reply): return Strings.siriAnswered(room, snippet(reply))
        case .waiting: return Strings.siriWaiting(room)
        }
    }

    /// 단축어 다음 동작에 넘길 값: 답 전문(없으면 빈 문자열).
    static func value(_ outcome: Outcome) -> String {
        if case .answered(let reply) = outcome { return reply }
        return ""
    }
}
