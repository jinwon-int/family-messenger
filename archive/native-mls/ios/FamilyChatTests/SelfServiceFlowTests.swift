// 새 기기 셀프서비스(#574 PR 3) — AppModel 쪽: 등록 대기 바퀴의 후보 게시·재게시·모드, 우편함 발견과 서명 자격, 지문 비교 승인(stale 재서명 ·
// 불일치 거부), 등록 기기 역할(E5), 형제 기기 초대 대기열(재시도·30분 포기), 형제가 보낸 로비 Welcome 의 자동 수락, /v2/me 주기.
// 가짜 엔진(FakeEngine: policy_fingerprint = 고정 지문, sign_* = 프레임)과 메모리 릴레이(InMemoryRelay 의 기기 셀프서비스 대역) — xcframework 불필요,
// Linux 스모크(scripts/linux-smoke.sh)에도 복사된다. 실 엔진의 초대 성공은 TwoDeviceScenario 가 다룬다(여기서는 키 패키지 없음 → 재시도 경로).
import XCTest
import FamilyMLSCore
@testable import FamilyChat

@MainActor
final class SelfServiceFlowTests: XCTestCase {
    private let fp = String(repeating: "f", count: 64)

    /// `now` 를 테스트가 돌린다(후보 재게시 여유 5분 · 대기열 TTL 30분). 릴레이의 시계도 같은 값.
    private final class Clock { var now = Date(timeIntervalSince1970: 1_700_000_000) }

    private func makeModel(actor: String = "owner", relay: RelayTransport, inner: InMemoryRelay, clock: Clock, factory: MlsEngineFactory = FakeFactory(),
                           rooms: [RoomRecord] = [], queue: SiblingQueueStoring = InMemorySiblingQueueStore(), meEveryRounds: Int = 4) -> AppModel {
        var deps = AppModel.Dependencies(
            engineFactory: factory, stateStore: InMemoryStateStore(), messageStore: InMemoryMessageStore(seedRooms: rooms),
            outbox: InMemoryOutboxStore(), cursors: InMemoryCursorStore(),
            identityProvider: { "\(actor)-iphone-abc123" }, expectedDecryptFormat: { 2 }, makeTransport: { _ in relay })
        deps.actorStore = InMemoryActorStore(actor)
        deps.clock = { clock.now }
        deps.siblingQueue = queue
        deps.meEveryRounds = meEveryRounds
        inner.now = { clock.now }
        return AppModel(dependencies: deps)
    }

    // MARK: - 등록 대기(403): 후보 게시

    /// 403 device_subject_mismatch 바퀴: 후보를 올리고(모드 sibling, 만료 10분) 만료 5분 전까지는 다시 올리지 않는다.
    func testEnrollmentPostsCandidateAndRepostsBeforeExpiry() async throws {
        let clock = Clock()
        let relay = RefusingRelay(RelayError.refused(code: "device_subject_mismatch", status: 403))
        relay.inner.seedDevice("owner-web-a")   // 이 계정에 활성 기기가 있어야 셀프서비스(아니면 first_device_out_of_band)
        let model = makeModel(relay: relay, inner: relay.inner, clock: clock)
        await model.bootstrap(); model.login(.bearer("t"))
        await model.refresh()
        XCTAssertEqual(model.phase, .needsEnrollment)
        XCTAssertEqual(model.enrollment.mode, .sibling)
        XCTAssertEqual(model.enrollment.expiresAt, clock.now.addingTimeInterval(600))
        XCTAssertEqual(relay.inner.candidatePosts, 1)
        XCTAssertEqual(relay.inner.candidateIds(), [model.deviceId])
        XCTAssertEqual(model.me?.devices?.map(\.deviceId), ["owner-web-a"], "the enrollment tick reads /v2/me every round")
        await model.refresh()
        clock.now = clock.now.addingTimeInterval(4 * 60)
        await model.refresh()
        XCTAssertEqual(relay.inner.candidatePosts, 1, "not before expiry − 5 min")
        clock.now = clock.now.addingTimeInterval(2 * 60)   // 6분 경과 = 만료 4분 전
        await model.refresh()
        XCTAssertEqual(relay.inner.candidatePosts, 2, "re-posted ~5 min before the 10-min TTL")
        XCTAssertEqual(model.enrollment.expiresAt, clock.now.addingTimeInterval(600))
        XCTAssertNil(model.lastError)
    }

