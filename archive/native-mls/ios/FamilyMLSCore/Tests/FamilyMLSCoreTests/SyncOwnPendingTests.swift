// #665 내 글 평문 영속 — `RoomSyncEngine` 이 outbox 항목과 함께 기록 재료(`OwnPendingStore`)를 남기고, 서버가 seq 를 주면
// 즉시 송신이든 재시작 뒤 `flushOutbox` 든 같은 길로 `MessageStore` 에 기록한 뒤 지운다. 저장소가 없으면 종전과 같다.
import XCTest
@testable import FamilyMLSCore

final class SyncOwnPendingTests: XCTestCase {
    let alice = "alice-pc"
    let carol = "carol-ipad"

    /// 이미 참여한 기기 + 기록 재료 저장소.
    private func harness(pending: [String]? = nil) throws -> (SyncHarness, InMemoryOwnPendingStore) {
        let h = try SyncHarness()
        let own = InMemoryOwnPendingStore()
        h.ownPending = own
        try h.restart()
        try h.store.seed(room: h.room, .joined([alice, h.me].sorted(), epoch: 1, pending: pending))
        h.relay.epoch = 1
        h.relay.members = [alice, h.me]
        return (h, own)
    }

    func testSentTextIsRecordedFromTheMaterialAndTheRowIsRemoved() async throws {
        let (h, own) = try harness()

        let outcome = try await h.sync.send(text: "hi")

        guard case .sent(let clientId, let seq, false) = outcome else { return XCTFail("\(outcome)") }
        let stored = try h.messages.messages(room: h.room, after: 0, limit: 10)
        XCTAssertEqual(stored.map(\.body), ["hi"])
        XCTAssertEqual(stored.first?.seq, seq)
        XCTAssertEqual(stored.first?.clientId, clientId)
        XCTAssertEqual(stored.first?.senderDevice, h.me)
        XCTAssertEqual(stored.first?.kind, .text)
        XCTAssertEqual(stored.first?.decryptedBy, .app)
        XCTAssertTrue(try own.ownPending(room: h.room).isEmpty, "recorded → material removed")
    }

    func testWithoutAMaterialStoreNothingIsRecorded() async throws {
        let h = try SyncHarness()
        try h.store.seed(room: h.room, .joined([alice, h.me].sorted(), epoch: 1, pending: nil))
        h.relay.epoch = 1
        h.relay.members = [alice, h.me]

        guard case .sent = try await h.sync.send(text: "hi") else { return XCTFail() }

        XCTAssertTrue(try h.messages.messages(room: h.room, after: 0, limit: 10).isEmpty, "종전: 평문을 쥔 호출자가 기록한다")
    }

    /// 네트워크 실패로 outbox 에 남은 글: 재료도 남는다. 새 엔진(재시작)의 `flushOutbox` 가 같은 바이트로 보내고 **그때** 기록한다.
    func testQueuedEntryIsRecordedWhenANewEngineFlushesIt() async throws {
        let (h, own) = try harness()
        h.relay.postErrors = [.network("lost")]

        guard case .queued(let clientId) = try await h.sync.send(text: "later") else { return XCTFail() }
        XCTAssertEqual(try own.ownPending(room: h.room).map(\.clientId), [clientId])
        XCTAssertEqual(try own.ownPending(room: h.room).first?.body, "later")
        XCTAssertTrue(try h.messages.messages(room: h.room, after: 0, limit: 10).isEmpty, "not recorded before the relay confirms")

        try h.restart()
        let outcomes = try await h.sync.flushOutbox()

        guard case .sent(clientId, let seq, false)? = outcomes.first else { return XCTFail("\(outcomes)") }
        let stored = try h.messages.messages(room: h.room, after: 0, limit: 10)
        XCTAssertEqual(stored.map(\.body), ["later"])
        XCTAssertEqual(stored.first?.seq, seq)
        XCTAssertEqual(stored.first?.clientId, clientId)
        XCTAssertEqual(stored.first?.receivedAt, try? XCTUnwrap(h.outbox.entry(room: h.room, clientId: clientId)).createdAt,
                       "내 글의 시각 = 보낸 순간(#405)")
        XCTAssertTrue(try own.ownPending(room: h.room).isEmpty)
        XCTAssertEqual(h.relay.posts.count, 2, "같은 바이트 재시도 1회")
        XCTAssertEqual(h.relay.posts[0].bytes, h.relay.posts[1].bytes)
    }

