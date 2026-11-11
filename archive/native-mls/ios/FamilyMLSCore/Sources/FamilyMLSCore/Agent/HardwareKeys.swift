// 하드웨어 키보드 단축키 판정(순수 로직, Linux `swift test`) — 웹 한데 `web/hande/keyboard.js`·`shortcuts.js`(#478) 의 휴대폰 세로
// (한 pane) 규칙을 옮긴다. iOS 앱은 목록 | 대화방이 한 화면씩이라 웹의 2분할(900px+) 미리보기 분기는 없다.
//
// 대화방(웹 `listPageNavAction` 'switch' · `timelineKeyAction` · `viewKeyAction`):
//   PageUp/PageDown = 이전·다음 대화방(작성 중이어도 — 초안은 방별 저장) · Home = 대화 목록
//   작성창: Esc·End = 대화 읽기(작성창에서 나와 위 대화를 본다) · Enter = 전송 · Shift+Enter = 줄바꿈(웹 `composerKeyAction`)
//   대화 읽기: ↑/↓ = 말풍선 하나씩 위·아래 · End = 맨 아래(최신) · Enter = 작성창으로 · Esc = 선택 모드
//   선택 모드(웹 캐럿 모드 `timeline-caret.js` 의 iOS 판): 말풍선 하나에 점선 테두리 · ↑/↓ = 테두리 이동 ·
//     Enter = 그 말풍선을 「선택해서 복사」 창으로(창 안에서 Shift+방향키 글자 선택 · ⌘C 복사) · ⌘C = 말풍선 글 전체 복사 ·
//     Esc = 대화 읽기로 · End = 맨 아래 · PageUp/PageDown/Home 은 쓰지 않는다(웹 캐럿 모드도 방을 넘기지 않음)
// 대화 목록(웹 `listPageNavAction` 'navigate' · `listPageMove`):
//   PageUp/PageDown = 표시 행을 한 칸씩(열지 않음) · Enter = 표시된 행 열기 · 순서 모드에서는 움직이지 않는다(웹 #480 A)
//
// 수정키(⌘·⌥·⌃·Shift)가 붙은 키는 건드리지 않는다 — ⌘↩ 보내기(SwiftUI 단축키), Shift+방향키 선택, ⌘↑ 글 처음으로 같은 편집 동작이다.
// 예외: 작성창 Shift+Enter(줄바꿈) · 선택 모드 ⌘C(복사) · 대화 읽기·선택 모드 ⌘V(작성창에 붙여넣기).
// 왜 작성창 Enter 를 여기서 판정하나: 하드웨어 키보드 Return 이 SwiftUI 세로 TextField 에 줄바꿈을 넣지 않는 기기가 있어(오너 실기기 2026-10-31:
// Enter 전송·Shift+Enter 줄바꿈 둘 다 안 됨) `ComposerKeys` 의 글 변화 판정이 한 번도 불리지 않았다. 줄바꿈이 들어오는 기기에서는
// 종전 판정이 먼저 처리하고, 앱이 `insertedNewline` 으로 그것을 알아 두 번 처리하지 않는다.
import Foundation

public enum HardwareKeys {
    public enum Key: String, Equatable, Sendable {
        case pageUp, pageDown, home, end, escape, upArrow, downArrow, enter
        /// 글자 C — 선택 모드 ⌘C 복사에만 쓴다.
        case letterC
        /// 글자 V — 대화 읽기·선택 모드 ⌘V(작성창에 붙여넣기)에만 쓴다.
        case letterV
    }

