// `MlsStateStore` 참조 구현(메모리). 계약 테스트(`StateStoreContract`)의 기준이자 L3 가 저장 없이 동기화 로직을
// 시험할 때 쓰는 대역. 프로세스 간 잠금은 `Backing` 객체를 두 스토어가 공유하는 것으로 흉내 낸다.
import Foundation

public final class InMemoryStateBacking {
    final class Room {
        var bytes: Data?
        var generation: UInt64 = 0
        let lock = NSLock()           // "프로세스 간" 잠금 대역: 스토어 인스턴스가 달라도 같은 Room 을 잠근다
        var holder: Thread?
    }
    let mutex = NSLock()
    var rooms: [RoomID: Room] = [:]
    public init() {}
    func room(_ id: RoomID) -> Room {
        mutex.lock(); defer { mutex.unlock() }
        if let r = rooms[id] { return r }
        let r = Room(); rooms[id] = r; return r
    }
}

public final class InMemoryStateStore: MlsStateStore {
    final class Tx: StateTransaction {
        let room: RoomID
        let generation: UInt64
        private let backing: InMemoryStateBacking.Room
        private var open = true
        init(room: RoomID, backing: InMemoryStateBacking.Room) {
            self.room = room; self.backing = backing; self.generation = backing.generation
        }
        func load() throws -> Data? {
            guard open else { throw StateStoreError.notInTransaction }
            return backing.bytes
        }
        func save(_ exportState: Data) throws {
            guard open else { throw StateStoreError.notInTransaction }
            backing.bytes = exportState
            backing.generation += 1
        }
        func close() { open = false }
    }

    private let backing: InMemoryStateBacking

    public init(backing: InMemoryStateBacking = InMemoryStateBacking()) { self.backing = backing }

    public func withExclusive<T>(room: RoomID, timeout: TimeInterval, _ body: (StateTransaction) throws -> T) throws -> T {
        let r = backing.room(room)
        if r.holder === Thread.current { throw StateStoreError.io("re-entrant withExclusive") }
        guard r.lock.lock(before: Date(timeIntervalSinceNow: timeout)) else { throw StateStoreError.lockTimeout(room) }
        r.holder = Thread.current
        defer { r.holder = nil; r.lock.unlock() }
        // 스냅샷: body 가 throw 하면 디스크(여기선 메모리) 불변 — 저장 전 값을 되돌린다.
        let before = (r.bytes, r.generation)
        let tx = Tx(room: room, backing: r)
        do {
            let result = try body(tx)
            tx.close()
            return result
        } catch {
            tx.close()
            r.bytes = before.0; r.generation = before.1
            throw error
        }
    }

    public func generation(room: RoomID) throws -> UInt64 { backing.room(room).generation }
}

public final class InMemoryOutboxStore: OutboxStore {
    private var entries: [RoomID: [OutboxEntry]] = [:]
    private let lock = NSLock()
    public init() {}
    public func enqueue(_ entry: OutboxEntry) throws {
        lock.lock(); defer { lock.unlock() }
        entries[entry.room, default: []].append(entry)
    }
    public func pending(room: RoomID) throws -> [OutboxEntry] {
        lock.lock(); defer { lock.unlock() }
        return (entries[room] ?? []).filter { $0.status == .pending }
    }
    public func mark(room: RoomID, clientId: String, status: OutboxEntry.Status) throws {
        lock.lock(); defer { lock.unlock() }
        entries[room] = (entries[room] ?? []).map { e in var e = e; if e.clientId == clientId { e.status = status }; return e }
    }
    public func prune(room: RoomID, keepingLast: Int) throws {
        lock.lock(); defer { lock.unlock() }
        let all = entries[room] ?? []
        let done = all.filter { $0.status != .pending }
        let keepDone = Array(done.suffix(keepingLast))
        entries[room] = all.filter { $0.status == .pending } + keepDone
    }
}

public final class InMemoryCursorStore: CursorStore {
    private var cursors: [RoomID: Int64] = [:]
    private let lock = NSLock()
    public init() {}
    public func cursor(room: RoomID) throws -> Int64 { lock.lock(); defer { lock.unlock() }; return cursors[room] ?? 0 }
    public func setCursor(room: RoomID, seq: Int64) throws { lock.lock(); defer { lock.unlock() }; cursors[room] = seq }
}
