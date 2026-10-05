// `MlsStateStore` 계약 테스트 — **모든 구현이 통과해야 한다**(InMemory 참조 구현, L1 의 파일 구현).
// L1 은 자기 테스트 파일에서 `StateStoreContract.run(label:) { 두 스토어 }` 를 호출한다. `makePair` 는 "같은 디스크를 보는
// 두 프로세스" 를 흉내 내는 두 스토어 인스턴스를 돌려준다(파일 구현은 같은 경로를 여는 두 객체).
import XCTest
@testable import FamilyMLSCore

enum StateStoreContract {
    static func run(label: String, makePair: () throws -> (MlsStateStore, MlsStateStore), file: StaticString = #filePath, line: UInt = #line) throws {
        let (a, b) = try makePair()
        let room = "room-contract"

        // 1. 빈 상태: load nil, generation 0
        try a.withExclusive(room: room, timeout: 1) { tx in
            XCTAssertNil(try tx.load(), "\(label): empty load", file: file, line: line)
            XCTAssertEqual(tx.generation, 0, file: file, line: line)
        }
        XCTAssertEqual(try a.generation(room: room), 0, file: file, line: line)

        // 2. save → generation 1, 다른 "프로세스" 가 읽는다
        try a.withExclusive(room: room, timeout: 1) { tx in try tx.save(Data("state-1".utf8)) }
        XCTAssertEqual(try b.generation(room: room), 1, "\(label): other process sees generation", file: file, line: line)
        try b.withExclusive(room: room, timeout: 1) { tx in
            XCTAssertEqual(try tx.load(), Data("state-1".utf8), file: file, line: line)
            XCTAssertEqual(tx.generation, 1, file: file, line: line)
        }

        // 3. body throw → 디스크 불변
        struct Boom: Error {}
        XCTAssertThrowsError(try a.withExclusive(room: room, timeout: 1) { tx in
            try tx.save(Data("state-2".utf8))
            throw Boom()
        }, file: file, line: line)
        try b.withExclusive(room: room, timeout: 1) { tx in
            XCTAssertEqual(try tx.load(), Data("state-1".utf8), "\(label): rollback after throw", file: file, line: line)
            XCTAssertEqual(tx.generation, 1, file: file, line: line)
        }

        // 4. 트랜잭션 밖에서 핸들 사용 금지
        var leaked: StateTransaction?
        try a.withExclusive(room: room, timeout: 1) { tx in leaked = tx }
        XCTAssertThrowsError(try leaked?.load(), "\(label): handle dead after transaction", file: file, line: line)

        // 5. 단일 작성자: a 가 잡고 있는 동안 b 는 timeout
        let held = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let worker = Thread {
            try? a.withExclusive(room: room, timeout: 1) { _ in
                held.signal()
                release.wait()
            }
        }
        worker.start()
        held.wait()
        XCTAssertThrowsError(try b.withExclusive(room: room, timeout: 0.2) { _ in }, "\(label): second writer must time out", file: file, line: line) { error in
            XCTAssertEqual(error as? StateStoreError, .lockTimeout(room), file: file, line: line)
        }
        release.signal()

        // 6. 해제 뒤 b 가 잡고 쓴다; 다른 방은 독립
        try b.withExclusive(room: room, timeout: 1) { tx in try tx.save(Data("state-3".utf8)) }
        XCTAssertEqual(try a.generation(room: room), 2, file: file, line: line)
        XCTAssertEqual(try a.generation(room: "room-other"), 0, file: file, line: line)

        // 7. 재진입 금지(데드락 대신 오류)
        XCTAssertThrowsError(try a.withExclusive(room: room, timeout: 1) { _ in
            try a.withExclusive(room: room, timeout: 0.1) { _ in }
        }, "\(label): re-entrancy is an error", file: file, line: line)
    }
}

final class InMemoryStateStoreContractTests: XCTestCase {
    func testInMemoryStoreSatisfiesContract() throws {
        try StateStoreContract.run(label: "InMemory") {
            let backing = InMemoryStateBacking()
            return (InMemoryStateStore(backing: backing), InMemoryStateStore(backing: backing))
        }
    }

    func testOutboxAndCursorReferenceStores() throws {
        let outbox = InMemoryOutboxStore()
        let e1 = OutboxEntry(room: "r", clientId: "c1", kind: "application", epoch: 3, bytes: Data([1]), status: .pending, createdAt: Date())
        let e2 = OutboxEntry(room: "r", clientId: "c2", kind: "application", epoch: 3, bytes: Data([2]), status: .pending, createdAt: Date())
        try outbox.enqueue(e1); try outbox.enqueue(e2)
        XCTAssertEqual(try outbox.pending(room: "r").map(\.clientId), ["c1", "c2"])
        try outbox.mark(room: "r", clientId: "c1", status: .sent)
        XCTAssertEqual(try outbox.pending(room: "r").map(\.clientId), ["c2"])
        try outbox.prune(room: "r", keepingLast: 0)
        XCTAssertEqual(try outbox.pending(room: "r").map(\.clientId), ["c2"], "pending entries are never pruned")

        let cursors = InMemoryCursorStore()
        XCTAssertEqual(try cursors.cursor(room: "r"), 0)
        try cursors.setCursor(room: "r", seq: 41)
        XCTAssertEqual(try cursors.cursor(room: "r"), 41)
    }
}
