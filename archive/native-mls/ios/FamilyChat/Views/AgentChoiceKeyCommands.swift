// agent-choices-v1 §3.1(#629) — 선택지 카드 하드웨어 키보드 단축키: ⌥1~9 = 체크 토글 · ⌥Return = 보내기.
// 판정은 Core `AgentChoiceKeys.decide`(공유 벡터 `keys`). 여기는 SwiftUI 단축키(UIKeyCommand)를 거는 일만 한다.
//
// 왜 SwiftUI `.keyboardShortcut` 인가: ⌥+숫자는 문자 키라 작성창(UITextView)이 자기 동작으로 먼저 쓰는 키(PageUp·Esc)가 아니다 —
// 응답자 체인의 단축키가 글자 입력보다 먼저 맞춰지므로 맞으면 「¡」 같은 특수문자가 들어가지 않는다(가로챈 키는 기본 동작을 막는다).
// GameController 길(`HardwareKeyRouter`)은 숫자 키를 넘기지 않고, ⌥Return 은 `HardwareKeys.roomAction` 이 수정키 때문에 nil 이라 겹치지 않는다.
// 가로채지 않아야 할 때(열린 카드 없음 · 비활성 · N > k · 체크 없음)는 그 단축키 버튼을 아예 만들지 않는다 — ⌥+숫자 특수문자 입력이 그대로 남는다.
import SwiftUI
import FamilyMLSCore

struct AgentChoiceKeyCommands: View {
    /// 방의 open 카드(nil = 열린 카드 없음 → 단축키를 하나도 걸지 않는다).
    let card: AgentChoiceKeys.Card?
    let perform: (AgentChoiceKeys.Action) -> Void

    private static let digits: [Int] = Array(1...9)

    var body: some View {
        ZStack {
            ForEach(Self.digits, id: \.self) { number in
                if AgentChoiceKeys.decide(.init(.digit(number), option: true), card: card) != nil {
                    Button(Strings.choiceKeyToggle(number)) { press(.digit(number)) }
                        .keyboardShortcut(KeyEquivalent(Character(String(number))), modifiers: .option)
                }
            }
            if AgentChoiceKeys.decide(.init(.enter, option: true), card: card) != nil {
                Button(Strings.choiceKeySend) { press(.enter) }
                    .keyboardShortcut(.return, modifiers: .option)
            }
        }
        .opacity(0)
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
    }

    /// 누른 순간 다시 판정한다 — 한글 조합 중이면(규격: 조합 중 = 가로채지 않음) 아무것도 하지 않는다.
    @MainActor private func press(_ key: AgentChoiceKeys.Key) {
        let input = AgentChoiceKeys.Input(key, option: true, composing: FirstResponderText.hasMarkedText)
        if let action = AgentChoiceKeys.decide(input, card: card) { perform(action) }
    }
}