    /// 404(옛 릴레이·접근 인증 꺼짐) → 운영자 흐름, 이 세션에서는 다시 묻지 않는다. 다시 로그인하면 다시 묻는다.
    func testEnrollmentOnOldRelayStaysOperatorFlow() async throws {
        let clock = Clock()
        let relay = RefusingRelay(RelayError.refused(code: "device_subject_mismatch", status: 403))
        relay.inner.deviceStore = false
        let model = makeModel(relay: relay, inner: relay.inner, clock: clock)
        await model.bootstrap(); model.login(.bearer("t"))
        await model.refresh()
        XCTAssertEqual(model.phase, .needsEnrollment)
        XCTAssertEqual(model.enrollment.mode, .operatorFlow)
        XCTAssertNil(model.enrollment.expiresAt)
        XCTAssertEqual(model.me, MeResponse(subject: "sub-test"), "an old relay answers subject only")
        clock.now = clock.now.addingTimeInterval(60 * 60)
        await model.refresh(); await model.refresh()
        XCTAssertEqual(relay.inner.candidatePosts, 1, "404 = no self-service; off for the session")
        XCTAssertNil(model.lastError, "operator flow is not an error")
        model.login(.bearer("t2"))
        await model.refresh()
        XCTAssertEqual(relay.inner.candidatePosts, 2)
    }

    /// 403 first_device_out_of_band(이 계정의 첫 기기) → 운영자 흐름이되 5분마다 다시 묻는다(그사이 형제 기기가 등록됐을 수 있다).
    func testEnrollmentFirstDeviceIsOperatorFlowAndRechecks() async throws {
        let clock = Clock()
        let relay = RefusingRelay(RelayError.refused(code: "device_subject_mismatch", status: 403))
        let model = makeModel(relay: relay, inner: relay.inner, clock: clock)
        await model.bootstrap(); model.login(.bearer("t"))
        await model.refresh()
        XCTAssertEqual(model.enrollment.mode, .operatorFlow)
        XCTAssertEqual(relay.inner.candidatePosts, 1)
        XCTAssertNil(model.lastError)
        await model.refresh()
        XCTAssertEqual(relay.inner.candidatePosts, 1)
        clock.now = clock.now.addingTimeInterval(5 * 60 + 1)
        relay.inner.seedDevice("owner-web-a")   // 그사이 운영자가 다른 기기를 올렸다
        await model.refresh()
        XCTAssertEqual(relay.inner.candidatePosts, 2)
        XCTAssertEqual(model.enrollment.mode, .sibling)
    }

    /// 409 device_exists → 이 ID 는 다시 쓸 수 없다(idTaken), 다시 올리지 않는다.
    func testEnrollmentIdTakenStopsPosting() async throws {
        let clock = Clock()
        let relay = RefusingRelay(RelayError.refused(code: "device_subject_mismatch", status: 403))
        relay.inner.seedDevice("owner-iphone-abc123", status: "revoked")   // 지운 기기의 옛 ID
        relay.inner.seedDevice("owner-web-a")
        let model = makeModel(relay: relay, inner: relay.inner, clock: clock)
        await model.bootstrap(); model.login(.bearer("t"))
        await model.refresh()
        XCTAssertEqual(model.enrollment.mode, .idTaken)
        clock.now = clock.now.addingTimeInterval(60 * 60)
        await model.refresh()
        XCTAssertEqual(relay.inner.candidatePosts, 1)
    }

    // MARK: - 우편함 · 승인(E2)

