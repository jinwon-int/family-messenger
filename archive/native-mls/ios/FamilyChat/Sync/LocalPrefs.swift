// 이 기기에 두는 표시 설정(#549 방 순서 · #571 읽음 위치). 방 순서는 이 기기에만. 읽음 위치는 #571 B 부터 릴레이가 같은 사람(actor)의
// 기기들 사이에서 공유한다 — 방 화면이 `markRead` 와 함께 `AppModel.noteRead`(`POST /read`)를 부르고, 릴레이 값(`AppModel.relayReadSeq`)은
// `RootView` 가 여기에 합친다(줄어들지 않음). MLS 상태·메시지 DB 와 섞지 않으려고 UserDefaults 에 둔다(방 행 displayOrder 는 동기화 엔진도
// 고쳐 쓰므로 건드리지 않는다). #584: 서버별 스코프(`ScopedDefaults`) — `AppModel.localPrefs` 가 서버를 바꿀 때 새로 만든다.
// (Views/ 에서 Sync/ 로 옮김 — AppModel 이 소유하므로 Linux 스모크·앱이 같은 파일을 컴파일한다.)
import Foundation
import FamilyMLSCore

@MainActor
final class LocalPrefs: ObservableObject {
    static let readKey = "hande.readSeq"
    static let orderKey = "hande.roomOrder"

    private let defaults: ScopedDefaults

    @Published private(set) var readSeq: [RoomID: Int64]
    @Published private(set) var roomOrder: [RoomID]

    init(defaults: ScopedDefaults) {
        self.defaults = defaults
        // 플랫폼에 따라 NSNumber 또는 Int 로 돌아온다(Linux 스모크).
        readSeq = (defaults.dictionary(forKey: Self.readKey) ?? [:]).compactMapValues { value in
            (value as? NSNumber)?.int64Value ?? (value as? Int64) ?? (value as? Int).map(Int64.init)
        }
        roomOrder = defaults.stringArray(forKey: Self.orderKey) ?? []
    }

    convenience init(defaults: UserDefaults = .standard) { self.init(defaults: ScopedDefaults(defaults)) }

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
