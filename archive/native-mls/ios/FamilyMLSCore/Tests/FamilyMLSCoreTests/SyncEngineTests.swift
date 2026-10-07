// RoomSyncEngine 테스트 (#276 L3, CONTRACTS.md §2.2·§2.4) — 가짜 엔진·InMemory 스토어·메모리 릴레이(SyncFakes.swift).
// 수용 기준: 수신 순서 · 커서/ack(영속 후 전진) · history_gap 정지 · commit 정책 거부 → discard + 영속 ⛔ ·
// 409 → 새 client_id 재암호화(옛 항목 reconciled) · 정확 바이트 재시도(200 duplicate) · 네트워크는 트랜잭션 밖.
import XCTest
@testable import FamilyMLSCore

final class SyncEngineTests: XCTestCase {
    let alice = "alice-pc"
    let carol = "carol-ipad"

    /// alice 가 방을 만들고(seq1 commit) me 를 Welcome(seq2) 으로 초대한 상태.
    private func invitedHarness() throws -> SyncHarness {
        let h = try SyncHarness()
        h.relay.inject(device: alice, kind: .commit, bytes: FakeCommit(committer: alice, adds: [h.me]).bytes)
        h.relay.inject(device: alice, kind: .welcome, bytes: FakeWelcome(members: [alice, h.me]).bytes)
        h.relay.members = [alice, h.me]
        return h
    }

    /// 이미 참여한(엔진 상태 시드) 기기. relay epoch = 엔진 epoch.
    private func joinedHarness(pending: [String]? = nil) throws -> SyncHarness {
        let h = try SyncHarness()
        try h.store.seed(room: h.room, .joined([alice, h.me].sorted(), epoch: 1, pending: pending))
        h.relay.epoch = 1
        h.relay.members = [alice, h.me]
        return h
    }

