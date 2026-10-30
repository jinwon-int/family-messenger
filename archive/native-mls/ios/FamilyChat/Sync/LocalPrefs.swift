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
    /// 방별 작성 중인 글(웹 drafts.js `hande:draft:<device>:<room>` 과 같은 역할). 서버 스코프 안이라 기기·서버별로 따로다.
    static let draftKey = "hande.drafts"
    /// 글자 상한 — 한 방의 초안이 설정 저장소를 독차지하지 않게(웹 `DRAFT_LIMIT`).
    static let draftLimit = 20_000

    private let defaults: ScopedDefaults

    @Published private(set) var readSeq: [RoomID: Int64]
    @Published private(set) var roomOrder: [RoomID]
    /// `@Published` 가 아니다 — 글자마다 바뀌므로 방 목록 등 다른 화면을 다시 그리지 않게 한다. 방 화면이 열릴 때 한 번 읽는다.
    private var drafts: [RoomID: String]

    init(defaults: ScopedDefaults) {
        self.defaults = defaults
        // 플랫폼에 따라 NSNumber 또는 Int 로 돌아온다(Linux 스모크).
        readSeq = (defaults.dictionary(forKey: Self.readKey) ?? [:]).compactMapValues { value in
            (value as? NSNumber)?.int64Value ?? (value as? Int64) ?? (value as? Int).map(Int64.init)
        }
        roomOrder = defaults.stringArray(forKey: Self.orderKey) ?? []
        drafts = (defaults.dictionary(forKey: Self.draftKey) ?? [:]).compactMapValues { $0 as? String }
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

    /// 이 방에 쓰다 만 글(없으면 빈 문자열).
    func draft(for room: RoomID) -> String { drafts[room] ?? "" }

    /// 작성창이 바뀔 때마다 부른다. 빈 글은 지운다(보낸 뒤 · 다 지운 뒤). 같은 값이면 저장하지 않는다.
    func setDraft(_ text: String, for room: RoomID) {
        let value = String(text.prefix(Self.draftLimit))
        if value.isEmpty {
            guard drafts.removeValue(forKey: room) != nil else { return }
        } else {
            guard drafts[room] != value else { return }
            drafts[room] = value
        }
        if drafts.isEmpty { defaults.removeObject(forKey: Self.draftKey) } else { defaults.set(drafts, forKey: Self.draftKey) }
    }

    /// 기기 지우기: 메시지 저장소와 함께 쓰다 만 글(평문)도 남기지 않는다. 읽음 위치·방 순서는 표시 설정이라 그대로 둔다.
    func clearDrafts() {
        drafts = [:]
        defaults.removeObject(forKey: Self.draftKey)
    }
}