    public struct Modifiers: OptionSet, Equatable, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }
        public static let shift = Modifiers(rawValue: 1 << 0)
        public static let control = Modifiers(rawValue: 1 << 1)
        public static let option = Modifiers(rawValue: 1 << 2)
        public static let command = Modifiers(rawValue: 1 << 3)
    }

    public struct Press: Equatable, Sendable {
        public let key: Key
        public let modifiers: Modifiers
        public init(_ key: Key, _ modifiers: Modifiers = []) {
            self.key = key
            self.modifiers = modifiers
        }
    }

    // MARK: 대화방

    /// 대화방 안에서 키보드가 어디를 다루는가.
    public enum RoomMode: Equatable, Sendable {
        /// 작성창에 커서.
        case composer
        /// 작성창 밖 — 대화를 위아래로 읽는다.
        case reading
        /// 말풍선 하나를 골라 둔 상태(웹 캐럿 모드).
        case selecting
    }

    public enum RoomAction: String, Equatable, Sendable {
        case previousRoom, nextRoom, backToList
        /// 작성창에서 나와 대화 읽기(웹: 타임라인으로 포커스). 선택 모드에서는 선택을 끝내고 읽기로.
        case readTimeline
        /// 대화 읽기에서 작성창으로(웹: 대화형 요소 밖 Enter).
        case focusComposer
        case scrollUp, scrollDown
        /// 맨 아래(최신 글) — 웹은 타임라인 End 를 브라우저 기본(맨 아래로)에 맡긴다.
        case scrollToLatest
        /// 작성창 Enter = 보내기 · Shift+Enter = 커서 자리에 줄바꿈.
        case send, newline
        /// 대화 읽기 Esc = 선택 모드 시작.
        case startSelecting
        /// 선택 모드 ↑/↓ = 테두리를 위·아래 말풍선으로.
        case selectUp, selectDown
        /// 선택 모드 Enter = 「선택해서 복사」 창 · ⌘C = 글 전체 복사.
        case openSelection, copySelection
        /// 대화 읽기·선택 모드 ⌘V = 작성창으로 가서 커서 자리에 붙여넣기(선택 창에서 복사한 글을 바로 답장에 쓰게).
        case pasteToComposer
    }

    /// 대화방 화면에서 이 키가 할 일. 없으면 nil(키를 그대로 둔다).
    public static func roomAction(_ press: Press, mode: RoomMode) -> RoomAction? {
        switch (mode, press.key, press.modifiers) {
        case (.composer, .enter, .shift): return .newline
        case (.selecting, .letterC, .command): return .copySelection
        case (.reading, .letterV, .command), (.selecting, .letterV, .command): return .pasteToComposer
        default: break
        }
        guard press.modifiers.isEmpty else { return nil }
        switch (mode, press.key) {
        case (.composer, .pageUp), (.reading, .pageUp): return .previousRoom
        case (.composer, .pageDown), (.reading, .pageDown): return .nextRoom
        case (.composer, .home), (.reading, .home): return .backToList
        case (.composer, .escape), (.composer, .end): return .readTimeline
        case (.composer, .enter): return .send
        case (.reading, .upArrow): return .scrollUp
        case (.reading, .downArrow): return .scrollDown
        case (.reading, .end), (.selecting, .end): return .scrollToLatest
        case (.reading, .enter): return .focusComposer
        case (.reading, .escape): return .startSelecting
        case (.selecting, .upArrow): return .selectUp
        case (.selecting, .downArrow): return .selectDown
        case (.selecting, .enter): return .openSelection
        case (.selecting, .escape): return .readTimeline
        default: return nil
        }
    }

    /// 선택 모드의 테두리 위치. `rows` = 복사할 글이 있는 말풍선만(첨부·복호화 실패 제외), seq 오름차순. 커서가 없으면 마지막 말풍선,
    /// 커서가 고를 수 없는 행(첨부 등)이면 그 위의 가장 가까운 말풍선(없으면 첫 말풍선). 이동은 끝에서 멈춘다(맨 아래로 빠지지 않는다).
    /// `step` 0 = 시작 위치.
    public static func selectTarget(rows: [Int64], cursor: Int64?, step: Int) -> Int64? {
        guard !rows.isEmpty else { return nil }
        let index: Int
        if let cursor {
            index = rows.firstIndex(of: cursor) ?? rows.lastIndex(where: { $0 < cursor }) ?? 0
        } else {
            index = rows.count - 1
        }
        return rows[min(rows.count - 1, max(0, index + step))]
    }

    /// `old` → `new` 가 줄바꿈 한 글자 삽입인가(입력칸이 Return 으로 스스로 줄바꿈을 넣었다 — 그 경우 종전 `ComposerKeys` 가 처리한다).
    public static func insertedNewline(old: String, new: String) -> Bool {
        guard new.count == old.count + 1 else { return false }
        let o = Array(old), n = Array(new)
        var i = 0
        while i < o.count, o[i] == n[i] { i += 1 }
        return n[i] == "\n" && Array(n[(i + 1)...]) == Array(o[i...])
    }

    /// 보낼 글: 끝의 줄바꿈·공백만 걷는다(앞·가운데 줄바꿈은 그대로). 비면 nil.
    public static func outgoingText(_ draft: String) -> String? {
        var text = draft
        while let last = text.last, last.isWhitespace || last.isNewline { text.removeLast() }
        return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : text
    }

    public enum ScrollTarget: Equatable, Sendable {
        /// 이 말풍선을 가운데로.
        case row(Int64)
        /// 맨 아래(최신 글 따라가기 다시 켬).
        case latest
    }

    /// 대화 읽기 ↑/↓ — 한 번에 말풍선 하나씩. 웹은 60px 씩 스크롤하지만 SwiftUI(iOS 16)에는 픽셀 단위 스크롤 명령이 없어
    /// 행(seq) 단위로 옮긴다. `cursor` 는 지난번 키로 옮겨 간 행 — 없거나 목록에서 사라졌으면 마지막 말풍선에서 시작한다.
    /// 맨 위에서 ↑ 는 제자리, 마지막 말풍선에서 ↓ 는 맨 아래(`latest`). 글이 없으면 ↓ 만 `latest`.
    public static func scrollTarget(rows: [Int64], cursor: Int64?, up: Bool) -> ScrollTarget? {
        guard !rows.isEmpty else { return up ? nil : .latest }
        let index = cursor.flatMap { rows.firstIndex(of: $0) } ?? rows.count - 1
        if up { return .row(rows[max(0, index - 1)]) }
        let next = index + 1
        return next < rows.count ? .row(rows[next]) : .latest
    }

    /// 대화 읽기 ↑/↓ 한 번에 움직일 거리 — 설정 「화면」. 오너 2026-11-11: 말풍선 하나씩(`scrollTarget`)은 긴 에이전트 답에서 한 번에
    /// 너무 많이 움직이고, 화면보다 긴 말풍선은 가운데를 맞추느라 윗부분을 건너뛴다 → 기본은 보이는 칸 높이의 1/3, 종전 방식은 `bubble` 로 남긴다.
    /// 기기 표시 설정이라 서버 스코프 밖 `UserDefaults.standard`(테마와 같다).
    public enum ArrowScrollStep: String, CaseIterable, Equatable, Sendable {
        case small, medium, large, bubble

        public static let storageKey = "hande.arrowScrollStep"
        public static let standard: ArrowScrollStep = .medium

        /// 저장값이 없거나 모르는 값이면 기본(보통).
        public static func from(_ raw: String?) -> ArrowScrollStep {
            raw.flatMap(ArrowScrollStep.init(rawValue:)) ?? standard
        }

        /// 보이는 칸 높이에 대한 한 번 이동 비율. `bubble` 은 nil(말풍선 단위 — `scrollTarget`).
        /// 크게(2/3)도 1/3 은 겹쳐 남아 어디까지 읽었는지 놓치지 않는다.
        public var viewportFraction: Double? {
            switch self {
            case .small: return 1.0 / 6.0
            case .medium: return 1.0 / 3.0
            case .large: return 2.0 / 3.0
            case .bubble: return nil
            }
        }
    }

    public enum PixelScrollTarget: Equatable, Sendable {
        /// 스크롤 위치(contentOffset.y)를 여기로.
        case offset(Double)
        /// 맨 아래(최신 글 따라가기 다시 켬) — 말풍선 단위의 `ScrollTarget.latest` 와 같다.
        case latest
    }

    /// 대화 읽기 ↑/↓ — 보이는 칸의 `fraction` 만큼(웹의 고정 60px 이동과 같은 픽셀 단위). `offset` = 지금 contentOffset.y,
    /// `minOffset`·`maxOffset` = 맨 위·맨 아래의 offset(위 inset 은 음수 쪽). 맨 위에서 ↑ 는 nil(제자리),
    /// ↓ 로 맨 아래에 닿거나 넘으면 `latest`. 칸 크기를 아직 모르면 nil(호출자가 말풍선 단위로 대신한다).
    public static func pixelScrollTarget(offset: Double, viewport: Double, minOffset: Double, maxOffset: Double,
                                         fraction: Double, up: Bool) -> PixelScrollTarget? {
        guard viewport > 0, fraction > 0, offset.isFinite, minOffset.isFinite, maxOffset.isFinite else { return nil }
        let bottom = max(minOffset, maxOffset)
        let step = max(1, (viewport * fraction).rounded())
        if up {
            guard offset > minOffset + 0.5 else { return nil }
            return .offset(max(minOffset, offset - step))
        }
        let next = offset + step
        return next >= bottom - 0.5 ? .latest : .offset(next)
    }

    // MARK: 대화 목록

    public enum ListAction: Equatable, Sendable {
        /// 이 index 의 행을 표시(열지 않는다).
        case highlight(Int)
        /// 이 index 의 방을 연다.
        case open(Int)
    }

    /// 대화 목록 화면에서 이 키가 할 일. `highlighted` = 키로 표시해 둔 행, `anchor` = 표시가 없을 때 PageUp/Down 의 출발점
    /// (방금 나온 방 — 웹 `currentListIndex` 의 열린 방). Enter 는 표시된 행이 있을 때만 연다(보이지 않는 행을 열지 않게).
    public static func listAction(_ press: Press, count: Int, highlighted: Int?, anchor: Int?, orderEditing: Bool) -> ListAction? {
        guard press.modifiers.isEmpty, !orderEditing, count > 0 else { return nil }
        switch press.key {
        case .pageUp, .pageDown:
            return pageMove(down: press.key == .pageDown, count: count, current: highlighted ?? anchor).map(ListAction.highlight)
        case .enter:
            guard let highlighted, highlighted >= 0, highlighted < count else { return nil }
            return .open(highlighted)
        default:
            return nil
        }
    }

    /// 대화 읽기에서 Enter 로 작성창에 들어간 직후, 그 Enter 를 누르고 있어 반복 입력된 줄바꿈이 작성창에 들어오면
    /// `ComposerKeys` 가 저장된 초안을 보내 버린다 — 이 시간 안의 Enter 전송은 줄바꿈만 되돌린다(보내지 않음).
    /// 키 반복은 보통 0.5초 뒤 시작하므로 그보다 조금 길게 둔다.
    public static let sendGuardAfterKeyFocus: TimeInterval = 0.8

    /// `sinceKeyFocus` = Enter 로 작성창에 들어온 뒤 지난 초(없으면 nil). true 면 이번 Enter 전송을 막는다.
    public static func suppressSend(sinceKeyFocus: TimeInterval?) -> Bool {
        guard let sinceKeyFocus else { return false }
        return sinceKeyFocus >= 0 && sinceKeyFocus < sendGuardAfterKeyFocus
    }

    /// 웹 `listPageMove` 와 같다: 출발점이 없거나 범위 밖이면 PageDown 은 첫 행, PageUp 은 마지막 행. 끝에서는 제자리.
    public static func pageMove(down: Bool, count: Int, current: Int?) -> Int? {
        guard count > 0 else { return nil }
        guard let current, current >= 0, current < count else { return down ? 0 : count - 1 }
        return min(count - 1, max(0, current + (down ? 1 : -1)))
    }
}

