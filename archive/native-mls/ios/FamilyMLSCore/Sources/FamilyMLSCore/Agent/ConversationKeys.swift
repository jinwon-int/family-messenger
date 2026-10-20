// P3 편의 판정(#405) — 웹앱(web/app/src) 규칙을 옮긴 순수 로직(Linux `swift test`).
//   · ComposerKeys: 하드웨어 키보드 Enter=전송 · Shift+Enter=줄바꿈(웹 keyboard.js `composerKeyAction`).
//     iOS 16 SwiftUI 에는 키 이벤트 훅(onKeyPress 17+)이 없어 "입력칸에 줄바꿈 하나가 막 들어왔다"를 글 변화로 알아챈다.
//   · RoomOrder: 목록 순서 = 사용자가 정한 순서, 거기 없는 방은 기본 순서로 뒤에(웹 room-order.js). 최근 활동순으로 움직이지 않는다.
//   · Unread: 이 기기에서 마지막으로 본 seq 뒤에 남이 쓴 글이 있는가(웹 read-receipts.js 의 로컬판 — 릴레이에 읽음 확인 없음).
import Foundation

public enum ComposerKeys {
    public enum Action: Equatable {
        /// 그대로 둔다(화면 키보드의 줄바꿈 · Shift+Enter · 일반 입력).
        case keep
        /// 막 들어온 줄바꿈을 빼고 이 글을 보낸다.
        case send(String)
        /// 빈 글에서 Enter — 줄바꿈만 되돌린다.
        case revert(String)
    }

    /// `old` → `new` 가 줄바꿈 한 글자 삽입이고 하드웨어 키보드에서 Shift 없이 눌렸으면 전송.
    public static func decide(old: String, new: String, hardwareKeyboard: Bool, shift: Bool) -> Action {
        guard hardwareKeyboard, !shift, new.count == old.count + 1 else { return .keep }
        let o = Array(old), n = Array(new)
        var i = 0
        while i < o.count, o[i] == n[i] { i += 1 }
        guard n[i] == "\n", Array(n[(i + 1)...]) == Array(o[i...]) else { return .keep }
        return old.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .revert(old) : .send(old)
    }
}

public enum RoomOrder {
    /// 저장된 순서를 먼저, 거기 없는 방은 `rooms` 의 기존 순서(displayOrder)로 뒤에. 없어진 방 ID 는 무시.
    public static func apply(_ rooms: [RoomRecord], saved: [RoomID]) -> [RoomRecord] {
        let byId = Dictionary(rooms.map { ($0.room, $0) }, uniquingKeysWith: { a, _ in a })
        var seen = Set<RoomID>()
        var out: [RoomRecord] = []
        for id in saved where !seen.contains(id) {
            if let room = byId[id] { out.append(room); seen.insert(id) }
        }
        for room in rooms where !seen.contains(room.room) { out.append(room); seen.insert(room.room) }
        return out
    }

    /// 화면 목록(`ids`)에서 `from` 위치들을 `to` 앞으로 옮긴 새 순서(SwiftUI `onMove` 와 같은 뜻).
    public static func move(_ ids: [RoomID], from: IndexSet, to: Int) -> [RoomID] {
        let moving = from.sorted().filter { $0 < ids.count }.map { ids[$0] }
        var rest: [RoomID] = []
        var target = to
        for (index, id) in ids.enumerated() {
            if from.contains(index) {
                if index < to { target -= 1 }
            } else {
                rest.append(id)
            }
        }
        target = max(0, min(target, rest.count))
        rest.insert(contentsOf: moving, at: target)
        return rest
    }

    /// 목록 순서에서 `room` 의 이전(-1)/다음(+1) 방. 끝에서는 nil(돌아가지 않는다).
    public static func neighbor(of room: RoomID, in ids: [RoomID], step: Int) -> RoomID? {
        guard let index = ids.firstIndex(of: room) else { return ids.first }
        let next = index + step
        return ids.indices.contains(next) ? ids[next] : nil
    }
}

public enum Unread {
    /// 마지막 글이 남의 글(같은 사람의 다른 기기는 남이 아니다)이고, 이 기기가 본 seq 보다 뒤인가.
    public static func isUnread(last: MessageRecord?, myDevice: DeviceID, readSeq: Int64?) -> Bool {
        guard let last, !last.isMine(device: myDevice) else { return false }
        return last.seq > (readSeq ?? 0)
    }
}