    /// 승인할 수 있는 기기(활성, actor 에 registrar 없음)의 바퀴: 우편함의 내 actor 후보가 `candidates` 에 오른다; 다른 actor 는 빠진다; 「무시」는 세션 동안.
    func testCandidatesAreDiscoveredForMyActorOnly() async throws {
        let clock = Clock()
        let relay = InMemoryRelay()
        relay.seedDevice("owner-iphone-abc123")
        let model = makeModel(relay: relay, inner: relay, clock: clock)
        await model.bootstrap(); model.login(.bearer("t"))
        await model.refresh()
        XCTAssertEqual(model.phase, .ready)
        XCTAssertTrue(model.candidates.isEmpty)
        let key = String(repeating: "ab", count: 32)
        _ = try await relay.postDeviceCandidate(DeviceCandidatePost(deviceId: "owner-pc-9", actor: "owner", signingKey: key, fingerprint: fp))
        _ = try await relay.postDeviceCandidate(DeviceCandidatePost(deviceId: "mom-pc-1", actor: "mom", signingKey: key, fingerprint: fp))
        await model.refresh()
        XCTAssertEqual(model.candidates.map(\.deviceId), ["owner-pc-9"], "same actor only")
        XCTAssertEqual(model.notificationCount, 1)
        model.dismissCandidate("owner-pc-9")
        XCTAssertTrue(model.candidates.isEmpty)
        await model.refresh()
        XCTAssertTrue(model.candidates.isEmpty, "dismissed for this session")
        XCTAssertTrue(model.diagnosticsReport().contains("candidate: owner-pc-9 asks for approval"), model.diagnosticsReport())
    }

    /// actor 에 registrar 가 있는데 내가 아니면 우편함을 묻지도 않는다(서명해도 거부된다).
    func testNonRegistrarDoesNotReadTheMailboxWhenTheActorHasARegistrar() async throws {
        let clock = Clock()
        let relay = InMemoryRelay()
        relay.seedDevice("owner-iphone-abc123")
        relay.seedDevice("owner-web-a", roles: ["registrar"])
        let model = makeModel(relay: relay, inner: relay, clock: clock)
        await model.bootstrap(); model.login(.bearer("t"))
        await model.refresh(); await model.refresh()
        XCTAssertEqual(model.phase, .ready)
        XCTAssertFalse(model.deviceRoles.canSign)
        XCTAssertEqual(relay.candidateLists, 0)
        XCTAssertTrue(model.candidates.isEmpty)
    }

    /// 승인: 지문은 이 기기에서 다시 계산한 값(릴레이 값과 같다) → sign_approval → POST → 체인에 활성 기기 추가, /v2/me 갱신, 형제 초대 대기열에
    /// 내가 참여한 방(MemberFakeEngine: roster = 나)이 오른다. 새 기기가 로비 키를 아직 올리지 않았으니(noKeyPackage) 바퀴마다 다시 시도하고,
    /// 30분이 지나면 🔔 에 알리고 버린다.
    func testApproveCandidateSignsPostsAndQueuesSiblingInvitesUntilGivingUp() async throws {
        let clock = Clock()
        let relay = InMemoryRelay()
        relay.seedDevice("owner-iphone-abc123")
        let queue = InMemorySiblingQueueStore()
        let model = makeModel(relay: relay, inner: relay, clock: clock, factory: MemberFakeFactory(), queue: queue)
        await model.bootstrap(); model.login(.bearer("t"))
        await model.refresh()
        XCTAssertEqual(model.phase, .ready)
        // 참여 요청으로 방 상태를 만든다(MemberFakeEngine: roster = 나 → 참여한 방). 기록만 시드하면 MLS 상태가 없어 「참여 안 함」이다.
        try await model.requestJoin(room: "family")
        XCTAssertEqual(model.rooms.map(\.room), ["family"])
        let key = String(repeating: "ab", count: 32)
        _ = try await relay.postDeviceCandidate(DeviceCandidatePost(deviceId: "owner-pc-9", actor: "owner", signingKey: key, fingerprint: fp))
        await model.refresh()
        XCTAssertEqual(model.candidates.map(\.deviceId), ["owner-pc-9"])
        XCTAssertEqual(try model.candidateFingerprint("owner-pc-9"), fp, "recomputed locally from the signing key")

        let commit = try await model.approveCandidate("owner-pc-9")
        XCTAssertEqual(commit, DevicePolicyCommit(deviceId: "owner-pc-9", approvedBy: model.deviceId, revision: 2))
        XCTAssertEqual(relay.approvalPosts.count, 1)
        let evidence = try XCTUnwrap(relay.approvalPosts.first)
        XCTAssertEqual(evidence.baseRevision, 1, "signed against the mailbox's policy_revision")
        XCTAssertEqual(evidence.signingKey, key); XCTAssertEqual(evidence.fingerprint, fp); XCTAssertEqual(evidence.subject, "sub-test")
        XCTAssertEqual(evidence.signature, String(repeating: "5a", count: 64), "the frame's last 64 bytes, hex (FakePolicyWire)")
        XCTAssertEqual(evidence.approvedBy, model.deviceId)
        XCTAssertEqual(relay.policyDevice("owner-pc-9")?.status, "active")
        XCTAssertTrue(model.candidates.isEmpty)
        XCTAssertEqual(relay.candidateIds(), [], "the mailbox row is dropped")
        XCTAssertEqual(model.me?.policyRevision, 2, "/v2/me re-read right after the commit")
        XCTAssertEqual(model.notice, Strings.candidateApproved("owner-pc-9"))
        XCTAssertEqual(queue.load(device: model.deviceId).entries.map(\.rooms), [["family"]], "rooms I am in (and the sibling is not) are queued")

        // 바퀴: 새 기기의 키 패키지가 없다 → 남겨 두고 다음에. 포기 알림은 없다.
        await model.refresh()
        XCTAssertEqual(queue.load(device: model.deviceId).entries.map(\.target), ["owner-pc-9"])
        XCTAssertTrue(model.siblingNotes.isEmpty)
        clock.now = clock.now.addingTimeInterval(SelfService.siblingInviteTTL + 1)
        await model.refresh()
        XCTAssertTrue(queue.load(device: model.deviceId).isEmpty, "given up after the TTL")
        XCTAssertEqual(model.siblingNotes.map(\.id), ["sibling-expired:owner-pc-9"])
        XCTAssertEqual(model.siblingNotes.first?.text, Strings.siblingGaveUp("owner-pc-9", ["family"]))
        XCTAssertEqual(model.notificationCount, 1)
        model.dismissSiblingNote("sibling-expired:owner-pc-9")
        XCTAssertEqual(model.notificationCount, 0)
        let report = model.diagnosticsReport()
        XCTAssertTrue(report.contains("sibling owner-pc-9: invite queue family"), report)
        XCTAssertTrue(report.contains("sibling owner-pc-9: gave up after 30 min"), report)
        XCTAssertFalse(report.contains(key), "no key material in the report")
    }

