// 방 순서 동기화(#715 room-order v1) — 와이어 디코드·요청 URL/인증/본문·PUT 응답 매핑(409 → conflict) · 판정기(채택·시드·충돌·404·간격).
// 실제 왕복은 RelayTransportTests 와 같은 이유(Linux corelibs URLSession 모킹 불가)로 순수 함수만 고정한다.
import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import FamilyMLSCore

final class RoomOrderSyncTests: XCTestCase {
    private let baseURL = URL(string: "https://relay.example.com")!
    private func transport(_ credential: RelayCredential = .bearer("t"), base: URL? = nil) -> URLSessionRelayTransport {
        URLSessionRelayTransport(baseURL: base ?? baseURL, credential: credential)
    }
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private func state(_ rooms: [RoomID], _ revision: Int64) -> RoomOrderState {
        RoomOrderState(rooms: rooms, revision: revision, updatedAt: revision == 0 ? 0 : 1_800_000_000)
    }

    // MARK: - 와이어

    func testDecodesContractBodies() throws {
        let t = transport()
        XCTAssertEqual(try t.decode(RoomOrderState.self, Data(#"{"rooms":[],"revision":0,"updated_at":0}"#.utf8)), .empty)
        XCTAssertEqual(try t.decode(RoomOrderState.self, Data(#"{"rooms":["family","bot-dm"],"revision":3,"updated_at":1800000000}"#.utf8)),
                       state(["family", "bot-dm"], 3))
        // updated_at 은 없어도 된다(표시용). rooms·revision 은 필수.
        XCTAssertEqual(try t.decode(RoomOrderState.self, Data(#"{"rooms":["a"],"revision":1}"#.utf8)).updatedAt, 0)
        XCTAssertThrowsError(try t.decode(RoomOrderState.self, Data(#"{"revision":1}"#.utf8)))
    }

    func testGetRequestCarriesDeviceAndSameAuth() throws {
        let bearer = try transport(.bearer("jwt-x")).roomOrderRequest(device: "owner-iphone-1")
        XCTAssertEqual(bearer.httpMethod, "GET")
        XCTAssertEqual(bearer.url?.absoluteString, "https://relay.example.com/v2/me/room-order?device=owner-iphone-1")
        XCTAssertEqual(bearer.value(forHTTPHeaderField: "Cf-Access-Jwt-Assertion"), "jwt-x")
        XCTAssertNil(bearer.httpBody)
        let cookie = try transport(.accessCookie("jwt-c")).roomOrderRequest(device: "d")
        XCTAssertEqual(cookie.value(forHTTPHeaderField: "Cookie"), "CF_Authorization=jwt-c")
        let based = try transport(base: URL(string: "https://example.com/relay/")!).roomOrderRequest(device: "d")
        XCTAssertEqual(based.url?.absoluteString, "https://example.com/relay/v2/me/room-order?device=d")
    }

    func testPutRequestBodyMatchesContract() throws {
        let request = try transport(.accessCookie("jwt-c")).putRoomOrderRequest(device: "owner-iphone-1", rooms: ["family", "x"], baseRevision: 4)
        XCTAssertEqual(request.httpMethod, "PUT")
        XCTAssertEqual(request.url?.absoluteString, "https://relay.example.com/v2/me/room-order")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Cookie"), "CF_Authorization=jwt-c")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        let body = try XCTUnwrap(request.httpBody)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(object["device"] as? String, "owner-iphone-1")
        XCTAssertEqual(object["rooms"] as? [String], ["family", "x"])
        XCTAssertEqual((object["base_revision"] as? NSNumber)?.int64Value, 4)
        XCTAssertEqual(Set(object.keys), ["device", "rooms", "base_revision"])
    }

    func testPutResponseMapping() throws {
        let t = transport()
        XCTAssertEqual(try t.roomOrderPutResult(status: 200, data: Data(#"{"rooms":["a","b"],"revision":5,"updated_at":1800000000}"#.utf8)),
                       .saved(state(["a", "b"], 5)))
        XCTAssertEqual(try t.roomOrderPutResult(
            status: 409, data: Data(#"{"error":"revision_conflict","rooms":["b","a"],"revision":7,"updated_at":1800000000}"#.utf8)),
                       .conflict(state(["b", "a"], 7)))
        // 409 인데 본문이 계약 모양이 아니면 거부로(앱은 다음 GET 으로 서버 값을 받는다).
        XCTAssertThrowsError(try t.roomOrderPutResult(status: 409, data: Data(#"{"error":"revision_conflict"}"#.utf8))) {
            XCTAssertEqual($0 as? RelayError, .refused(code: "revision_conflict", status: 409))
        }
        XCTAssertThrowsError(try t.roomOrderPutResult(status: 400, data: Data(#"{"error":"duplicate_room"}"#.utf8))) {
            XCTAssertEqual($0 as? RelayError, .refused(code: "duplicate_room", status: 400))
        }
        XCTAssertThrowsError(try t.roomOrderPutResult(status: 404, data: Data("404 page not found".utf8))) {
            XCTAssertEqual($0 as? RelayError, .refused(code: "http_404", status: 404))
        }
    }

    /// 옛 전송(테스트 대역 포함)은 프로토콜 기본 구현 = 404 → 기능 감지로 꺼진다.
    func testDefaultTransportIs404() async {
        final class Old: RelayTransport {
            func postKeyPackages(room: RoomID, _ post: KeyPackagePost) async throws -> KeyPackagesResponse { throw RelayError.network("n/a") }
            func consumeKeyPackage(room: RoomID, device: DeviceID, target: DeviceID) async throws -> StoredKeyPackage? { nil }
            func postEvent(room: RoomID, _ post: EventPost) async throws -> EventPostResponse { throw RelayError.network("n/a") }
            func getEvents(room: RoomID, device: DeviceID, after: Int64, limit: Int, ack: Int64?) async throws -> EventsPage { throw RelayError.network("n/a") }
            func closeRoom(room: RoomID, device: DeviceID) async throws {}
            func listRooms(device: DeviceID) async throws -> RoomsResponse { throw RelayError.network("n/a") }
            func registerPush(_ registration: PushRegistration) async throws {}
            func unregisterPush(device: DeviceID) async throws {}
        }
        do { _ = try await Old().roomOrder(device: "d"); XCTFail("expected 404") } catch {
            XCTAssertEqual(RoomOrderSync.Failure.classify(error), .unsupported)
        }
        do { _ = try await Old().putRoomOrder(device: "d", rooms: ["a"], baseRevision: 0); XCTFail("expected 404") } catch {
            XCTAssertEqual(RoomOrderSync.Failure.classify(error), .unsupported)
        }
    }

    func testFailureClassification() {
        XCTAssertEqual(RoomOrderSync.Failure.classify(RelayError.refused(code: "http_404", status: 404)), .unsupported)
        XCTAssertEqual(RoomOrderSync.Failure.classify(RelayError.refused(code: "duplicate_room", status: 400)), .rejected)
        XCTAssertEqual(RoomOrderSync.Failure.classify(RelayError.refused(code: "device_not_allowed", status: 403)), .transient)
        XCTAssertEqual(RoomOrderSync.Failure.classify(RelayError.network("offline")), .transient)
        XCTAssertEqual(RoomOrderSync.Failure.classify(RelayError.unauthorized), .transient)
        XCTAssertEqual(RoomOrderSync.Failure.classify(CancellationError()), .transient)
    }

    // MARK: - 올릴 순서 (화면 순서)

    func testLocalOrderIsTheVisibleOrder() {
        // 사용자 순서 없음 → 시드하지 않는다(기본 순서는 사용자 순서가 아니다).
        XCTAssertEqual(RoomOrderSync.localOrder(saved: [], rooms: ["a", "b"]), [])
        // 저장 순서의 방 → 거기 없는 방(기본 순서) → 목록에 없는 저장 ID(뒤). `RoomOrder.apply` 와 같은 앞부분.
        XCTAssertEqual(RoomOrderSync.localOrder(saved: ["c", "gone", "a"], rooms: ["a", "b", "c", "d"]), ["c", "a", "b", "d", "gone"])
        // 방 목록이 아직 비어도 저장 순서를 잃지 않는다.
        XCTAssertEqual(RoomOrderSync.localOrder(saved: ["c", "a"], rooms: []), ["c", "a"])
        // 중복·형식 위반은 뺀다(릴레이 400 duplicate_room / bad_identifier 를 미리 피한다).
        XCTAssertEqual(RoomOrderSync.localOrder(saved: ["a", "a", "bad id", "b/c", ""], rooms: ["a"]), ["a"])
    }

    func testLocalOrderCapsAt64KeepingListedRoomsFirst() {
        let listed = (0..<60).map { "r\($0)" }
        let stale = (0..<10).map { "old\($0)" }
        let order = RoomOrderSync.localOrder(saved: stale + listed.reversed(), rooms: listed)
        XCTAssertEqual(order.count, RoomOrderSync.maxRooms)
        XCTAssertEqual(Array(order.prefix(60)), listed.reversed(), "목록에 있는 방이 먼저 — 64개 상한이 실제 방을 밀어내지 않는다")
        XCTAssertEqual(Array(order.suffix(4)), ["old0", "old1", "old2", "old3"])
    }

    func testIdentifierRule() {
        XCTAssertTrue(RoomOrderSync.isValidRoomID("Family_room-1"))
        XCTAssertTrue(RoomOrderSync.isValidRoomID(String(repeating: "a", count: 64)))
        XCTAssertFalse(RoomOrderSync.isValidRoomID(String(repeating: "a", count: 65)))
        XCTAssertFalse(RoomOrderSync.isValidRoomID(""))
        XCTAssertFalse(RoomOrderSync.isValidRoomID("가족"))
        XCTAssertFalse(RoomOrderSync.isValidRoomID("a.b"))
    }

    // MARK: - 판정: GET (규칙 1)

    /// 업데이트 뒤 첫 실행: 서버 revision 0 + 아이폰의 기존 순서 → 그 순서를 base 0 으로 시드, 200 이면 그대로.
    func testRevisionZeroSeedsTheExistingLocalOrder() {
        var sync = RoomOrderSync()
        XCTAssertTrue(sync.beginFetch(now: t0))
        let saved = ["bot-dm", "family"]
        let rooms = ["family", "bot-dm", "work"]
        XCTAssertEqual(sync.fetched(.empty, saved: saved, rooms: rooms), .put(rooms: ["bot-dm", "family", "work"], baseRevision: 0))
        XCTAssertTrue(sync.busy)
        // 릴레이가 받은 그대로(화면 순서 전체) → 로컬 저장 순서도 화면과 같은 전체 목록으로.
        XCTAssertEqual(sync.putFinished(.saved(state(["bot-dm", "family", "work"], 1)), saved: saved, rooms: rooms),
                       .adopt(["bot-dm", "family", "work"]))
        XCTAssertEqual(sync.revision, 1)
        XCTAssertFalse(sync.busy)
        XCTAssertFalse(sync.hasUnsentEdit)
    }

    func testRevisionZeroWithoutLocalOrderDoesNothing() {
        var sync = RoomOrderSync()
        XCTAssertTrue(sync.beginFetch(now: t0))
        XCTAssertEqual(sync.fetched(.empty, saved: [], rooms: ["a", "b"]), .none)
        XCTAssertEqual(sync.revision, 0)
        XCTAssertFalse(sync.busy)
    }

    func testServerOrderIsAdoptedWhenRevisionPositive() {
        var sync = RoomOrderSync()
        XCTAssertTrue(sync.beginFetch(now: t0))
        XCTAssertEqual(sync.fetched(state(["b", "a"], 3), saved: ["a", "b"], rooms: ["a", "b"]), .adopt(["b", "a"]))
        XCTAssertEqual(sync.revision, 3)
        // 같으면 다시 쓰지 않는다.
        XCTAssertTrue(sync.beginFetch(now: t0.addingTimeInterval(60)))
        XCTAssertEqual(sync.fetched(state(["b", "a"], 3), saved: ["b", "a"], rooms: ["a", "b"]), .none)
    }

    /// 다른 기기가 먼저 시드했다: revision 0 을 보고 올렸는데 409 → 서버 것 채택.
    func testSeedConflictAdoptsServer() {
        var sync = RoomOrderSync()
        XCTAssertTrue(sync.beginFetch(now: t0))
        XCTAssertEqual(sync.fetched(.empty, saved: ["a", "b"], rooms: ["a", "b"]), .put(rooms: ["a", "b"], baseRevision: 0))
        XCTAssertEqual(sync.putFinished(.conflict(state(["b", "a"], 1)), saved: ["a", "b"], rooms: ["a", "b"]), .adopt(["b", "a"]))
        XCTAssertEqual(sync.revision, 1)
        XCTAssertFalse(sync.busy)
    }

    /// 409 의 서버 값이 revision 0(릴레이 DB 가 비워졌다) → 빈 순서로 덮지 않고 base 0 으로 다시 시드.
    func testConflictAtRevisionZeroReseeds() {
        var sync = RoomOrderSync()
        XCTAssertTrue(sync.beginFetch(now: t0))
        _ = sync.fetched(state(["a", "b"], 5), saved: ["a", "b"], rooms: ["a", "b"])
        XCTAssertEqual(sync.reordered(saved: ["b", "a"], rooms: ["a", "b"]), .put(rooms: ["b", "a"], baseRevision: 5))
        XCTAssertEqual(sync.putFinished(.conflict(.empty), saved: ["b", "a"], rooms: ["a", "b"]), .put(rooms: ["b", "a"], baseRevision: 0))
    }

    func testFetchIntervalIsAtLeast60Seconds() {
        var sync = RoomOrderSync()
        XCTAssertTrue(sync.canFetch(now: t0))
        XCTAssertTrue(sync.beginFetch(now: t0))
        XCTAssertFalse(sync.canFetch(now: t0), "왕복 중에는 다시 묻지 않는다")
        _ = sync.fetched(.empty, saved: [], rooms: [])
        XCTAssertFalse(sync.beginFetch(now: t0.addingTimeInterval(59)))
        XCTAssertTrue(sync.beginFetch(now: t0.addingTimeInterval(60)))
    }

    // MARK: - 판정: 사용자 변경 (규칙 2)

    func testReorderPutsWithLastSeenRevision() {
        var sync = RoomOrderSync()
        XCTAssertTrue(sync.beginFetch(now: t0))
        XCTAssertEqual(sync.fetched(state(["a", "b", "c"], 2), saved: ["a", "b", "c"], rooms: ["a", "b", "c"]), .none)
        XCTAssertEqual(sync.reordered(saved: ["c", "a", "b"], rooms: ["a", "b", "c"]), .put(rooms: ["c", "a", "b"], baseRevision: 2))
        XCTAssertTrue(sync.hasUnsentEdit)
        XCTAssertEqual(sync.putFinished(.saved(state(["c", "a", "b"], 3)), saved: ["c", "a", "b"], rooms: ["a", "b", "c"]), .none)
        XCTAssertEqual(sync.revision, 3)
        XCTAssertFalse(sync.hasUnsentEdit)
    }

    func testReorderConflictAdoptsServer() {
        var sync = RoomOrderSync()
        XCTAssertTrue(sync.beginFetch(now: t0))
        _ = sync.fetched(state(["a", "b", "c"], 2), saved: ["a", "b", "c"], rooms: ["a", "b", "c"])
        _ = sync.reordered(saved: ["c", "a", "b"], rooms: ["a", "b", "c"])
        XCTAssertEqual(sync.putFinished(.conflict(state(["b", "c", "a"], 4)), saved: ["c", "a", "b"], rooms: ["a", "b", "c"]),
                       .adopt(["b", "c", "a"]))
        XCTAssertEqual(sync.revision, 4)
        XCTAssertFalse(sync.hasUnsentEdit, "409 → 서버 것 채택, 접은 변경을 다시 올리지 않는다")
    }

    /// 첫 GET 전에 바꾼 순서는 서버 순서로 덮지 않는다 — GET 이 끝나면 그 revision 위에 올린다.
    func testReorderBeforeFirstFetchIsPushedAfterIt() {
        var sync = RoomOrderSync()
        XCTAssertEqual(sync.reordered(saved: ["b", "a"], rooms: ["a", "b"]), .none, "revision 을 모른다 — 아직 보내지 않는다")
        XCTAssertTrue(sync.hasUnsentEdit)
        XCTAssertTrue(sync.beginFetch(now: t0))
        XCTAssertEqual(sync.fetched(state(["a", "b"], 6), saved: ["b", "a"], rooms: ["a", "b"]), .put(rooms: ["b", "a"], baseRevision: 6))
    }

    /// GET 중에 바꿨다 → 결과로 덮지 않고 그 revision 위에 올린다.
    func testReorderDuringFetchIsPushedAfterIt() {
        var sync = RoomOrderSync()
        XCTAssertTrue(sync.beginFetch(now: t0))
        XCTAssertEqual(sync.reordered(saved: ["b", "a"], rooms: ["a", "b"]), .none)
        XCTAssertEqual(sync.fetched(.empty, saved: ["b", "a"], rooms: ["a", "b"]), .put(rooms: ["b", "a"], baseRevision: 0))
    }

    /// PUT 중에 또 바꿨다 → 200 뒤 새 revision 으로 한 번 더(마지막 순서가 서버에 남는다).
    func testReorderDuringPutIsPushedAgain() {
        var sync = RoomOrderSync()
        XCTAssertTrue(sync.beginFetch(now: t0))
        _ = sync.fetched(state(["a", "b", "c"], 2), saved: ["a", "b", "c"], rooms: ["a", "b", "c"])
        XCTAssertEqual(sync.reordered(saved: ["b", "a", "c"], rooms: ["a", "b", "c"]), .put(rooms: ["b", "a", "c"], baseRevision: 2))
        XCTAssertEqual(sync.reordered(saved: ["c", "b", "a"], rooms: ["a", "b", "c"]), .none, "왕복 하나만")
        XCTAssertEqual(sync.putFinished(.saved(state(["b", "a", "c"], 3)), saved: ["c", "b", "a"], rooms: ["a", "b", "c"]),
                       .put(rooms: ["c", "b", "a"], baseRevision: 3))
        XCTAssertEqual(sync.putFinished(.saved(state(["c", "b", "a"], 4)), saved: ["c", "b", "a"], rooms: ["a", "b", "c"]), .none)
        XCTAssertFalse(sync.hasUnsentEdit)
    }

    // MARK: - 실패 (규칙 4)

    func testNotFoundTurnsSyncOffForTheSession() {
        var sync = RoomOrderSync()
        XCTAssertTrue(sync.beginFetch(now: t0))
        sync.failed(.unsupported)
        XCTAssertTrue(sync.unsupported)
        XCTAssertFalse(sync.canFetch(now: t0.addingTimeInterval(3600)))
        XCTAssertEqual(sync.reordered(saved: ["b", "a"], rooms: ["a", "b"]), .none)
    }

    /// 네트워크 오류: 바꾼 순서를 남겨 다음 GET 뒤에 다시 올린다.
    func testTransientPutFailureRetriesAfterNextFetch() {
        var sync = RoomOrderSync()
        XCTAssertTrue(sync.beginFetch(now: t0))
        _ = sync.fetched(state(["a", "b"], 2), saved: ["a", "b"], rooms: ["a", "b"])
        _ = sync.reordered(saved: ["b", "a"], rooms: ["a", "b"])
        sync.failed(.transient)
        XCTAssertTrue(sync.hasUnsentEdit)
        XCTAssertFalse(sync.busy)
        XCTAssertTrue(sync.beginFetch(now: t0.addingTimeInterval(60)))
        XCTAssertEqual(sync.fetched(state(["a", "b"], 2), saved: ["b", "a"], rooms: ["a", "b"]), .put(rooms: ["b", "a"], baseRevision: 2))
    }

    /// 시드가 닿지 않았다 → 다음 주기에 revision 0 을 다시 보고 다시 시드.
    func testTransientSeedFailureReseedsNextCycle() {
        var sync = RoomOrderSync()
        XCTAssertTrue(sync.beginFetch(now: t0))
        _ = sync.fetched(.empty, saved: ["b", "a"], rooms: ["a", "b"])
        sync.failed(.transient)
        XCTAssertTrue(sync.beginFetch(now: t0.addingTimeInterval(60)))
        XCTAssertEqual(sync.fetched(.empty, saved: ["b", "a"], rooms: ["a", "b"]), .put(rooms: ["b", "a"], baseRevision: 0))
    }

    func testRejectedPutIsNotResent() {
        var sync = RoomOrderSync()
        XCTAssertTrue(sync.beginFetch(now: t0))
        _ = sync.fetched(state(["a", "b"], 2), saved: ["a", "b"], rooms: ["a", "b"])
        _ = sync.reordered(saved: ["b", "a"], rooms: ["a", "b"])
        sync.failed(.rejected)
        XCTAssertFalse(sync.hasUnsentEdit)
        XCTAssertTrue(sync.beginFetch(now: t0.addingTimeInterval(60)))
        XCTAssertEqual(sync.fetched(state(["a", "b"], 2), saved: ["b", "a"], rooms: ["a", "b"]), .adopt(["a", "b"]))
    }
}
