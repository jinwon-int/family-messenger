// "이 기기 지우기"(§9-5) 의 저장소 쪽: `FileStateStore.removeAllState`(identity 슬롯 포함, 방마다 잠금) + `FileSQLiteStore.wipe`(4 테이블, 열린 연결 유지).
import XCTest
@testable import FamilyMLSCore

final class FileWipeTests: XCTestCase {
    private func makeDir(_ prefix: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func makeStateStore(_ dir: URL) throws -> FileStateStore {
        #if canImport(CryptoKit)
        return try FileStateStore(directory: dir, sealer: ChaChaPolySealer(keySource: StaticSealKeySource(key: Data(repeating: 9, count: 32))))
        #else
        return try FileStateStore(directory: dir, sealer: PassthroughSealer())
        #endif
    }

    func testRemoveAllStateClearsEveryRoomIncludingIdentitySlot() throws {
        let dir = try makeDir("fmwipe")
        let store = try makeStateStore(dir)
        for room in ["_identity", "family", "kids"] {
            try store.withExclusive(room: room, timeout: 1) { try $0.save(Data(room.utf8)) }
        }
        XCTAssertEqual(try store.roomsOnDisk(), ["_identity", "family", "kids"])
        try store.removeAllState(timeout: 1)
        XCTAssertEqual(try store.roomsOnDisk(), [], "no state or generation file is left")
        for room in ["_identity", "family", "kids"] {
            XCTAssertEqual(try store.generation(room: room), 0, room)
            XCTAssertNil(try store.withExclusive(room: room, timeout: 1) { try $0.load() }, room)
        }
        try store.removeAllState(timeout: 1)   // 멱등(빈 디렉터리)
        try store.withExclusive(room: "family", timeout: 1) { try $0.save(Data("fresh".utf8)) }
        XCTAssertEqual(try store.generation(room: "family"), 1, "a new device starts its generations over")
    }

    func testRemoveAllStateStopsAtAHeldLockAndLeavesTheRestForARetry() throws {
        let dir = try makeDir("fmwipe")
        let holder = try makeStateStore(dir)
        let wiper = try makeStateStore(dir)
        for room in ["a", "b"] { try holder.withExclusive(room: room, timeout: 1) { try $0.save(Data(room.utf8)) } }
        let holding = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let thread = Thread {
            try? holder.withExclusive(room: "b", timeout: 1) { _ in
                holding.signal()
                _ = release.wait(timeout: .now() + 5)
            }
        }
        thread.start()
        XCTAssertEqual(holding.wait(timeout: .now() + 5), .success)
        XCTAssertThrowsError(try wiper.removeAllState(timeout: 0.2)) { XCTAssertEqual($0 as? StateStoreError, .lockTimeout("b")) }
        XCTAssertEqual(try wiper.generation(room: "a"), 0, "rooms before the held one were removed")
        XCTAssertEqual(try wiper.generation(room: "b"), 1, "the held room is untouched")
        release.signal()
        while !thread.isFinished { Thread.sleep(forTimeInterval: 0.01) }
        try wiper.removeAllState(timeout: 1)
        XCTAssertEqual(try wiper.roomsOnDisk(), [])
    }

    func testSQLiteWipeEmptiesAllTablesAndKeepsTheConnectionUsable() throws {
        let dir = try makeDir("fmwipedb")
        let store = try FileSQLiteStore(directory: dir)
        try store.upsertRoom(RoomRecord(room: "family", epoch: 3, revision: 1, haltedReason: "history_gap", displayOrder: 0))
        try store.insert(MessageRecord(room: "family", seq: 1, senderDevice: "mom-iphone-1", clientId: "c1", kind: .text, body: "hi",
                                       attachment: nil, receivedAt: Date(), decryptedBy: .app))
        try store.enqueue(OutboxEntry(room: "family", clientId: "c2", kind: "application", epoch: 3, bytes: Data([1, 2]), status: .pending, createdAt: Date()))
        try store.setCursor(room: "family", seq: 1)

        try store.wipe()

        XCTAssertEqual(try store.rooms(), [])
        XCTAssertEqual(try store.messages(room: "family", after: 0, limit: 10), [])
        XCTAssertEqual(try store.pending(room: "family"), [])
        XCTAssertEqual(try store.cursor(room: "family"), 0)
        XCTAssertEqual(try store.debugScalar("SELECT version FROM schema_version"), Int64(MessageSchema.version), "schema row survives")

        // 같은 연결로 계속 쓴다(새 기기의 첫 방).
        try store.upsertRoom(RoomRecord(room: "family", epoch: 0, revision: 0, haltedReason: nil, displayOrder: 0))
        try store.setCursor(room: "family", seq: 5)
        XCTAssertEqual(try store.rooms().map(\.room), ["family"])
        XCTAssertEqual(try store.cursor(room: "family"), 5)
        // 다른 인스턴스(NSE 대역)가 열어도 비어 있던 것이 보인다 — 파일 unlink 가 아니라 행 삭제라서.
        XCTAssertEqual(try FileSQLiteStore(directory: dir).messages(room: "family", after: 0, limit: 10), [])
    }
}
