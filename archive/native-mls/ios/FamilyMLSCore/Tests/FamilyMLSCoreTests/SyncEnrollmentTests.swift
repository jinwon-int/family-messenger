// 등록 대기 흐름 테스트 (#276 L3 5번) — 403 device_subject_mismatch → "운영자 등록 대기" + 등록 JSON(relay-app §1 과 같은 키).
import XCTest
@testable import FamilyMLSCore

final class SyncEnrollmentTests: XCTestCase {
    let alice = "alice-pc"
    let mismatch = RelayError.refused(code: RelayErrorCode.deviceSubjectMismatch.rawValue, status: 403)

    private var expected: EnrollmentRequest {
        EnrollmentRequest(deviceId: "me-iphone-aaaaaa", actor: "me", subject: "cf-sub-me",
                          signingKey: String(repeating: "ab", count: 32), fingerprint: "fp-me-iphone-aaaaaa")
    }

    func testDeviceSubjectMismatchOnReadIsRegistrationPendingNotHalt() async throws {
        let h = try SyncHarness()
        h.relay.getErrors = [mismatch]

        let pass = try await h.sync.syncOnce()

        XCTAssertTrue(pass.registrationPending)
        XCTAssertNil(pass.halted)
        XCTAssertNil(h.sync.haltedReason)
        XCTAssertEqual(h.sync.registrationPending, expected)
        XCTAssertTrue(try h.messages.rooms().allSatisfy { $0.haltedReason == nil }, "정지 사유로 영속하지 않는다")
        // 새 기기: 등록 JSON 을 만든 그 상태(서명키)가 저장됐다 — 다음 실행에서 같은 키.
        XCTAssertEqual(try h.store.generation(room: h.room), 1)
        XCTAssertNotNil(h.engineState)
    }

    func testEnrollmentJSONUsesRelayAppKeys() throws {
        let json = try expected.json()
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: String])
        XCTAssertEqual(Set(object.keys), ["device_id", "actor", "subject", "signing_key", "fingerprint"])
        XCTAssertEqual(object["device_id"], "me-iphone-aaaaaa")
        XCTAssertEqual(object["signing_key"]?.count, 64)
        XCTAssertEqual(try JSONDecoder().decode(EnrollmentRequest.self, from: Data(json.utf8)), expected)
        XCTAssertEqual(EnrollmentRequest.actor(of: "dad-iphone-0a1b2c"), "dad")
        XCTAssertEqual(EnrollmentRequest.actor(of: "solo"), "solo")
    }

    func testPendingClearsOnceRelayAcceptsTheDevice() async throws {
        let h = try SyncHarness()
        h.relay.inject(device: alice, kind: .commit, bytes: FakeCommit(committer: alice, adds: [h.me]).bytes)
        h.relay.inject(device: alice, kind: .welcome, bytes: FakeWelcome(members: [alice, h.me]).bytes)
        h.relay.members = [alice, h.me]
        h.relay.getErrors = [mismatch, mismatch]

        try await h.sync.syncOnce()
        try await h.sync.syncOnce()
        XCTAssertNotNil(h.sync.registrationPending)
        // 운영자가 등록했다 → 다음 GET 성공.
        let pass = try await h.sync.syncOnce()
        XCTAssertNil(h.sync.registrationPending)
        XCTAssertFalse(pass.registrationPending)
        XCTAssertTrue(pass.joined)
    }

    func testSendWhileUnregisteredSpendsNoRatchet() async throws {
        let h = try SyncHarness()
        h.relay.getErrors = [mismatch]
        do { _ = try await h.sync.send(text: "x"); XCTFail() }
        catch { XCTAssertEqual(error as? SyncError, .registrationPending) }
        XCTAssertEqual(h.factory.log.count(.encrypt), 0)
        XCTAssertTrue(h.relay.posts.isEmpty)
    }

    func testPostMismatchKeepsExactBytesPendingUntilEnrolled() async throws {
        let h = try SyncHarness()
        try h.store.seed(room: h.room, .joined([alice, h.me].sorted(), epoch: 1))
        h.relay.epoch = 1
        h.relay.members = [alice, h.me]
        h.relay.postErrors = [mismatch]

        do { _ = try await h.sync.send(text: "hold"); XCTFail() }
        catch { XCTAssertEqual(error as? SyncError, .registrationPending) }
        XCTAssertEqual(h.sync.registrationPending?.deviceId, h.me)
        let pending = try h.outbox.pending(room: h.room)
        XCTAssertEqual(pending.count, 1)

        // 등록 뒤: 동기화가 대기를 풀고, outbox 는 같은 바이트로 나간다.
        try await h.sync.syncOnce()
        XCTAssertNil(h.sync.registrationPending)
        let outcomes = try await h.sync.flushOutbox()
        XCTAssertEqual(outcomes, [.sent(clientId: pending[0].clientId, seq: 1, duplicate: false)])
        XCTAssertEqual(h.relay.posts.map(\.bytes), [pending[0].bytes, pending[0].bytes])
        XCTAssertEqual(h.factory.log.count(.encrypt), 1)
    }

    func testForegroundLoopKeepsPollingWhileRegistrationPending() async throws {
        let h = try SyncHarness()
        h.relay.getErrors = [mismatch, mismatch, mismatch]
        var cycles = 0
        struct Stop: Error {}
        await h.sync.runForeground(sleep: { _ in
            cycles += 1
            if cycles == 3 { throw Stop() }   // sleep 이 던지면(취소 대역) 루프가 끝난다
        })
        XCTAssertEqual(cycles, 3, "등록 대기는 정지가 아니다 — 폴링을 계속한다")
        XCTAssertEqual(h.relay.getCalls.count, 3)
        XCTAssertNotNil(h.sync.registrationPending)
    }
}
