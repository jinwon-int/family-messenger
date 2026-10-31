// P3 편의(#405) 앱 쪽 부품: 화면 이동(방 전환) · 하드웨어 키보드 상태 · 이 기기에만 두는 표시 설정(읽음·방 순서).
// 판정 규칙은 Core(ComposerKeys·RoomOrder·Unread)에 있고, 여기는 상태를 들고 저장만 한다.
import SwiftUI
import UIKit
import Combine
import FamilyMLSCore
#if canImport(GameController)
import GameController
#endif

/// 대화 목록 ↔ 대화방 이동 경로. PageUp/PageDown 으로 방을 바로 바꾸고 Home 으로 목록에 돌아가려면 경로를 쥐고 있어야 한다.
@MainActor
final class Navigator: ObservableObject {
    @Published var path: [RoomID] = []
    /// 마지막으로 연 방 — 목록에서 PageUp/PageDown 의 출발점(웹 shortcuts.js `currentListIndex` 의 열린 방). 그리지 않으므로 @Published 아님.
    private(set) var lastOpened: RoomID?

    func open(_ room: RoomID) {
        lastOpened = room
        path = [room]
    }
    func backToList() { path = [] }
}

/// 하드웨어 키보드(블루투스·iPad 키보드). 화면 키보드에서는 Enter 가 늘 줄바꿈이다(iOS 관례).
enum HardwareKeyboard {
    static var isConnected: Bool {
        #if canImport(GameController)
        return GCKeyboard.coalesced != nil
        #else
        return false
        #endif
    }

    static var isShiftPressed: Bool {
        #if canImport(GameController)
        guard let input = GCKeyboard.coalesced?.keyboardInput else { return false }
        return input.button(forKeyCode: .leftShift)?.isPressed == true || input.button(forKeyCode: .rightShift)?.isPressed == true
        #else
        return false
        #endif
    }
}

/// 하드웨어 키보드 키를 GameController 로 직접 받는다(웹 한데 단축키 동등성, 판정은 Core `HardwareKeys`).
/// 왜: 대화방을 열면 커서가 작성창(UITextView)에 있는데, 작성창이 PageUp/PageDown·Esc 를 자기 동작(스크롤·입력 취소)으로 먼저 써 버려
/// SwiftUI `.keyboardShortcut` 까지 오지 않는다(오너 2026-10-31: Home 만 웹과 같고 나머지는 안 됨). GameController 는 응답자 체인과
/// 무관하게 키 변화를 받는다 — Shift+Enter 판정(`HardwareKeyboard.isShiftPressed`)이 이미 쓰는 길이다.
/// 화면(대화방·목록)이 `presses` 를 구독하고, 자기가 맨 위에 보일 때만 처리한다. 한 번의 누름이 SwiftUI 단축키와 이 길 두 곳으로 올 수 있어
/// 동작은 `once` 로 한 번만 한다(앱 전체에 하나 — 방을 바꾸면 화면 인스턴스가 새로 생기므로 화면마다 두면 두 번 넘어간다).
/// GameController 누름이 한 번이라도 도착하면(`gameControllerDelivering`) 그 뒤로는 SwiftUI 단축키 길을 쓰지 않는다 — 두 길 경합 자체를 없앤다.
/// GameController 가 키를 주지 않는 기기에서는 SwiftUI 길이 지금처럼 남는다(나빠지지 않음).
@MainActor
final class HardwareKeyRouter {
    static let shared = HardwareKeyRouter()

    let presses = PassthroughSubject<HardwareKeys.Press, Never>()
    private var deduper = KeyDeduper()
    private var started = false
    /// GameController 로 키 누름을 한 번이라도 받았다.
    private(set) var gameControllerDelivering = false
    private var connectObserver: NSObjectProtocol?

    /// 한 번만 붙인다(이미 연결된 키보드 + 나중에 연결되는 키보드).
    func start() {
        guard !started else { return }
        started = true
        #if canImport(GameController)
        attach(GCKeyboard.coalesced)
        connectObserver = NotificationCenter.default.addObserver(forName: .GCKeyboardDidConnect, object: nil, queue: .main) { _ in
            Task { @MainActor in HardwareKeyRouter.shared.attach(GCKeyboard.coalesced) }
        }
        #endif
    }

    /// 한 누름이 두 길로 와도 한 번만 한다. SwiftUI 단축키 길은 GameController 가 키를 주기 시작하면 쓰지 않는다.
    func once(_ action: String, from source: KeyDeduper.Source, _ body: () -> Void) {
        if source == .shortcut && gameControllerDelivering { return }
        if deduper.accept(action, from: source, at: ProcessInfo.processInfo.systemUptime) { body() }
    }

    private func deliver(_ press: HardwareKeys.Press) {
        gameControllerDelivering = true
        presses.send(press)
    }

    #if canImport(GameController)
    private func attach(_ keyboard: GCKeyboard?) {
        keyboard?.keyboardInput?.keyChangedHandler = Self.makeHandler()
    }

    /// 처리기는 메인 액터 밖에서 만든다(GameController 가 부르는 큐와 무관하게) — 누름만 골라 메인 액터로 넘긴다.
    nonisolated private static func makeHandler() -> GCKeyboardValueChangedHandler {
        { input, _, code, pressed in
            guard pressed, let mapped = HardwareKeyRouter.key(for: code) else { return }
            let press = HardwareKeys.Press(mapped, HardwareKeyRouter.modifiers(input))
            Task { @MainActor in HardwareKeyRouter.shared.deliver(press) }
        }
    }

