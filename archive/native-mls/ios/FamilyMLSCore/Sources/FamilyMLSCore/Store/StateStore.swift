// 계약 3 — 기기 상태 저장·단일 작성자 (CONTRACTS.md §3, #271 §4). **레인 L1 이 파일 기반으로 구현한다.**
//
// 의미(봇 persist_state·워커 K3 와 같은 계약):
//  - 한 방(room)의 MLS 상태는 한 시점에 **한 작성자**만 전진시킨다. App 과 NSE 는 별 프로세스이므로 구현은 OS
//    advisory lock(App Group 컨테이너의 `<room>.lock` 에 flock) 으로 직렬화한다.
//  - `withExclusive` 의 body 안에서만 load/save 가 가능하다. body 가 throw 하면 디스크는 불변이고 잠금은 해제된다.
//  - `save` 는 원자적(tmp → fsync → rename → 디렉터리 fsync)이고 generation 을 1 올린다. 트랜잭션이 시작될 때 읽은
//    generation 과 디스크가 다르면(다른 프로세스가 사이에 썼다면) `generationMismatch` 로 실패한다 — 잠금이 있으면
//    일어날 수 없지만 계약 테스트는 이 경로를 강제한다.
//  - 봉인(Keychain 키 + secretstream)·Data Protection 은 구현 내부. 이 프로토콜의 바이트는 **평문 export_state** 다.
//  - 네트워크는 절대 트랜잭션 안에서 하지 않는다(호출자 규칙; CONTRACTS.md §3.4).
import Foundation

public enum StateStoreError: Error, Equatable {
    case lockTimeout(RoomID)
    case generationMismatch(expected: UInt64, actual: UInt64)
    case notInTransaction
    case io(String)
    case sealing(String)
}

public protocol StateTransaction: AnyObject {
    var room: RoomID { get }
    /// 트랜잭션 시작 시점의 generation(0 = 상태 없음).
    var generation: UInt64 { get }
    /// 봉인 해제된 export_state 바이트. 상태가 없으면 nil.
    func load() throws -> Data?
    /// 원자 저장 + generation += 1. 같은 트랜잭션에서 두 번 호출하면 두 번째도 generation 을 올린다.
    func save(_ exportState: Data) throws
}

public protocol MlsStateStore: AnyObject {
    /// 단일 작성자 구간. `timeout` 안에 잠금을 못 얻으면 `lockTimeout`. 재진입 금지(같은 스레드에서 중첩 호출은 데드락이 아니라 오류여야 한다).
    func withExclusive<T>(room: RoomID, timeout: TimeInterval, _ body: (StateTransaction) throws -> T) throws -> T
    /// 잠금 없이 읽는 현재 generation — 앱이 "NSE 가 사이에 썼는가" 를 감지하는 데 쓴다.
    func generation(room: RoomID) throws -> UInt64
}

// MARK: - 부속 저장소 (같은 App Group, 같은 Data Protection; MLS 상태와 분리)

public struct OutboxEntry: Equatable {
    public enum Status: String { case pending, sent, reconciled }
    public let room: RoomID
    public let clientId: String
    public let kind: String            // commit | welcome | application
    public let epoch: Int64
    /// 정확 바이트 재시도(K4): 재시도는 **이 바이트 그대로** 보낸다. 재암호화 금지.
    public let bytes: Data
    public var status: Status
    public let createdAt: Date
    public init(room: RoomID, clientId: String, kind: String, epoch: Int64, bytes: Data, status: Status, createdAt: Date) {
        self.room = room; self.clientId = clientId; self.kind = kind; self.epoch = epoch; self.bytes = bytes; self.status = status; self.createdAt = createdAt
    }
}

public protocol OutboxStore: AnyObject {
    func enqueue(_ entry: OutboxEntry) throws
    func pending(room: RoomID) throws -> [OutboxEntry]
    func mark(room: RoomID, clientId: String, status: OutboxEntry.Status) throws
    /// 서버가 200/201 로 확인했고 커서가 지난 항목을 지운다. 장부 상한 256(#177 §3.5).
    func prune(room: RoomID, keepingLast: Int) throws
}

public protocol CursorStore: AnyObject {
    /// 마지막으로 **처리·영속 완료**한 seq (relay `?after=`·`?ack=` 의 값).
    func cursor(room: RoomID) throws -> Int64
    func setCursor(room: RoomID, seq: Int64) throws
}