    /// 다른 스레드의 신호를 async 문맥에서 기다린다(블로킹 wait 대신 폴링).
    private func waitFor(_ semaphore: DispatchSemaphore, timeout: TimeInterval = 2) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while semaphore.wait(timeout: .now()) == .timedOut {
            guard Date() < deadline else { return XCTFail("신호 대기 시간 초과") }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    // MARK: - 수신 순서

    func testWelcomeJoinsThenDecryptsAndSkipsPreWelcomeEvents() async throws {
        let h = try invitedHarness()
        let appSeq = h.relay.inject(device: alice, kind: .application, bytes: h.ciphertext(from: alice, clientId: alice, text: "안녕"))

        let pass = try await h.sync.syncOnce()

        XCTAssertTrue(pass.joined)
        XCTAssertEqual(pass.inserted, [appSeq])
        XCTAssertEqual(pass.cursor, appSeq)
        // seq1(Welcome 이전 commit)은 stage 하지 않는다 — 내 것이 아니다.
        XCTAssertEqual(h.factory.log.count(.stageCommit), 0)
        XCTAssertEqual(h.factory.log.count(.join), 1)
        let stored = try h.messages.messages(room: h.room, after: 0, limit: 10)
        XCTAssertEqual(stored.map(\.body), ["안녕"])
        XCTAssertEqual(stored.first?.senderDevice, alice)
        XCTAssertEqual(stored.first?.senderActor, "alice")
        XCTAssertEqual(stored.first?.kind, .text)
        // 해독(수신 ratchet)이 상태에 저장됐다.
        XCTAssertEqual(h.engineState?.receiveGeneration, 1)
        XCTAssertEqual(try h.cursors.cursor(room: h.room), appSeq)
    }

    func testWelcomeAfterJoinIsIgnored() async throws {
        let h = try joinedHarness()
        h.relay.inject(device: alice, kind: .welcome, bytes: FakeWelcome(members: [alice, h.me]).bytes)
        let pass = try await h.sync.syncOnce()
        XCTAssertNil(pass.halted)
        XCTAssertEqual(pass.cursor, 1)
        XCTAssertEqual(h.factory.log.count(.join), 0)
    }

    func testOwnCommitEchoMergesPending() async throws {
        let h = try joinedHarness(pending: [alice, carol, "me-iphone-aaaaaa"].sorted())
        h.relay.inject(device: h.me, kind: .commit, bytes: Data("own".utf8))
        let pass = try await h.sync.syncOnce()
        XCTAssertNil(pass.halted)
        XCTAssertEqual(h.factory.log.count(.mergePending), 1)
        XCTAssertEqual(h.factory.log.count(.stageCommit), 0, "내 echo 는 stage 하지 않는다")
        XCTAssertNil(h.engineState?.pending)
        XCTAssertEqual(h.engineState?.members, [alice, carol, h.me].sorted())
    }

    func testOwnApplicationEchoIsSkipped() async throws {
        let h = try joinedHarness()
        h.relay.inject(device: h.me, kind: .application, bytes: Data("mine".utf8))
        let pass = try await h.sync.syncOnce()
        XCTAssertEqual(pass.cursor, 1)
        XCTAssertEqual(h.factory.log.count(.decrypt), 0)
        XCTAssertTrue(h.messages.records.isEmpty)
    }

    func testForeignCommitMergedAfterPolicyPassesWithOuterRoster() async throws {
        let h = try joinedHarness()
        h.relay.inject(device: alice, kind: .commit, bytes: FakeCommit(committer: alice, adds: [carol]).bytes)
        h.relay.members = [alice, carol, h.me]   // 릴레이 추적 roster = 기대 roster
        let pass = try await h.sync.syncOnce()
        XCTAssertNil(pass.halted)
        XCTAssertEqual(h.factory.log.calls.filter { ["stage_commit", "merge_staged", "discard_staged"].contains($0) },
                       ["stage_commit", "merge_staged"])
        XCTAssertEqual(h.engineState?.members, [alice, carol, h.me].sorted())
        XCTAssertEqual(h.engineState?.epoch, 2)
        XCTAssertEqual(try h.messages.rooms().first?.epoch, 2, "RoomRecord 가 릴레이 epoch 로 갱신")
    }

    func testPoisonCommitIsSkippedNotHalted() async throws {
        let h = try joinedHarness()
        let bad = h.relay.inject(device: alice, kind: .commit, bytes: FakeCommit(committer: alice, poison: true).bytes)
        let pass = try await h.sync.syncOnce()
        XCTAssertNil(pass.halted)
        XCTAssertEqual(pass.rejected, [bad])
        XCTAssertEqual(pass.cursor, bad, "엔진 거부(poison)는 보고 후 지나간다(봇 rejected 와 같음)")
    }

    // MARK: - commit 정책 거부 → discard + ⛔ (영속)

    func testPolicyRefusalDiscardsStagedAndHaltsDurably() async throws {
        let h = try joinedHarness()
        let appBefore = h.relay.inject(device: alice, kind: .application, bytes: h.ciphertext(from: alice, clientId: alice, text: "전"))
        // 릴레이 row 는 alice 인데 MLS path leaf 는 carol → committer_mismatch
        h.relay.inject(device: alice, kind: .commit, bytes: FakeCommit(committer: alice, adds: [carol], path: [carol]).bytes)
        h.relay.inject(device: alice, kind: .application, bytes: h.ciphertext(from: alice, clientId: alice, text: "후"))

        let pass = try await h.sync.syncOnce()

        XCTAssertEqual(pass.halted, CommitRefusalReason.committerMismatch.rawValue)
        XCTAssertEqual(h.factory.log.count(.discardStaged), 1)
        XCTAssertEqual(h.factory.log.count(.mergeStaged), 0)
        XCTAssertEqual(h.engineState?.members, [alice, h.me].sorted(), "epoch·roster 유지")
        XCTAssertNil(h.engineState?.staged)
        XCTAssertEqual(pass.cursor, appBefore, "거부된 commit 을 지나가지 않는다")
        XCTAssertEqual(try h.cursors.cursor(room: h.room), appBefore)
        XCTAssertEqual(h.messages.records.map(\.body), ["전"], "정지 뒤 application 은 처리하지 않는다")
        XCTAssertEqual(try h.messages.rooms().first?.haltedReason, "committer_mismatch")

        // 재시작 뒤에도 정지 유지: GET 도, 송신도 하지 않는다.
        let restarted = try h.restart()
        XCTAssertEqual(restarted.haltedReason, "committer_mismatch")
        let gets = h.relay.getCalls.count
        let again = try await restarted.syncOnce()
        XCTAssertEqual(again.halted, "committer_mismatch")
        XCTAssertEqual(h.relay.getCalls.count, gets)
        do { _ = try await restarted.send(text: "x"); XCTFail("정지된 방에서 송신") }
        catch { XCTAssertEqual(error as? SyncError, .halted("committer_mismatch")) }
    }

    func testOuterInnerMismatchHalts() async throws {
        let h = try joinedHarness()
        h.relay.inject(device: alice, kind: .commit, bytes: FakeCommit(committer: alice, adds: [carol]).bytes)
        h.relay.members = [alice, h.me]   // 릴레이는 carol 을 모른다
        let pass = try await h.sync.syncOnce()
        XCTAssertEqual(pass.halted, CommitRefusalReason.outerInnerMismatch.rawValue)
        XCTAssertEqual(h.factory.log.count(.discardStaged), 1)
    }

    func testOlderEpochCommitChecksInnerOnly() async throws {
        let h = try joinedHarness()
        h.relay.inject(device: alice, kind: .commit, bytes: FakeCommit(committer: alice, adds: [carol]).bytes)
        h.relay.inject(device: alice, kind: .commit, bytes: FakeCommit(committer: alice, removes: [carol]).bytes)
        // 페이지 epoch = 3: 첫 commit(epoch 1)은 최신이 아니라 outer 를 비교하지 않는다. 두 번째(epoch 2)만 outer 비교.
        h.relay.members = [alice, h.me]
        let pass = try await h.sync.syncOnce()
        XCTAssertNil(pass.halted)
        XCTAssertEqual(h.factory.log.count(.mergeStaged), 2)
        XCTAssertEqual(h.engineState?.members, [alice, h.me].sorted())
    }

    func testUnparseableStageReportHaltsReportFormat() async throws {
        let h = try joinedHarness()
        h.relay.inject(device: alice, kind: .commit, bytes: FakeCommit(committer: alice, badReport: true).bytes)
        let pass = try await h.sync.syncOnce()
        XCTAssertEqual(pass.halted, SyncHaltReason.reportFormat)
        XCTAssertEqual(h.factory.log.count(.discardStaged), 1)
    }

    func testCommitRemovingMeHaltsRemovedFromRoom() async throws {
        let h = try joinedHarness()
        let seq = h.relay.inject(device: alice, kind: .commit, bytes: FakeCommit(committer: alice, removes: [h.me]).bytes)
        h.relay.members = nil   // 제거된 기기에게 릴레이는 roster 를 주지 않는다(#289)
        let pass = try await h.sync.syncOnce()
        XCTAssertEqual(pass.halted, SyncHaltReason.removedFromRoom)
        XCTAssertEqual(h.factory.log.count(.mergeStaged), 1, "검증된 제거는 merge 한다")
        XCTAssertEqual(pass.cursor, seq)
    }

    // MARK: - 해독 불가

    func testUndecryptableApplicationIsRecordedAndSkipped() async throws {
        let h = try joinedHarness()
        let bad = h.relay.inject(device: alice, kind: .application, bytes: Data("garbage".utf8))
        let good = h.relay.inject(device: alice, kind: .application, bytes: h.ciphertext(from: alice, clientId: alice, text: "ok"))
        let spoof = h.relay.inject(device: alice, kind: .application, bytes: h.ciphertext(from: carol, clientId: carol, text: "가짜"))
        let pass = try await h.sync.syncOnce()
        XCTAssertEqual(pass.rejected, [bad, spoof])
        XCTAssertEqual(pass.inserted, [good])
        XCTAssertEqual(pass.cursor, spoof)
        let kinds = h.messages.records.map { "\($0.seq):\($0.kind.rawValue):\($0.body)" }
        XCTAssertEqual(kinds, ["\(bad):undecryptable:undecryptable", "\(good):text:ok", "\(spoof):undecryptable:sender_mismatch"])
    }

    // MARK: - 커서 / ack

    func testCursorAckedOnNextGetOnlyAfterPersistAndNotResent() async throws {
        let h = try invitedHarness()
        let seq3 = h.relay.inject(device: alice, kind: .application, bytes: h.ciphertext(from: alice, clientId: alice, text: "1"))
        try await h.sync.syncOnce()
        try await h.sync.syncOnce()
        try await h.sync.syncOnce()
        XCTAssertEqual(h.relay.getCalls.map(\.after), [0, seq3, seq3])
        XCTAssertEqual(h.relay.getCalls.map(\.ack), [nil, seq3, nil], "참여 전 ack 없음 → 영속 커서 ack → 같은 값 재전송 안 함")
    }

    func testCursorNotAdvancedWhenStateSaveFails() async throws {
        let h = try joinedHarness()
        h.relay.inject(device: alice, kind: .application, bytes: h.ciphertext(from: alice, clientId: alice, text: "x"))
        // 다른 프로세스가 잠금을 쥔 상태 → lockTimeout: 아무것도 영속되지 않았으니 커서도 그대로.
        h.configuration.lockTimeout = 0.05
        let sync = try h.restart()
        let acquired = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0), done = DispatchSemaphore(value: 0)
        Thread {
            try? h.store.inner.withExclusive(room: h.room, timeout: 1) { _ in acquired.signal(); release.wait() }
            done.signal()
        }.start()
        try await waitFor(acquired)
        do { try await sync.syncOnce(); XCTFail("잠금 타임아웃이어야 한다") }
        catch { XCTAssertEqual(error as? StateStoreError, .lockTimeout(h.room)) }
        XCTAssertEqual(try h.cursors.cursor(room: h.room), 0)
        XCTAssertTrue(h.messages.records.isEmpty)
        release.signal()
        try await waitFor(done)
        let pass = try await sync.syncOnce()
        XCTAssertEqual(pass.inserted, [1], "잠금이 풀리면 같은 seq 를 처음부터 처리")
    }