/// 한 번의 키 누름이 두 길로 와도 한 번만 한다. 앱은 같은 누름을 SwiftUI `.keyboardShortcut`(작성창이 키를 먼저 쓰지 않을 때)과
/// GameController 키 변화(늘) 양쪽에서 받을 수 있다 — 둘 다 PageDown 을 처리하면 방이 두 칸 넘어간다.
/// **다른 길**에서 `window` 안에 온 같은 동작만 버린다: 같은 길의 빠른 두 번 누름(일부러 두 칸)은 그대로 둔다. 창은 처리 시각 기준이라,
/// 첫 처리(새 대화방 화면 만들기)로 메인 스레드가 잠시 막혀 두 번째 길이 늦게 와도 걸러지도록 넉넉히 둔다.
public struct KeyDeduper: Sendable {
    /// `shortcut` = SwiftUI `.keyboardShortcut` · `gameController` = GameController 키 변화 ·
    /// `keyPress` = SwiftUI `onKeyPress`(iOS 17+, 작성창 Return 을 입력칸보다 먼저 받는다).
    public enum Source: Sendable, Equatable { case shortcut, gameController, keyPress }

    public let window: TimeInterval
    private var last: [String: (source: Source, at: TimeInterval)] = [:]

    public init(window: TimeInterval = 0.5) {
        self.window = window
    }

    /// `now`(단조 시계 초)에 `source` 길로 온 `action` 을 해도 되는가 — 해도 되면 기록하고 true. 버린 것은 기록하지 않는다.
    public mutating func accept(_ action: String, from source: Source, at now: TimeInterval) -> Bool {
        if let previous = last[action], previous.source != source, now >= previous.at, now - previous.at < window { return false }
        last[action] = (source, now)
        return true
    }
}
