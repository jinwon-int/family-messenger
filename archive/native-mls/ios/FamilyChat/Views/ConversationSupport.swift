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

/// 이 기기에 두는 표시 설정. 방 순서는 이 기기에만. 읽음 위치는 #571 B 부터 릴레이가 같은 사람(actor)의 기기들 사이에서 공유한다 —
/// 방 화면이 `markRead` 와 함께 `AppModel.noteRead`(`POST /read`)를 부르고, 릴레이 값(`AppModel.relayReadSeq`)은 `RootView` 가 여기에 합친다(줄어들지 않음).
/// MLS 상태·메시지 DB 와 섞지 않으려고 UserDefaults 에 둔다(방 행 displayOrder 는 동기화 엔진도 고쳐 쓰므로 건드리지 않는다).
@MainActor
final class LocalPrefs: ObservableObject {
    static let shared = LocalPrefs()

    private let defaults: UserDefaults
    private static let readKey = "hande.readSeq"
    private static let orderKey = "hande.roomOrder"

    @Published private(set) var readSeq: [RoomID: Int64]
    @Published private(set) var roomOrder: [RoomID]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let raw = defaults.dictionary(forKey: Self.readKey) as? [String: NSNumber] ?? [:]
        readSeq = raw.mapValues { $0.int64Value }
        roomOrder = defaults.stringArray(forKey: Self.orderKey) ?? []
    }

    /// 이 방을 `seq` 까지 봤다(줄어들지 않는다).
    func markRead(_ room: RoomID, seq: Int64) {
        guard seq > (readSeq[room] ?? 0) else { return }
        readSeq[room] = seq
        defaults.set(readSeq.mapValues { NSNumber(value: $0) }, forKey: Self.readKey)
    }

    func setOrder(_ ids: [RoomID]) {
        roomOrder = ids
        defaults.set(ids, forKey: Self.orderKey)
    }
}