    func testAckRefusalDisablesAckButKeepsSyncing() async throws {
        let h = try invitedHarness()
        try await h.sync.syncOnce()
        h.relay.inject(device: alice, kind: .application, bytes: h.ciphertext(from: alice, clientId: alice, text: "1"))
        h.relay.getErrors = [.refused(code: "bad_ack", status: 400)]
        let refused = try await h.sync.syncOnce()
        XCTAssertNil(refused.halted)
        let pass = try await h.sync.syncOnce()
        XCTAssertEqual(pass.inserted.count, 1)
        XCTAssertEqual(h.relay.getCalls.last?.ack, nil, "ack 를 끈 뒤로는 보내지 않는다")
    }

    func testMissingRoomIsNotAnError() async throws {
        let h = try SyncHarness()
        h.relay.getErrors = [.refused(code: "no_such_room", status: 404)]
        let pass = try await h.sync.syncOnce()
        XCTAssertNil(pass.halted)
        XCTAssertFalse(pass.joined)
    }

    func testRoomClosedHalts() async throws {
        let h = try joinedHarness()
        h.relay.getErrors = [.refused(code: "room_closed", status: 410)]
        let pass = try await h.sync.syncOnce()
        XCTAssertEqual(pass.halted, SyncHaltReason.roomClosed)
        XCTAssertEqual(try h.messages.rooms().first?.haltedReason, "room_closed")
    }

