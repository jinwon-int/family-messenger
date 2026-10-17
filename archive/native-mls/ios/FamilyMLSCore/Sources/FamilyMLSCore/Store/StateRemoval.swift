// ⛔ 정지 해제 경로의 저장소 쪽 계약(#271 §9-4 "정지 해제 안내", §9-5 "이 기기 지우기").
//
// `MlsStateStore`(StateStore.swift, 동결)는 상태를 **지우는** 연산이 없다. 정지(commit 정책 위반·이력 공백·방 제거)에서
// 빠져나오는 길은 relay-app·봇과 같다: 이 기기의 **방 상태를 버리고** 운영자에게 다시 초대받는 것(RELAY-APP.md §정지).
// 거부된 commit 을 받아들이는 길은 어디에도 없다 — 삭제는 자기 상태만 지우고, 방에 다시 들어가는 것은 상대의 새 Welcome 뿐이다.
//
// 구현은 선택 적합(optional conformance): 앱은 `stateStore as? RoomStateRemoving` 으로 묻고, 지원하지 않는 저장소면 정지 해제를
// 제공하지 않는다. 파일 저장소(`FileStateStore`)는 방 flock 을 잡은 채 지운다(NSE 가 사이에 저장해 파일을 되살리지 못하게).
import Foundation

public protocol RoomStateRemoving: AnyObject {
    /// 한 방의 MLS 상태(state·generation 미러)를 지운다. 잠금은 구현이 잡는다. 상태가 없어도 성공(멱등).
    /// `generation(room:)` 은 그 뒤 0 이다 — 다음 트랜잭션의 `load()` 는 nil 을 돌려주고 시드(identity)에서 다시 시작한다.
    func removeState(room: RoomID, timeout: TimeInterval) throws
    /// 이 저장소의 **모든** 방 상태(`_identity` 슬롯 포함)를 지운다 — "이 기기 지우기"(§9-5). 방마다 잠금을 잡고 지운다.
    /// 하나라도 잠금을 못 얻으면 거기서 throw 하고 나머지는 그대로 둔다(부분 삭제 = 호출자가 다시 부른다, 멱등).
    func removeAllState(timeout: TimeInterval) throws
}

extension FileStateStore: RoomStateRemoving {
    public func removeState(room: RoomID, timeout: TimeInterval) throws {
        let name = try Self.sanitizedRoom(room)
        let lock = FileLock(path: directory.appendingPathComponent("\(name).lock").path, room: room)
        try lock.acquire(timeout: timeout)
        defer { lock.release() }
        for suffix in ["state.tmp", "gen.tmp", "state", "gen"] {
            let url = directory.appendingPathComponent("\(name).\(suffix)")
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            try FileManager.default.removeItem(at: url)
        }
        _ = try FileSys.fsyncDirectory(path: directory.path)
        // `.lock` 앵커는 남긴다(0바이트, 비밀 없음) — 다른 프로세스가 같은 inode 를 잡고 기다리는 중일 수 있다.
    }

    public func removeAllState(timeout: TimeInterval) throws {
        for room in try roomsOnDisk() { try removeState(room: room, timeout: timeout) }
    }

    /// 디렉터리의 `<room>.state|.gen|.state.tmp|.gen.tmp` 에서 방 이름을 모은다(`.lock` 만 남은 방은 지울 것이 없다).
    func roomsOnDisk() throws -> [RoomID] {
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        var rooms = Set<RoomID>()
        for file in names {
            for suffix in [".state.tmp", ".gen.tmp", ".state", ".gen"] where file.hasSuffix(suffix) {
                rooms.insert(String(file.dropLast(suffix.count)))
                break
            }
        }
        return rooms.sorted()
    }
}

/// 「목록에서 지우기」(#389) — 내보내졌거나(`removed_from_room`) 닫힌(`room_closed`) 방을 이 기기에서 잊는다.
/// `MessageStore`(동결)에는 삭제 연산이 없으므로 `RoomStateRemoving` 처럼 선택 적합이다: 앱은 `messageStore as? RoomForgetting` 으로 묻는다.
/// 지우는 것은 그 방의 `rooms` 행과 `messages` 행뿐이다(커서·outbox·MLS 상태는 각자의 저장소 계약으로 앱이 정리한다).
/// 릴레이는 건드리지 않는다 — 내보내진 기기는 `GET /v2/rooms` 에 `member=false` 로, 닫힌 방은 `closed=true` 로 나와 다시 생기지 않는다.
public protocol RoomForgetting: AnyObject {
    /// 한 방의 방 행·메시지 행을 한 번에 지운다. 없으면 성공(멱등).
    func forgetRoom(_ room: RoomID) throws
}

extension FileSQLiteStore: RoomForgetting {}

