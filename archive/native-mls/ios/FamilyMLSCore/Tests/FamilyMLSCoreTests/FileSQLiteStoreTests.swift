// 계약 4 검증 — `FileSQLiteStore`: 동결 DDL v1 한 DB 에 MessageStore·OutboxStore·CursorStore.
// InMemory 참조 구현(`testOutboxAndCursorReferenceStores`)과 같은 규율을 파일 구현이 따르는지 확인한다.
import XCTest
@testable import FamilyMLSCore

final class FileSQLiteStoreTests: XCTestCase {
    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("fml1db-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func makeStore(_ dir: URL) throws -> FileSQLiteStore {
        try FileSQLiteStore(directory: dir)
    }

    private func record(_ room: RoomID = "r1", _ seq: Int64, body: String = "hello",
                        attachment: Data? = nil, kind: MessageRecord.Kind = .text,
                        decryptedBy: MessageRecord.DecryptedBy = .app) -> MessageRecord {
        MessageRecord(room: room, seq: seq, senderDevice: "actor-dev1", clientId: "dev1",
                      kind: kind, body: body, attachment: attachment,
                      receivedAt: Date(timeIntervalSince1970: 1_700_000_000 + Double(seq)),
                      decryptedBy: decryptedBy)
    }

    // MARK: 스키마

    func testSchemaVersionV1WrittenOnce() throws {
        let dir = try makeTempDir()
        let store = try makeStore(dir)
        XCTAssertEqual(try store.debugScalar("SELECT version FROM schema_version"), Int64(MessageSchema.version))
        XCTAssertEqual(try store.debugScalar("SELECT COUNT(*) FROM schema_version"), Int64(1))

        // 같은 파일을 다시 열어도 v1 로 계속 열린다(마이그레이션 경로 아님).
        _ = try FileSQLiteStore(directory: dir)
        XCTAssertEqual(try store.debugScalar("SELECT COUNT(*) FROM schema_version"), Int64(1))
    }

    func testAllFrozenTablesExist() throws {
        let dir = try makeTempDir()
        let store = try makeStore(dir)
        for table in ["schema_version", "rooms", "messages", "outbox", "cursors"] {
            let count = try store.debugScalar("SELECT COUNT(*) FROM \(table)")
            XCTAssertNotNil(count, "table \(table) missing")
        }
    }

    // MARK: MessageStore

    func testMessageInsertAndQueryOrderLimit() throws {
        let dir = try makeTempDir()
        let store = try makeStore(dir)
        try store.insert(record("r1", 1))
        try store.insert(record("r1", 2, body: "att", attachment: Data([9, 8, 7])))
        try store.insert(record("r1", 3, kind: .undecryptable, decryptedBy: .nse))
        try store.insert(record("r2", 10))

        XCTAssertEqual(try store.messages(room: "r1", after: 0, limit: 10).map(\.seq), [1, 2, 3])
        XCTAssertEqual(try store.messages(room: "r1", after: 1, limit: 1).map(\.seq), [2])
        XCTAssertEqual(try store.messages(room: "r1", after: 0, limit: 2).map(\.seq), [1, 2])
        XCTAssertEqual(try store.messages(room: "r2", after: 0, limit: 10).count, 1)

        let second = try store.messages(room: "r1", after: 1, limit: 1)[0]
        XCTAssertEqual(second.body, "att")
        XCTAssertEqual(second.attachment, Data([9, 8, 7]))
        XCTAssertEqual(second.senderActor, "actor")
        let third = try store.messages(room: "r1", after: 2, limit: 1)[0]
        XCTAssertEqual(third.kind, .undecryptable)
        XCTAssertEqual(third.decryptedBy, .nse)
        XCTAssertNil(try store.messages(room: "r1", after: 0, limit: 10)[0].attachment)
    }

    func testMessageDuplicatePrimaryKeyThrows() throws {
        let dir = try makeTempDir()
        let store = try makeStore(dir)
        try store.insert(record("r1", 1))
        XCTAssertThrowsError(try store.insert(record("r1", 1)))
    }

    // MARK: rooms

    func testRoomUpsertOrderAndHaltedReason() throws {
        let dir = try makeTempDir()
        let store = try makeStore(dir)
        try store.upsertRoom(RoomRecord(room: "family", epoch: 3, revision: 5, haltedReason: nil, displayOrder: 1))
        try store.upsertRoom(RoomRecord(room: "parents", epoch: 1, revision: 0, haltedReason: nil, displayOrder: 0))
        XCTAssertEqual(try store.rooms().map(\.room), ["parents", "family"])

        // upsert 갱신
        try store.upsertRoom(RoomRecord(room: "family", epoch: 4, revision: 6, haltedReason: nil, displayOrder: 1))
        XCTAssertEqual(try store.rooms().first { $0.room == "family" }?.epoch, 4)

        // 정지 사유 유지·해제
        try store.setHalted(room: "family", reason: "history_gap")
        XCTAssertEqual(try store.rooms().first { $0.room == "family" }?.haltedReason, "history_gap")
        try store.setHalted(room: "family", reason: nil)
        XCTAssertNil(try store.rooms().first { $0.room == "family" }?.haltedReason)
    }