    func testPagingFollowsUntilShortPage() async throws {
        let h = try joinedHarness()
        h.configuration.pageLimit = 2
        let sync = try h.restart()
        for i in 1...5 { h.relay.inject(device: alice, kind: .application, bytes: h.ciphertext(from: alice, clientId: alice, text: "\(i)")) }
        let passes = try await sync.syncAll()
        XCTAssertEqual(passes.map(\.fetched), [2, 2, 1])
        XCTAssertEqual(h.messages.records.map(\.body), ["1", "2", "3", "4", "5"])
        XCTAssertEqual(try h.cursors.cursor(room: h.room), 5)
    }

    // MARK: - history_gap

    func testHistoryGapHaltsBeforeProcessingAnything() async throws {
        let h = try joinedHarness()
        try h.cursors.setCursor(room: h.room, seq: 3)
        for i in 1...6 { h.relay.inject(device: alice, kind: .application, bytes: h.ciphertext(from: alice, clientId: alice, text: "\(i)")) }
        h.relay.firstSeq = 6   // 4·5 는 지워졌다
        let pass = try await h.sync.syncOnce()
        XCTAssertEqual(pass.halted, SyncHaltReason.historyGap)
        XCTAssertEqual(h.factory.log.count(.decrypt), 0)
        XCTAssertEqual(try h.cursors.cursor(room: h.room), 3)
        XCTAssertEqual(try h.messages.rooms().first?.haltedReason, "history_gap")
    }

