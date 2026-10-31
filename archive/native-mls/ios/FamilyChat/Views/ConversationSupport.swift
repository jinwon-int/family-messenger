// P3 편의(#405) 앱 쪽 부품: 화면 이동(방 전환) · 하드웨어 키보드 상태 · 이 기기에만 두는 표시 설정(읽음·방 순서).
// 판정 규칙은 Core(ComposerKeys·RoomOrder·Unread)에 있고, 여기는 상태를 들고 저장만 한다.
import SwiftUI
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
@MainActor
final class HardwareKeyRouter {
    static let shared = HardwareKeyRouter()

    let presses = PassthroughSubject<HardwareKeys.Press, Never>()
    private var deduper = KeyDeduper()
    private var started = false
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

    /// 같은 동작이 아주 짧은 간격으로 두 번 오면(한 누름 · 두 길) 한 번만 한다.
    func once(_ action: String, _ body: () -> Void) {
        if deduper.accept(action, at: ProcessInfo.processInfo.systemUptime) { body() }
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
            Task { @MainActor in HardwareKeyRouter.shared.presses.send(press) }
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

// `LocalPrefs`(읽음 위치·방 순서)는 Sync/LocalPrefs.swift — AppModel 이 서버 스코프별로 소유한다(#584).
