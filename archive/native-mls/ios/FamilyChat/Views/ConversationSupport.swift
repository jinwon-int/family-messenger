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

    func open(_ room: RoomID) { path = [room] }
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

// `LocalPrefs`(읽음 위치·방 순서)는 Sync/LocalPrefs.swift — AppModel 이 서버 스코프별로 소유한다(#584).