    func testNoHistoryGapBeforeJoin() async throws {
        let h = try invitedHarness()
        h.relay.firstSeq = 2   // 참여 전 기기에겐 이전 이력이 원래 없다
        let pass = try await h.sync.syncOnce()
        XCTAssertNil(pass.halted)
        XCTAssertTrue(pass.joined)
    }

    // MARK: - 송신

    func testSendPersistsStateBeforePostAndPostsExactOutboxBytes() async throws {
        let h = try joinedHarness()
        var generationAtPost: Int?
        h.relay.onPost = { [unowned h] _ in generationAtPost = h.engineState?.sendGeneration }

        let outcome = try await h.sync.send(text: "hello")

        guard case .sent(let clientId, let seq, false) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(generationAtPost, 1, "송신 ratchet 이 POST 전에 저장됐다")
        XCTAssertEqual(h.relay.posts.count, 1)
        XCTAssertEqual(h.relay.posts[0].clientId, clientId)
        XCTAssertEqual(h.relay.posts[0].epoch, 1)
        XCTAssertEqual(h.relay.rows.first { $0.seq == seq }?.bytes, h.relay.posts[0].bytes)
        XCTAssertTrue(try h.outbox.pending(room: h.room).isEmpty)
    }

    func testSendBeforeJoinThrowsNotJoinedAndLeavesNothing() async throws {
        let h = try SyncHarness()
        do { _ = try await h.sync.send(text: "x"); XCTFail("참여 전 송신") }
        catch { XCTAssertEqual(error as? SyncError, .notJoined) }
        XCTAssertTrue(h.relay.posts.isEmpty)
        XCTAssertTrue(try h.outbox.pending(room: h.room).isEmpty)
    }

    func testCasMismatchReconcilesOldEntryAndReencryptsWithNewClientId() async throws {
        let h = try joinedHarness(pending: [alice, carol, "me-iphone-aaaaaa"].sorted())
        // 송신 전 동기화와 내 POST 사이에 alice 가 carol 을 추가 → 릴레이 epoch 2. 내 POST(epoch 1)는 409.
        h.relay.onPost = { [unowned h, alice, carol] _ in
            guard h.relay.posts.count == 1 else { return }
            h.relay.inject(device: alice, kind: .commit, bytes: FakeCommit(committer: alice, adds: [carol]).bytes)
            h.relay.members = [alice, carol, h.me]
        }

        let outcome = try await h.sync.send(text: "hi")

        XCTAssertEqual(h.relay.posts.count, 2)
        let (first, second) = (h.relay.posts[0], h.relay.posts[1])
        XCTAssertNotEqual(first.clientId, second.clientId, "새 client_id")
        XCTAssertNotEqual(first.bytes, second.bytes, "재암호화(같은 바이트 재사용 아님)")
        XCTAssertEqual(first.epoch, 1)
        XCTAssertEqual(second.epoch, 2)
        XCTAssertEqual(outcome, .sent(clientId: second.clientId, seq: 2, duplicate: false))
        XCTAssertEqual(h.factory.log.count(.clearPending), 1, "대기 commit 은 409 에서 버린다")
        XCTAssertEqual(h.factory.log.count(.mergeStaged), 1, "재암호화 전에 동기화로 새 epoch 를 적용")
        let clear = h.factory.log.calls.firstIndex(of: "clear_pending")!
        let stage = h.factory.log.calls.firstIndex(of: "stage_commit")!
        let encrypts = h.factory.log.calls.indices.filter { h.factory.log.calls[$0] == "encrypt" }
        XCTAssertTrue(encrypts[0] < clear && clear < stage && stage < encrypts[1], "\(h.factory.log.calls)")
        XCTAssertTrue(try h.outbox.pending(room: h.room).isEmpty, "옛 항목 reconciled · 새 항목 sent")
    }

