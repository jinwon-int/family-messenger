// agent-choices-v1 §3.1(#629) — 선택지 카드 키보드 단축키 판정(순수 로직, Linux `swift test`).
// 정본: archive/native-mls/AGENT-CHOICES-V1.md §3.1 · 공유 벡터 tests/fixtures/agent-choices-vectors.json `keys`(웹 `choiceKeyAction` 과 같은 답).
//
// ⌥(Option)+1~9 = 방의 open 카드에서 그 번호 체크 토글 · ⌥+Enter = 체크가 하나 이상이면 보내기(카드 [보내기]와 같은 compose 전송).
// Option 만 눌려 있어야 한다(⌃·⌘·Shift 하나라도 있으면 nil) · IME 조합 중이면 nil · 카드가 없거나 비활성이면 nil · N 이 1..k 밖이면 nil.
// nil = 가로채지 않는다(⌥+숫자 특수문자 입력·기존 Enter 규칙 그대로).
// `HardwareKeys`(방 이동·읽기 모드)와는 따로 둔다 — 수정키가 붙은 키는 그쪽이 건드리지 않는다.
import Foundation

public enum AgentChoiceKeys {
    /// 눌린 키. 숫자는 물리 숫자 키(1~9 — 웹 `event.code` Digit/Numpad, iOS 단축키 입력 "1"~"9")로 본다.
    public enum Key: Equatable, Sendable {
        case digit(Int)
        case enter
        case other
    }

    public struct Input: Equatable, Sendable {
        public let key: Key
        public let option: Bool
        public let control: Bool
        public let command: Bool
        public let shift: Bool
        /// IME 조합 중(한글 등 확정 전 글자가 있다).
        public let composing: Bool

        public init(_ key: Key, option: Bool = false, control: Bool = false, command: Bool = false,
                    shift: Bool = false, composing: Bool = false) {
            self.key = key
            self.option = option
            self.control = control
            self.command = command
            self.shift = shift
            self.composing = composing
        }
    }

    /// 방의 open 선택지 카드(방당 최대 1개).
    public struct Card: Equatable, Sendable {
        /// 항목 수 k.
        public let count: Int
        /// 지금 체크된 번호.
        public let selected: Set<Int>
        /// 카드가 활성(보내는 중·참여 전·꺼진 자리가 아님).
        public let enabled: Bool

        public init(count: Int, selected: Set<Int>, enabled: Bool) {
            self.count = count
            self.selected = selected
            self.enabled = enabled
        }
    }

    public enum Action: Equatable, Sendable {
        /// 그 번호 체크 토글.
        case toggle(Int)
        /// 체크한 번호로 보내기.
        case send
    }

    /// 단축키 판정(규격 §3.1). nil = 가로채지 않음.
    public static func decide(_ input: Input, card: Card?) -> Action? {
        guard let card, card.enabled else { return nil }
        guard input.option, !input.control, !input.command, !input.shift, !input.composing else { return nil }
        switch input.key {
        case .digit(let number):
            return (1...9).contains(number) && number <= card.count ? .toggle(number) : nil
        case .enter:
            return card.selected.isEmpty ? nil : .send
        case .other:
            return nil
        }
    }
}