    /// 체인이 그사이 움직였다(409 stale_revision): 릴레이가 준 revision 으로 한 번 다시 서명한다.
    func testStaleRevisionIsResignedOnce() async throws {
        let clock = Clock()
        let relay = InMemoryRelay()
        relay.seedDevice("owner-iphone-abc123")
        let model = makeModel(relay: relay, inner: relay, clock: clock)
        await model.bootstrap(); model.login(.bearer("t"))
        await model.refresh()
        let key = String(repeating: "ab", count: 32)
        _ = try await relay.postDeviceCandidate(DeviceCandidatePost(deviceId: "owner-pc-9", actor: "owner", signingKey: key, fingerprint: fp))
        await model.refresh()
        relay.bumpPolicyRevision()   // CLI 가 먼저 commit 했다
        let commit = try await model.approveCandidate("owner-pc-9")
        XCTAssertEqual(commit.revision, 3)
        XCTAssertEqual(relay.approvalPosts.map(\.baseRevision), [1, 2], "first with the stale base, then once with the relay's current revision")
        XCTAssertTrue(model.diagnosticsReport().contains("stale revision 1 → 2 — re-signing"), model.diagnosticsReport())
    }

    /// 릴레이가 전한 지문이 공개키에서 계산한 값과 다르면 비교 단계에서 거부한다 — 서명도 POST 도 없다.
    func testFingerprintMismatchRefusesApproval() async throws {
        let clock = Clock()
        let relay = InMemoryRelay()
        relay.seedDevice("owner-iphone-abc123")
        let model = makeModel(relay: relay, inner: relay, clock: clock)
        await model.bootstrap(); model.login(.bearer("t"))
        await model.refresh()
        let key = String(repeating: "ab", count: 32)
        _ = try await relay.postDeviceCandidate(DeviceCandidatePost(deviceId: "owner-pc-9", actor: "owner", signingKey: key, fingerprint: String(repeating: "e", count: 64)))
        await model.refresh()
        XCTAssertEqual(model.candidates.count, 1)
        XCTAssertThrowsError(try model.candidateFingerprint("owner-pc-9")) { XCTAssertEqual($0 as? AppModel.SelfServiceError, .fingerprintMismatch) }
        do {
            try await model.approveCandidate("owner-pc-9")
            XCTFail("must refuse")
        } catch AppModel.SelfServiceError.fingerprintMismatch {
            // expected
        }
        XCTAssertTrue(relay.approvalPosts.isEmpty)
        XCTAssertNil(relay.policyDevice("owner-pc-9"))
        XCTAssertEqual(model.candidates.count, 1, "the candidate stays (the person may ignore it)")
    }