    nonisolated private static func key(for code: GCKeyCode) -> HardwareKeys.Key? {
        switch code {
        case .pageUp: return .pageUp
        case .pageDown: return .pageDown
        case .home: return .home
        case .end: return .end
        case .escape: return .escape
        case .upArrow: return .upArrow
        case .downArrow: return .downArrow
        case .returnOrEnter: return .enter
        case .keyV: return .letterV   // 대화 읽기·선택 모드 ⌘V
        case .keyC: return .letterC   // 선택 모드 ⌘C(물리 키 위치라 한글 입력 중에도 같다)
        default: return nil
        }
    }

    nonisolated private static func modifiers(_ input: GCKeyboardInput) -> HardwareKeys.Modifiers {
        func down(_ codes: GCKeyCode...) -> Bool { codes.contains { input.button(forKeyCode: $0)?.isPressed == true } }
        var out: HardwareKeys.Modifiers = []
        if down(.leftShift, .rightShift) { out.insert(.shift) }
        if down(.leftControl, .rightControl) { out.insert(.control) }
        if down(.leftAlt, .rightAlt) { out.insert(.option) }
        if down(.leftGUI, .rightGUI) { out.insert(.command) }
        return out
    }
    #endif
}

/// iOS 17+: 작성창 Return 을 **입력칸보다 먼저** 받는다(`onKeyPress`). 이 기기(오너 실기기 0.1.0 (73))에서는 SwiftUI 세로 TextField 가
/// 하드웨어 Return 을 받으면 줄바꿈 대신 입력을 끝내 커서를 놓는다 — 그래서 GameController 로 받아 처리하면 줄바꿈은 들어가도 커서가 사라졌다.
/// 여기서 처리하고 `.handled` 를 돌려주면 입력칸은 Return 을 보지 못해 커서가 남는다. Return = 보내기, Shift+Return = 줄바꿈,
/// 다른 수정키(⌘↩ 등)는 `.ignored` — SwiftUI 단축키가 처리한다. iOS 16 은 GameController 길 + 커서 되살리기로 남는다.
struct ComposerReturnKeys: ViewModifier {
    let onReturn: (_ shift: Bool) -> Void

    func body(content: Content) -> some View {
        if #available(iOS 17.0, *) {
            content.onKeyPress(.return, phases: .down) { press in
                switch press.modifiers {
                case []:
                    onReturn(false)
                    return .handled
                case .shift:
                    onReturn(true)
                    return .handled
                default:
                    return .ignored
                }
            }
        } else {
            content
        }
    }
}

/// 지금 키 입력을 받는 글 입력칸(작성창의 UITextView)을 직접 다룬다. SwiftUI(iOS 16) TextField 에는 커서 위치·조합 상태 API 가 없어
/// Shift+Enter 줄바꿈을 끝에 붙이면 가운데에서 친 줄바꿈이 엉뚱한 자리로 가고, Enter 전송 때 조합 중인 한글 음절을 알 수 없다.
@MainActor
enum FirstResponderText {
    fileprivate static weak var found: UIResponder?

    /// 커서 자리에 `text` 를 넣는다. 조합 중인 글자가 있으면 먼저 확정한다(그 글자를 덮어쓰지 않게). 입력칸이 없거나 글이 실제로
    /// 바뀌지 않았으면(입력칸이 줄바꿈을 막는 경우 등) false — 호출부가 끝에 붙인다.
    static func insert(_ text: String) -> Bool {
        guard let input = current() as? (UIResponder & UITextInput) else { return false }
        if input.markedTextRange != nil { input.unmarkText() }
        let before = fullText(input)
        input.insertText(text)
        return fullText(input) != before
    }

    /// 입력칸에 아직 확정되지 않은 조합 글자(한글 등)가 있는가.
    static var hasMarkedText: Bool {
        (current() as? (UIResponder & UITextInput))?.markedTextRange != nil
    }

    /// 조합 중인 글자를 그대로 확정한다.
    static func commitMarkedText() {
        (current() as? (UIResponder & UITextInput))?.unmarkText()
    }

    /// 지금 글 입력칸이 키 입력을 받고 있는가(커서가 살아 있는가).
    static var isActive: Bool {
        (current() as? UITextInput) != nil
    }

    /// 입력칸에서 블록으로 잡은 글(선택 창 ⌘C). 잡은 것이 없으면 nil.
    static var selectedText: String? {
        guard let input = current() as? (UIResponder & UITextInput), let range = input.selectedTextRange, !range.isEmpty,
              let text = input.text(in: range), !text.isEmpty else { return nil }
        return text
    }

    /// 입력칸의 실제 글(SwiftUI 바인딩보다 먼저 바뀐다). 입력칸이 없으면 nil.
    static var currentText: String? {
        guard let input = current() as? (UIResponder & UITextInput) else { return nil }
        return fullText(input)
    }

    private static func fullText(_ input: UITextInput) -> String? {
        guard let range = input.textRange(from: input.beginningOfDocument, to: input.endOfDocument) else { return nil }
        return input.text(in: range)
    }

    private static func current() -> UIResponder? {
        found = nil
        UIApplication.shared.sendAction(#selector(UIResponder.handeCaptureFirstResponder(_:)), to: nil, from: nil, for: nil)
        return found
    }
}

extension UIResponder {
    /// `sendAction(to: nil)` 은 첫 응답자에게 간다 — 그 응답자를 적어 둔다(`FirstResponderText`).
    @objc fileprivate func handeCaptureFirstResponder(_ sender: Any?) {
        FirstResponderText.found = self
    }
}

// `LocalPrefs`(읽음 위치·방 순서)는 Sync/LocalPrefs.swift — AppModel 이 서버 스코프별로 소유한다(#584).
