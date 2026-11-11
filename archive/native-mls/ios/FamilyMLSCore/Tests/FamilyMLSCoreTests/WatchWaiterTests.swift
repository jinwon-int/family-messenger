// #755 3단계: 바퀴 사이 `/v2/watch` 대기(`WatchWaiter`) — 모드 전환·최소 간격·미지원 재확인·오류·취소·방 상한.
import XCTest
@testable import FamilyMLSCore

final class WatchWaiterTests: XCTestCase {
    /// `watch` 만 각본대로 답하는 전송 대역(나머지 라우트는 쓰지 않는다).
    private final class Scripted: RelayTransport {
        enum Step { case answer(WatchResponse?, spend: TimeInterval), fail(Error) }
        var steps: [Step]
        var calls: [(device: DeviceID, rooms: [(room: RoomID, after: Int64)], wait: Int)] = []
        let clock: FakeClock
        init(_ steps: [Step], clock: FakeClock) { self.steps = steps; self.clock = clock }

        func watch(device: DeviceID, rooms: [(room: RoomID, after: Int64)], waitMilliseconds: Int) async throws -> WatchResponse? {
            calls.append((device: device, rooms: rooms, wait: waitMilliseconds))
            switch steps.removeFirst() {
            case .answer(let response, let spend): clock.t += spend; return response
            case .fail(let error): throw error
            }
        }
        func postKeyPackages(room: RoomID, _ post: KeyPackagePost) async throws -> KeyPackagesResponse { KeyPackagesResponse(stored: 0, duplicates: 0) }
        func consumeKeyPackage(room: RoomID, device: DeviceID, target: DeviceID) async throws -> StoredKeyPackage? { nil }
        func postEvent(room: RoomID, _ post: EventPost) async throws -> EventPostResponse { throw RelayError.network("n/a") }
        func getEvents(room: RoomID, device: DeviceID, after: Int64, limit: Int, ack: Int64?) async throws -> EventsPage { throw RelayError.network("n/a") }
        func closeRoom(room: RoomID, device: DeviceID) async throws {}
        func listRooms(device: DeviceID) async throws -> RoomsResponse { RoomsResponse(rooms: []) }
        func registerPush(_ registration: PushRegistration) async throws {}
        func unregisterPush(device: DeviceID) async throws {}
    }

    private final class FakeClock {
        var t: TimeInterval = 1_000_000
        var sleeps: [TimeInterval] = []
        var now: Date { Date(timeIntervalSince1970: t) }
    }

    private func waiter(_ clock: FakeClock) -> WatchWaiter {
        WatchWaiter(now: { clock.now }, sleep: { clock.sleeps.append($0); clock.t += $0 })
    }

    private let rooms: [(room: RoomID, after: Int64)] = [(room: "family", after: 7), (room: "sogyo", after: 3)]

    func testChangedRoomsReturnAndWatchingTurnsOn() async throws {
        let clock = FakeClock()
        let relay = Scripted([.answer(WatchResponse(changed: ["family"]), spend: 3)], clock: clock)
        let w = waiter(clock)
        let changed = try await w.wait(transport: relay, device: "owner-iphone", rooms: rooms, pollInterval: 4)
        XCTAssertEqual(changed, ["family"])
        XCTAssertTrue(w.watching)
        XCTAssertEqual(relay.calls.count, 1)
        XCTAssertEqual(relay.calls[0].device, "owner-iphone")
        XCTAssertEqual(relay.calls[0].wait, WatchWaiter.waitMilliseconds)
        XCTAssertEqual(relay.calls[0].rooms.map { $0.room }, ["family", "sogyo"])
        XCTAssertEqual(relay.calls[0].rooms.map { $0.after }, [7, 3])
        XCTAssertEqual(clock.sleeps, [], "3 s 걸렸으면 추가 대기 없음")
    }

    func testMinimumGapBetweenRounds() async throws {
        let clock = FakeClock()
        let relay = Scripted([.answer(WatchResponse(changed: ["family"]), spend: 0.2)], clock: clock)
        _ = try await waiter(clock).wait(transport: relay, device: "d", rooms: rooms, pollInterval: 4)
        XCTAssertEqual(clock.sleeps.count, 1)
        XCTAssertEqual(clock.sleeps[0], WatchWaiter.minGap - 0.2, accuracy: 0.0001)
    }

    func testOldRelayFallsBackAndReprobesLater() async throws {
        let clock = FakeClock()
        let relay = Scripted([.answer(nil, spend: 0), .answer(WatchResponse(), spend: 25)], clock: clock)
        let w = waiter(clock)
        _ = try await w.wait(transport: relay, device: "d", rooms: rooms, pollInterval: 4)
        XCTAssertFalse(w.watching)
        XCTAssertEqual(clock.sleeps, [4])
        _ = try await w.wait(transport: relay, device: "d", rooms: rooms, pollInterval: 4)
        XCTAssertEqual(relay.calls.count, 1, "재확인 전에는 다시 묻지 않는다")
        clock.t += WatchWaiter.reprobeInterval
        _ = try await w.wait(transport: relay, device: "d", rooms: rooms, pollInterval: 4)
        XCTAssertEqual(relay.calls.count, 2)
        XCTAssertTrue(w.watching)
    }

    func testErrorFallsBackThisRoundOnly() async throws {
        let clock = FakeClock()
        let relay = Scripted([.fail(RelayError.network("reset")), .answer(WatchResponse(), spend: 25)], clock: clock)
        let w = waiter(clock)
        let first = try await w.wait(transport: relay, device: "d", rooms: rooms, pollInterval: 4)
        XCTAssertEqual(first, [])
        XCTAssertFalse(w.watching)
        XCTAssertEqual(clock.sleeps, [4])
        _ = try await w.wait(transport: relay, device: "d", rooms: rooms, pollInterval: 4)
        XCTAssertTrue(w.watching, "다음 바퀴는 다시 시도")
    }

    func testCancellationPropagates() async {
        let clock = FakeClock()
        let relay = Scripted([.fail(CancellationError())], clock: clock)
        do {
            _ = try await waiter(clock).wait(transport: relay, device: "d", rooms: rooms, pollInterval: 4)
            XCTFail("취소는 던져야 한다")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertEqual(clock.sleeps, [], "취소면 대기하지 않는다")
    }

    func testNoRoomsSleepsWithoutAskingAndRoomListIsCapped() async throws {
        let clock = FakeClock()
        let none = Scripted([], clock: clock)
        _ = try await waiter(clock).wait(transport: none, device: "d", rooms: [], pollInterval: 4)
        XCTAssertEqual(none.calls.count, 0)
        XCTAssertEqual(clock.sleeps, [4])
        let many = (0..<70).map { (room: "r\($0)", after: Int64(0)) }
        let relay = Scripted([.answer(WatchResponse(), spend: 25)], clock: clock)
        _ = try await waiter(clock).wait(transport: relay, device: "d", rooms: many, pollInterval: 4)
        XCTAssertEqual(relay.calls[0].rooms.count, WatchWaiter.maxRooms)
    }
}
