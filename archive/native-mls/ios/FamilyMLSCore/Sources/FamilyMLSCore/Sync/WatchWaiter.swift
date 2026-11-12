import Foundation

/// 바퀴 사이 대기(#755 3단계). 릴레이가 `GET /v2/watch`(#424)를 알면 방 전체를 요청 하나로 기다렸다가 바뀌는 즉시 돌아간다 —
/// 4초 폴링(방마다 GET)이 「바뀔 때 한 번」이 된다. 호출자(AppModel)는 송신 직렬 잠금 **밖에서** 부른다(보내기가 막히지 않게).
///
/// - #424 이전 릴레이(`watch` 가 `nil`): `reprobeInterval` 동안 고정 주기(`pollInterval`) 대기, 그 뒤 다시 확인.
/// - 오류(망·인증·디코딩): 이번 바퀴는 고정 주기 대기, 다음 바퀴에 다시 시도.
/// - 바퀴 사이 최소 `minGap` — typing 처럼 잦은 변화가 바퀴를 몰아치지 않게.
/// 시계·대기는 주입(테스트). 웹 `watch-loop.js`·Android `DeviceHub.waitForChange` 와 같은 규칙.
public final class WatchWaiter {
    public static let waitMilliseconds = 25_000
    public static let minGap: TimeInterval = 1
    public static let reprobeInterval: TimeInterval = 300
    public static let maxRooms = 64

    public private(set) var watching = false
    private var unsupportedUntil = Date.distantPast
    private let now: () -> Date
    private let sleep: (TimeInterval) async throws -> Void

    public init(now: @escaping () -> Date = Date.init,
                sleep: @escaping (TimeInterval) async throws -> Void = { try await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000)) }) {
        self.now = now
        self.sleep = sleep
    }

    /// 다음 바퀴까지 기다린다. 돌려주는 값은 바뀐 방(빈 배열 = 시간 초과·폴백 대기). 취소되면 던진다.
    @discardableResult
    public func wait(transport: RelayTransport, device: DeviceID, rooms: [(room: RoomID, after: Int64)],
                     pollInterval: TimeInterval) async throws -> [RoomID] {
        guard !rooms.isEmpty, now() >= unsupportedUntil else {
            watching = false
            try await sleep(pollInterval)
            return []
        }
        let started = now()
        let response: WatchResponse?
        do {
            response = try await transport.watch(device: device, rooms: Array(rooms.prefix(Self.maxRooms)),
                                                 waitMilliseconds: Self.waitMilliseconds)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            watching = false
            try await sleep(pollInterval)
            return []
        }
        guard let response else {
            unsupportedUntil = now().addingTimeInterval(Self.reprobeInterval)
            watching = false
            try await sleep(pollInterval)
            return []
        }
        watching = true
        let spent = now().timeIntervalSince(started)
        if spent < Self.minGap { try await sleep(Self.minGap - spent) }
        return response.changed
    }
}
