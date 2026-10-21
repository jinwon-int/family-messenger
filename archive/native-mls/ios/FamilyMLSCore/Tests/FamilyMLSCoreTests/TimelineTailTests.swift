// #469 — 타임라인은 방의 **최신** N 건: `messageHeadsTail` 은 끝에서 읽어 오름차순으로 돌려준다.
// 종전 `messageHeads(after: 0, limit: N)` 은 가장 오래된 N 건이라 N+1 번째 행부터 화면에 오르지 않았다.
import XCTest
@testable import FamilyMLSCore

final class TimelineTailTests: XCTestCase {
    private func tempStore() throws -> (FileSQLiteStore, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("fmtail-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return (try FileSQLiteStore(directory: dir), dir)
    }

    private func record(_ room: RoomID, _ seq: Int64, attachment: Data? = nil) -> MessageRecord {
        MessageRecord(room: room, seq: seq, senderDevice: "mom-iphone-a1b2c3", clientId: "c\(seq)",
                      kind: attachment == nil ? .text : .attachment, body: attachment == nil ? "m\(seq)" : "image/jpeg",
                      attachment: attachment, receivedAt: Date(), decryptedBy: .app)
    }

    func testSQLiteTailReturnsNewestRowsAscendingWithoutBlobs() throws {
        let (store, dir) = try tempStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let blob = Data(repeating: 0xAB, count: 4_096)
        for seq in Int64(1)...503 { try store.insert(record("family", seq, attachment: seq == 503 ? blob : nil)) }
        try store.insert(record("other", 1))

        let tail = try store.messageHeadsTail(room: "family", limit: 500)
        XCTAssertEqual(tail.count, 500)
        XCTAssertEqual(tail.first?.record.seq, 4, "the three oldest rows fall out of the window")
        XCTAssertEqual(tail.last?.record.seq, 503, "the newest row — including one just sent — is always shown")
        XCTAssertEqual(tail.map(\.record.seq), tail.map(\.record.seq).sorted(), "ascending for the timeline")
        XCTAssertTrue(tail.allSatisfy { $0.record.attachment == nil }, "heads carry no blob")
        XCTAssertEqual(tail.last?.attachmentBytes, blob.count)
        XCTAssertEqual(tail.allSatisfy { $0.record.room == "family" }, true)

        // 종전 읽기와의 대비(동결 `MessageStore` 는 그대로): 앞 500건은 503 을 포함하지 않는다.
        let oldest = try store.messageHeads(room: "family", after: 0, limit: 500)
        XCTAssertEqual(oldest.last?.record.seq, 500)
    }

    func testSQLiteTailSmallRoomAndEdges() throws {
        let (store, dir) = try tempStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        XCTAssertEqual(try store.messageHeadsTail(room: "empty", limit: 500).count, 0)
        for seq in Int64(1)...3 { try store.insert(record("r", seq)) }
        XCTAssertEqual(try store.messageHeadsTail(room: "r", limit: 500).map(\.record.seq), [1, 2, 3], "fewer rows than the window: all of them")
        XCTAssertEqual(try store.messageHeadsTail(room: "r", limit: 2).map(\.record.seq), [2, 3])
        XCTAssertEqual(try store.messageHeadsTail(room: "r", limit: 0).count, 0)
    }

    /// 프로토콜 확장 기본 구현(메모리 저장소·대역용): 전부 읽어 꼬리.
    func testDefaultTailSuffixesTheAscendingRead() throws {
        final class HeadsOnly: AttachmentLoading {
            var heads: [MessageHead] = []
            func messageHeads(room: RoomID, after seq: Int64, limit: Int) throws -> [MessageHead] {
                Array(heads.filter { $0.record.room == room && $0.record.seq > seq }.prefix(limit))
            }
            func attachment(room: RoomID, seq: Int64) throws -> Data? { nil }
        }
        let store = HeadsOnly()
        store.heads = (1...7).map { MessageHead(record: record("r", Int64($0)), attachmentBytes: 0) }
        XCTAssertEqual(try store.messageHeadsTail(room: "r", limit: 3).map(\.record.seq), [5, 6, 7])
        XCTAssertEqual(try store.messageHeadsTail(room: "r", limit: 50).map(\.record.seq), Array(1...7).map(Int64.init))
        XCTAssertEqual(try store.messageHeadsTail(room: "r", limit: 0).count, 0)
    }
}