    /// 릴레이가 서명자 규칙으로 거부하면(approval_rejected) 사유가 실린 DevicePolicyRefusal 로 끝난다.
    func testApprovalRejectedCarriesTheDetail() async throws {
        let clock = Clock()
        let relay = InMemoryRelay()
        relay.seedDevice("owner-iphone-abc123")
        let model = makeModel(relay: relay, inner: relay, clock: clock)
        await model.bootstrap(); model.login(.bearer("t"))
        await model.refresh()
        let key = String(repeating: "ab", count: 32)
        _ = try await relay.postDeviceCandidate(DeviceCandidatePost(deviceId: "owner-pc-9", actor: "owner", signingKey: key, fingerprint: fp))
        await model.refresh()
        relay.seedDevice("owner-web-a", roles: ["registrar"])   // 목록을 읽은 뒤 registrar 가 생겼다(me 는 아직 옛 것)
        do {
            try await model.approveCandidate("owner-pc-9")
            XCTFail("must be rejected")
        } catch let refusal as DevicePolicyRefusal {
            XCTAssertEqual(refusal.code, "approval_rejected")
            XCTAssertEqual(refusal.detail, "approver is not a registrar")
        }
    }

    // MARK: - 등록 기기 역할(E5)

    /// registrar 없는 actor: 활성 기기가 자기에게 부여(부트스트랩) → 마지막 registrar 라 해제 불가 → 형제에 부여 뒤 자기 해제.
    func testRegistrarGrantAndReleaseFollowTheLastRegistrarRule() async throws {
        let clock = Clock()
        let relay = InMemoryRelay()
        relay.seedDevice("owner-iphone-abc123")
        relay.seedDevice("owner-web-a")
        let model = makeModel(relay: relay, inner: relay, clock: clock)
        await model.bootstrap(); model.login(.bearer("t"))
        await model.refresh()
        var rows = Dictionary(uniqueKeysWithValues: model.deviceRoles.devices.map { ($0.deviceId, $0) })
        XCTAssertTrue(model.deviceRoles.canSign)
        XCTAssertEqual([rows[model.deviceId]?.grant, rows[model.deviceId]?.isSelf, rows["owner-web-a"]?.grant], [true, true, true])

        let granted = try await model.setRegistrar(model.deviceId, grant: true)
        XCTAssertEqual(granted.roles, ["registrar"]); XCTAssertEqual(granted.revision, 2)
        XCTAssertEqual(relay.rolesPosts.last?.roles, ["registrar"], "complete sorted list")
        XCTAssertEqual(relay.rolesPosts.last?.signature, String(repeating: "5a", count: 64))
        XCTAssertEqual(model.me?.policyRevision, 2)
        rows = Dictionary(uniqueKeysWithValues: model.deviceRoles.devices.map { ($0.deviceId, $0) })
        XCTAssertEqual([rows[model.deviceId]?.registrar, rows[model.deviceId]?.release, rows[model.deviceId]?.lastRegistrar], [true, false, true])
        XCTAssertEqual([rows["owner-web-a"]?.grant, rows["owner-web-a"]?.release], [true, false])

        do {
            try await model.setRegistrar(model.deviceId, grant: false)
            XCTFail("the last registrar cannot release itself")
        } catch let refusal as DevicePolicyRefusal {
            XCTAssertEqual(refusal.code, "approval_rejected")
        }
        _ = try await model.setRegistrar("owner-web-a", grant: true)
        let released = try await model.setRegistrar(model.deviceId, grant: false)
        XCTAssertEqual(released.roles, []); XCTAssertEqual(released.revision, 4)
        XCTAssertEqual(relay.rolesPosts.last?.roles, [], "empty array = no roles")
        XCTAssertEqual(relay.policyDevice(model.deviceId)?.roles, [])
        XCTAssertFalse(model.deviceRoles.canSign, "now owner-web-a is the registrar — this device may not sign")
    }