    func testSecondCasMismatchGivesUp() async throws {
        let h = try joinedHarness()
        h.relay.postErrors = [.cas(epoch: 1, revision: 0), .cas(epoch: 1, revision: 0)]
        do { _ = try await h.sync.send(text: "x"); XCTFail() }
        catch { XCTAssertEqual(error as? SyncError, .casRetryExhausted) }
        XCTAssertEqual(h.relay.posts.count, 2)
        XCTAssertTrue(try h.outbox.pending(room: h.room).isEmpty, "두 항목 모두 reconciled")
    }

    func testLostResponseRetriesExactBytesAndGetsDuplicate() async throws {
        let h = try joinedHarness()
        h.relay.dropNextPostResponse = true

        let first = try await h.sync.send(text: "once")
        guard case .queued(let clientId) = first else { return XCTFail("\(first)") }
        XCTAssertEqual(try h.outbox.pending(room: h.room).map(\.clientId), [clientId])

        // 재시작 뒤에도 outbox 는 같은 바이트를 들고 있다.
        let restarted = try h.restart()
        let outcomes = try await restarted.flushOutbox()

        XCTAssertEqual(outcomes, [.sent(clientId: clientId, seq: 1, duplicate: true)])
        XCTAssertEqual(h.relay.posts.count, 2)
        XCTAssertEqual(h.relay.posts[0].bytes, h.relay.posts[1].bytes, "정확 바이트 재시도")
        XCTAssertEqual(h.relay.posts[0].clientId, h.relay.posts[1].clientId)
        XCTAssertEqual(h.relay.rows.count, 1, "릴레이에 한 번만 저장")
        XCTAssertEqual(h.factory.log.count(.encrypt), 1, "재시도는 재암호화하지 않는다")
        XCTAssertTrue(try h.outbox.pending(room: h.room).isEmpty)
    }

    func testFlushOutboxReconcilesStaleEntryWithoutPlaintext() async throws {
        let h = try joinedHarness()
        h.relay.postErrors = [.network("offline")]
        guard case .queued(let clientId) = try await h.sync.send(text: "stale") else { return XCTFail() }
        h.relay.inject(device: alice, kind: .commit, bytes: FakeCommit(committer: alice, adds: [carol]).bytes)
        let outcomes = try await h.sync.flushOutbox()
        XCTAssertEqual(outcomes, [.reconciled(clientId: clientId)])
        XCTAssertTrue(try h.outbox.pending(room: h.room).isEmpty)
    }

    // MARK: - 네트워크는 트랜잭션 밖

    func testRelayGuardDetectsCallsInsideTransaction() throws {
        // 음성 대조: 가드가 실제로 잡는다는 것.
        let h = try SyncHarness()
        try h.store.withExclusive(room: h.room, timeout: 1) { _ in h.relay.check("probe") }
        XCTAssertEqual(h.relay.violations, ["probe"])
    }

