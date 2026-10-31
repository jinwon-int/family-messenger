// 하드웨어 키보드 단축키 판정(순수 로직, Linux `swift test`) — 웹 한데 `web/hande/keyboard.js`·`shortcuts.js`(#478) 의 휴대폰 세로
// (한 pane) 규칙을 옮긴다. iOS 앱은 목록 | 대화방이 한 화면씩이라 웹의 2분할(900px+) 미리보기 분기는 없다.
//
// 대화방(웹 `listPageNavAction` 'switch' · `timelineKeyAction` · `viewKeyAction`):
//   PageUp/PageDown = 이전·다음 대화방(작성 중이어도 — 초안은 방별 저장) · Home = 대화 목록
//   작성창: Esc·End = 대화 읽기(작성창에서 나와 위 대화를 본다) · Enter = 전송(ComposerKeys, 여기서는 다루지 않음)
//   대화 읽기: ↑/↓ = 말풍선 하나씩 위·아래 · End = 맨 아래(최신) · Enter = 작성창으로
// 대화 목록(웹 `listPageNavAction` 'navigate' · `listPageMove`):
//   PageUp/PageDown = 표시 행을 한 칸씩(열지 않음) · Enter = 표시된 행 열기 · 순서 모드에서는 움직이지 않는다(웹 #480 A)
//
// 수정키(⌘·⌥·⌃·Shift)가 붙은 키는 건드리지 않는다 — ⌘↩ 보내기, Shift+방향키 선택, ⌘↑ 글 처음으로 같은 편집 동작이다.
// 웹의 캐럿 모드(대화 내용 Esc → 글자 선택)는 옮기지 않는다: iOS 는 말풍선을 꾹 눌러 「선택해서 복사」로 고른다.
import Foundation

public enum HardwareKeys {
    public enum Key: String, Equatable, Sendable {
        case pageUp, pageDown, home, end, escape, upArrow, downArrow, enter
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

    public enum RoomAction: String, Equatable, Sendable {
        case previousRoom, nextRoom, backToList
        /// 작성창에서 나와 대화 읽기(웹: 타임라인으로 포커스).
        case readTimeline
        /// 대화 읽기에서 작성창으로(웹: 대화형 요소 밖 Enter).
        case focusComposer
        case scrollUp, scrollDown
        /// 맨 아래(최신 글) — 웹은 타임라인 End 를 브라우저 기본(맨 아래로)에 맡긴다.
        case scrollToLatest
    }

    /// 대화방 화면에서 이 키가 할 일. 없으면 nil(키를 그대로 둔다).
    public static func roomAction(_ press: Press, composerFocused: Bool) -> RoomAction? {
        guard press.modifiers.isEmpty else { return nil }
        switch press.key {
        case .pageUp: return .previousRoom
        case .pageDown: return .nextRoom
        case .home: return .backToList
        case .escape: return composerFocused ? .readTimeline : nil
        case .end: return composerFocused ? .readTimeline : .scrollToLatest
        case .upArrow: return composerFocused ? nil : .scrollUp
        case .downArrow: return composerFocused ? nil : .scrollDown
        // 작성창 Enter 는 전송/줄바꿈(ComposerKeys — 글 변화로 판정)이라 여기서는 건드리지 않는다.
        case .enter: return composerFocused ? nil : .focusComposer
        }
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

    /// 웹 `listPageMove` 와 같다: 출발점이 없거나 범위 밖이면 PageDown 은 첫 행, PageUp 은 마지막 행. 끝에서는 제자리.
    public static func pageMove(down: Bool, count: Int, current: Int?) -> Int? {
        guard count > 0 else { return nil }
        guard let current, current >= 0, current < count else { return down ? 0 : count - 1 }
        return min(count - 1, max(0, current + (down ? 1 : -1)))
    }
}

/// 같은 동작이 아주 짧은 간격으로 두 번 오면 한 번만 한다. 앱은 한 번의 키 누름을 두 길로 받을 수 있다:
/// SwiftUI `.keyboardShortcut`(작성창이 키를 먼저 쓰지 않을 때) + GameController 키 변화(늘). 둘 다 PageDown 을 처리하면 방이 두 칸 넘어간다.
/// 창은 사람이 일부러 두 번 누르는 간격(≥ 약 100ms)보다 짧게 둔다.
public struct KeyDeduper: Sendable {
    public let window: TimeInterval
    private var last: [String: TimeInterval] = [:]

    public init(window: TimeInterval = 0.08) {
        self.window = window
    }

    /// `now`(단조 시계 초)에 `action` 을 해도 되는가 — 해도 되면 기록하고 true.
    public mutating func accept(_ action: String, at now: TimeInterval) -> Bool {
        if let previous = last[action], now >= previous, now - previous < window { return false }
        last[action] = now
        return true
    }
}