    /// 역할 변경의 409 stale_revision: /v2/me 를 다시 읽고 한 번 다시 서명한다.
    func testRolesStaleRevisionIsResignedOnce() async throws {
        let clock = Clock()
        let relay = InMemoryRelay()
        relay.seedDevice("owner-iphone-abc123")
        let model = makeModel(relay: relay, inner: relay, clock: clock)
        await model.bootstrap(); model.login(.bearer("t"))
        await model.refresh()
        relay.bumpPolicyRevision()
        let commit = try await model.setRegistrar(model.deviceId, grant: true)
        XCTAssertEqual(commit.revision, 3)
        XCTAssertEqual(relay.rolesPosts.map(\.baseRevision), [1, 2])
    }

    // MARK: - 형제 기기가 보낸 로비 Welcome

    /// 가족 기기(mom, B)도 같은 actor 의 활성 형제 기기가 보낸 Welcome 은 묻지 않고 받아들인다(from); 봇이 보낸 것은 종전대로 수락 대기.
    func testFamilyDeviceAutoAcceptsAWelcomeFromItsSibling() async throws {
        let clock = Clock()
        let relay = InMemoryRelay()
        relay.seedDevice("mom-iphone-abc123")
        relay.seedDevice("mom-web-a")
        relay.seedDevice("mom-old-c", status: "revoked")
        let model = makeModel(actor: "mom", relay: relay, inner: relay, clock: clock)
        await model.bootstrap(); model.login(.bearer("t"))
        await model.refresh()
        XCTAssertFalse(model.autoJoinsLobbyInvites)
        relay.seedWelcome(room: "ops-yukson", target: model.deviceId, bot: "bot-gongmyoung")
        relay.seedWelcome(room: "family", target: model.deviceId, bot: "mom-web-a")
        relay.seedWelcome(room: "old", target: model.deviceId, bot: "mom-old-c")
        await model.refresh()
        XCTAssertEqual(model.inviteStates["ops-yukson"], AppModel.InviteState.new, "a bot's Welcome still waits for the tap")
        XCTAssertEqual(model.inviteStates["old"], AppModel.InviteState.new, "a revoked device is not a sibling")
        // 형제의 Welcome 은 자동으로 시도됐다 — 가짜 엔진은 참여를 증명하지 못해 실패 상태로 남는다(LobbyTests 의 오너 기기와 같은 모양).
        XCTAssertEqual(model.inviteStates["family"], AppModel.InviteState.failed(tries: 1, reason: Strings.notJoined))
    }

    // MARK: - /v2/me 주기

    func testMeIsReadOnLoginEveryNRoundsAndOnForeground() async throws {
        let clock = Clock()
        let relay = InMemoryRelay()
        relay.seedDevice("owner-iphone-abc123")
        let model = makeModel(relay: relay, inner: relay, clock: clock, meEveryRounds: 4)
        await model.bootstrap(); model.login(.bearer("t"))
        await model.refresh()
        XCTAssertEqual(relay.meCalls, 1)
        XCTAssertEqual(model.me?.devices?.map(\.deviceId), ["owner-iphone-abc123"])
        await model.refresh(); await model.refresh(); await model.refresh()
        XCTAssertEqual(relay.meCalls, 1, "not every 4-second round")
        await model.refresh()
        XCTAssertEqual(relay.meCalls, 2, "every 4th round")
        await model.foregrounded()
        XCTAssertEqual(relay.meCalls, 3, "foreground return re-reads the chain")
        model.logout()
        XCTAssertNil(model.me)
    }

    func testRetryableInviteErrors() {
        XCTAssertTrue(AppModel.isRetryableInviteError(MembershipError.noKeyPackage("x")))
        XCTAssertTrue(AppModel.isRetryableInviteError(MembershipError.ownCommitNotMerged))
        XCTAssertTrue(AppModel.isRetryableInviteError(RelayError.cas(epoch: 1, revision: 1)))
        XCTAssertTrue(AppModel.isRetryableInviteError(RelayError.network("down")))
        XCTAssertTrue(AppModel.isRetryableInviteError(RelayError.refused(code: "bad_gateway", status: 502)))
        XCTAssertFalse(AppModel.isRetryableInviteError(RelayError.refused(code: "not_a_member", status: 403)))
        XCTAssertFalse(AppModel.isRetryableInviteError(MembershipError.notInGroup))
        XCTAssertFalse(AppModel.isRetryableInviteError(EngineError.rejected("x")))
    }
}