    // MARK: OutboxStore

    func testOutboxPendingMarkPruneMatchesReferenceDiscipline() throws {
        let dir = try makeTempDir()
        let store = try makeStore(dir)
        let e1 = OutboxEntry(room: "r", clientId: "c1", kind: "application", epoch: 3, bytes: Data([1]), status: .pending, createdAt: Date())
        let e2 = OutboxEntry(room: "r", clientId: "c2", kind: "application", epoch: 3, bytes: Data([2]), status: .pending, createdAt: Date())
        try store.enqueue(e1)
        try store.enqueue(e2)

        XCTAssertEqual(try store.pending(room: "r").map(\.clientId), ["c1", "c2"], "insertion order")
        XCTAssertEqual(try store.pending(room: "r").map(\.bytes), [Data([1]), Data([2])], "exact bytes preserved")

        try store.mark(room: "r", clientId: "c1", status: .sent)
        XCTAssertEqual(try store.pending(room: "r").map(\.clientId), ["c2"])

        // pending 은 절대 prune 되지 않는다(참조 구현과 동일).
        try store.prune(room: "r", keepingLast: 0)
        XCTAssertEqual(try store.pending(room: "r").map(\.clientId), ["c2"])

        // 완료 항목은 keepingLast 만큼만 남긴다.
        try store.mark(room: "r", clientId: "c2", status: .reconciled)
        let e3 = OutboxEntry(room: "r", clientId: "c3", kind: "commit", epoch: 3, bytes: Data([3]), status: .pending, createdAt: Date())
        try store.enqueue(e3)
        try store.mark(room: "r", clientId: "c3", status: .sent)
        try store.prune(room: "r", keepingLast: 1)
        XCTAssertEqual(try store.pending(room: "r").count, 0)
        XCTAssertEqual(try store.debugScalar("SELECT COUNT(*) FROM outbox"), Int64(1), "only the last done entry kept")
    }

    func testOutboxDuplicatePrimaryKeyThrows() throws {
        let dir = try makeTempDir()
        let store = try makeStore(dir)
        let entry = OutboxEntry(room: "r", clientId: "c1", kind: "application", epoch: 3, bytes: Data([1]), status: .pending, createdAt: Date())
        try store.enqueue(entry)
        XCTAssertThrowsError(try store.enqueue(entry))
    }

    func testOutboxSha256ColumnFilled() throws {
        let dir = try makeTempDir()
        let store = try makeStore(dir)
        try store.enqueue(OutboxEntry(room: "r", clientId: "c1", kind: "application", epoch: 3, bytes: Data("bytes".utf8), status: .pending, createdAt: Date()))
        XCTAssertEqual(try store.debugScalar("SELECT LENGTH(sha256) FROM outbox"), Int64(64), "sha256 hex")
    }

    // MARK: CursorStore

    func testCursorDefaultsAndUpsert() throws {
        let dir = try makeTempDir()
        let store = try makeStore(dir)
        XCTAssertEqual(try store.cursor(room: "r"), 0)
        try store.setCursor(room: "r", seq: 41)
        XCTAssertEqual(try store.cursor(room: "r"), 41)
        try store.setCursor(room: "r", seq: 42)
        XCTAssertEqual(try store.cursor(room: "r"), 42)
        try store.setCursor(room: "other", seq: 7)
        XCTAssertEqual(try store.cursor(room: "r"), 42)
        XCTAssertEqual(try store.cursor(room: "other"), 7)
    }

    // MARK: 한 DB · 재시작

    func testThreeStoresOneDatabaseAndReopen() throws {
        let dir = try makeTempDir()
        let store = try makeStore(dir)
        let messages: MessageStore = store
        let outbox: OutboxStore = store
        let cursors: CursorStore = store
        try messages.insert(record("r", 1))
        try outbox.enqueue(OutboxEntry(room: "r", clientId: "c1", kind: "application", epoch: 1, bytes: Data([1]), status: .pending, createdAt: Date()))
        try cursors.setCursor(room: "r", seq: 1)

        // 다시 열어 세 종류가 모두 남아 있는다(단일 DB 영속 증명 + 스키마 검증 경로).
        let reopened = try FileSQLiteStore(directory: dir)
        XCTAssertEqual(try reopened.messages(room: "r", after: 0, limit: 10).count, 1)
        XCTAssertEqual(try reopened.pending(room: "r").count, 1)
        XCTAssertEqual(try reopened.cursor(room: "r"), 1)
    }

    func testEmptyBodyAndEmptyBlobRoundTrip() throws {
        let dir = try makeTempDir()
        let store = try makeStore(dir)
        try store.insert(record("r", 1, body: "", attachment: Data()))
        let loaded = try store.messages(room: "r", after: 0, limit: 10)
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded[0].body, "")
        XCTAssertEqual(loaded[0].attachment, Data())
    }
}