    /// 504 류(저장은 됐는데 응답을 잃음) → 재시도는 `200 duplicate` — 그래도 한 번만 기록한다.
    func testDuplicateConfirmationRecordsOnce() async throws {
        let (h, own) = try harness()
        h.relay.dropNextPostResponse = true

        guard case .queued = try await h.sync.send(text: "once") else { return XCTFail() }
        let outcomes = try await h.sync.flushOutbox()

        guard case .sent(_, _, true)? = outcomes.first else { return XCTFail("\(outcomes)") }
        XCTAssertEqual(try h.messages.messages(room: h.room, after: 0, limit: 10).map(\.body), ["once"])
        XCTAssertTrue(try own.ownPending(room: h.room).isEmpty)
    }

    /// 409 → 옛 항목 reconciled: 그 재료는 닫고, 새 client_id 로 재암호화한 글이 기록된다(재료 한 벌만 남았다가 사라진다).
    func testCasMismatchClosesTheOldMaterialAndRecordsUnderTheNewClientId() async throws {
        let (h, own) = try harness(pending: [alice, carol, "me-iphone-aaaaaa"].sorted())
        h.relay.onPost = { [unowned h, alice, carol] _ in
            guard h.relay.posts.count == 1 else { return }
            h.relay.inject(device: alice, kind: .commit, bytes: FakeCommit(committer: alice, adds: [carol]).bytes)
            h.relay.members = [alice, carol, h.me]
        }

        let outcome = try await h.sync.send(text: "hi")

        guard case .sent(let clientId, _, false) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(h.relay.posts.count, 2)
        XCTAssertEqual(clientId, h.relay.posts[1].clientId)
        let stored = try h.messages.messages(room: h.room, after: 0, limit: 10)
        XCTAssertEqual(stored.map(\.body), ["hi"])
        XCTAssertEqual(stored.first?.clientId, clientId, "기록은 실제로 들어간 client_id")
        XCTAssertTrue(try own.ownPending(room: h.room).isEmpty)
    }

    /// 영구 거절(413 등): 항목도 재료도 닫힌다 — 평문은 호출자가 쥐고 있어 「전송 안 됨」으로 보인다.
    func testPermanentRefusalClosesTheMaterial() async throws {
        let (h, own) = try harness()
        h.relay.postErrors = [.refused(code: "room_bytes_cap", status: 413)]

        do { _ = try await h.sync.send(text: "big"); XCTFail() }
        catch RelayError.refused(let code, _) { XCTAssertEqual(code, "room_bytes_cap") }

        XCTAssertTrue(try own.ownPending(room: h.room).isEmpty)
        XCTAssertTrue(try h.outbox.pending(room: h.room).isEmpty)
        XCTAssertTrue(try h.messages.messages(room: h.room, after: 0, limit: 10).isEmpty)
    }

    /// `flushOutbox` 가 닫은(reconciled) 항목의 재료는 남긴다 — 앱이 그걸로 새로 암호화해 보낸다(평문이 메모리에 없는 재시작 뒤).
    func testReconciledInFlushKeepsTheMaterialForTheCaller() async throws {
        let (h, own) = try harness()
        h.relay.postErrors = [.network("lost")]
        guard case .queued(let clientId) = try await h.sync.send(text: "later") else { return XCTFail() }

        try h.restart()
        h.relay.postErrors = [.cas(epoch: 2, revision: 1)]
        let outcomes = try await h.sync.flushOutbox()

        XCTAssertEqual(outcomes, [.reconciled(clientId: clientId)])
        XCTAssertEqual(try own.ownPending(room: h.room, clientId: clientId)?.body, "later")
        XCTAssertEqual(try h.outbox.entry(room: h.room, clientId: clientId)?.status, .reconciled)
    }

    func testAttachmentAndFileV2MaterialsLookLikeReceivedRecords() async throws {
        let (h, own) = try harness()
        let bytes = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 0x4A, 0x46, 0x49, 0x46])   // JPEG 머리

        guard case .sent(_, let seq1, _) = try await h.sync.send(attachment: bytes) else { return XCTFail() }
        let v1 = try XCTUnwrap(h.messages.messages(room: h.room, after: seq1 - 1, limit: 1).first)
        XCTAssertEqual(v1.kind, .attachment)
        XCTAssertEqual(v1.body, AttachmentFormat.sniffMime(bytes))
        XCTAssertEqual(v1.attachment, bytes)

        let descriptor = Data(#"{"v":2,"blob":"x","size":3,"key":"k","nonce":"n","mime":"image/png"}"#.utf8)
        guard case .sent(_, let seq2, _) = try await h.sync.resend(fileV2Descriptor: descriptor, mime: "image/png") else { return XCTFail() }
        let v2 = try XCTUnwrap(h.messages.messages(room: h.room, after: seq2 - 1, limit: 1).first)
        XCTAssertEqual(v2.kind, .fileV2)
        XCTAssertEqual(v2.body, "image/png")
        XCTAssertEqual(v2.attachment, descriptor, "설명자만 남긴다(원본 바이트 아님)")
        XCTAssertTrue(try own.ownPending(room: h.room).isEmpty)
    }
}