    func testNoRelayCallHappensInsideATransaction() async throws {
        let h = try invitedHarness()
        h.relay.inject(device: alice, kind: .application, bytes: h.ciphertext(from: alice, clientId: alice, text: "1"))
        try await h.sync.syncAll()
        _ = try await h.sync.send(text: "a")
        var raced = false
        h.relay.onPost = { [unowned h, alice, carol] _ in
            guard !raced else { return }
            raced = true
            h.relay.inject(device: alice, kind: .commit, bytes: FakeCommit(committer: alice, adds: [carol]).bytes)
            h.relay.members = [alice, carol, h.me]
        }
        _ = try await h.sync.send(text: "b")          // 409 → 동기화 → 재암호화 경로
        XCTAssertTrue(raced)
        h.relay.dropNextPostResponse = true
        _ = try await h.sync.send(text: "c")
        try await h.sync.flushOutbox()
        try await h.sync.syncAll()

        XCTAssertGreaterThan(h.store.transactions, 5)
        XCTAssertGreaterThan(h.relay.getCalls.count + h.relay.posts.count, 5)
        XCTAssertEqual(h.relay.violations, [], "릴레이 호출이 withExclusive 안에서 일어났다")
    }

    // MARK: - 엔진 캐시 / 다른 작성자

    func testOtherWriterBetweenPassesForcesReimport() async throws {
        let h = try joinedHarness()
        try await h.sync.syncOnce()
        let imports = h.factory.log.imports
        try await h.sync.syncOnce()
        XCTAssertEqual(h.factory.log.imports, imports, "generation 이 같으면 캐시 엔진 재사용")
        // NSE 가 사이에 저장(같은 방, 다른 프로세스 대역) → generation 변경 → 다시 import.
        var state = try XCTUnwrap(h.engineState)
        state.receiveGeneration += 10
        try h.store.seed(room: h.room, state)
        try await h.sync.syncOnce()
        XCTAssertEqual(h.factory.log.imports, imports + 1)
    }

    // MARK: - 전면 폴링

    func testForegroundLoopSyncsFlushesAndStopsWhenHalted() async throws {
        let h = try joinedHarness()
        h.relay.postErrors = [.network("offline")]
        _ = try await h.sync.send(text: "later")
        var sleeps: [TimeInterval] = []
        await h.sync.runForeground(sleep: { [unowned h] interval in
            sleeps.append(interval)
            if sleeps.count == 2 {
                h.relay.inject(device: self.alice, kind: .commit, bytes: FakeCommit(committer: self.alice, path: []).bytes)
            }
        })
        XCTAssertEqual(sleeps, [4, 4], "4초 주기")
        XCTAssertEqual(h.sync.haltedReason, CommitRefusalReason.committerPath.rawValue)
        XCTAssertTrue(try h.outbox.pending(room: h.room).isEmpty, "첫 주기에 outbox 를 비웠다")
    }
}

// 실 엔진 결합에서 드러난 결함(파이널라이저 통합, #271): AAD client_id 와 릴레이 client_id 는 다른 값이다.
extension SyncEngineTests {
    func testSendFramesDeviceIdAsAADClientIdAndUniqueRelayClientId() async throws {
        let h = try joinedHarness()
        let outcome = try await h.sync.send(text: "hello")
        guard case .sent(let relayClientId, _, false) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertNotEqual(relayClientId, h.me, "릴레이 dedup 키는 기기 ID 와 달라야 한다(메시지마다 고유)")
        // 가짜 암호문 = magic ‖ (sender ‖ AAD client_id ‖ plaintext) ‖ generation
        let framed = h.relay.posts[0].bytes.dropFirst(FakeMlsEngine.ciphertextMagic.count)
        var at = 0
        XCTAssertEqual(try Framing.readString(Data(framed), &at), h.me)
        XCTAssertEqual(try Framing.readString(Data(framed), &at), h.me, "AAD client_id = 기기 ID(파사드 H1)")
    }

    func testForeignAADClientIdIsUndecryptable() async throws {
        let h = try joinedHarness()
        let seq = h.relay.inject(device: alice, kind: .application, bytes: h.ciphertext(from: alice, clientId: "\(alice)-relay-1", text: "x"))
        let pass = try await h.sync.syncOnce()
        XCTAssertEqual(pass.rejected, [seq])
        XCTAssertEqual(try h.messages.messages(room: h.room, after: 0, limit: 10).first?.body, "sender attribution rejected")
    }
}
