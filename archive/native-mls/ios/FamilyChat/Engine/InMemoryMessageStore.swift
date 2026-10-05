// 뼈대용 `MessageStore` 메모리 구현(화면이 돌아가게만). L1 의 SQLite 구현이 머지되면 교체한다.
import Foundation
import FamilyMLSCore

final class InMemoryMessageStore: MessageStore {
    private var records: [RoomID: [MessageRecord]] = [:]
    private var roomRecords: [RoomID: RoomRecord] = [:]
    private let lock = NSLock()

    init(seedRooms: [RoomRecord] = []) {
        for r in seedRooms { roomRecords[r.room] = r }
    }

    func insert(_ record: MessageRecord) throws {
        lock.lock(); defer { lock.unlock() }
        var list = records[record.room] ?? []
        guard !list.contains(where: { $0.seq == record.seq }) else { return }
        list.append(record)
        list.sort { $0.seq < $1.seq }
        records[record.room] = list
    }

    func messages(room: RoomID, after seq: Int64, limit: Int) throws -> [MessageRecord] {
        lock.lock(); defer { lock.unlock() }
        return Array((records[room] ?? []).filter { $0.seq > seq }.prefix(limit))
    }

    func upsertRoom(_ room: RoomRecord) throws {
        lock.lock(); defer { lock.unlock() }
        roomRecords[room.room] = room
    }

    func rooms() throws -> [RoomRecord] {
        lock.lock(); defer { lock.unlock() }
        return roomRecords.values.sorted { ($0.displayOrder, $0.room) < ($1.displayOrder, $1.room) }
    }

    func setHalted(room: RoomID, reason: String?) throws {
        lock.lock(); defer { lock.unlock() }
        guard var r = roomRecords[room] else { return }
        r.haltedReason = reason
        roomRecords[room] = r
    }
}
