// 격리 릴레이 스모크 (#276 §2.4 두 번째 수용 기준) — 실 MLS 엔진(ios-ffi) + 실 HTTP(URLSessionRelayTransport)
// + 실 Go 릴레이(`-access-mode disabled`, loopback 임시 포트, 임시 데이터 디렉터리).
//
// 릴레이와 감독자(`scripts/relay_smoke_supervisor.py`)는 CI 스텝(macOS) 또는 로컬 컨테이너가 띄우고 주소를 환경변수로 준다:
//   FC_SMOKE_RELAY_URL    예 http://127.0.0.1:53781
//   FC_SMOKE_CONTROL_URL  감독자 제어(POST /stop · /start)
// xcodebuild 는 `TEST_RUNNER_` 접두 환경변수를 접두 없이 테스트 프로세스에 넘긴다. 둘 다 없으면 건너뛴다(일반 PR·로컬).
// 시나리오는 IntegrationTests 와 같은 `TwoDeviceScenario`(초대→참여→양방향→릴레이 중단/재시작→정확 바이트 200→commit 위반 정지).
import XCTest
import FamilyMLSCore
@testable import FamilyChat

/// 감독자 제어 포트로 릴레이를 멈추고 다시 띄운다(같은 데이터 디렉터리 — 저장된 이벤트가 재시작 뒤에도 남는다).
final class SupervisorControl: RelayControl {
    let controlURL: URL
    init(controlURL: URL) { self.controlURL = controlURL }

    private func post(_ path: String) async throws {
        var request = URLRequest(url: controlURL.appendingPathComponent(path), timeoutInterval: 60)
        request.httpMethod = "POST"
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw RelayError.network("supervisor \(path): \(String(decoding: data, as: UTF8.self))")
        }
    }

    func stop() async throws { try await post("stop") }
    func start() async throws { try await post("start") }
}

@MainActor
final class RelaySmokeTests: XCTestCase {
    func testIsolatedRelaySmoke() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let relayRaw = env["FC_SMOKE_RELAY_URL"], let relayURL = URL(string: relayRaw),
              let controlRaw = env["FC_SMOKE_CONTROL_URL"], let controlURL = URL(string: controlRaw) else {
            throw XCTSkip("FC_SMOKE_RELAY_URL / FC_SMOKE_CONTROL_URL not set — isolated relay smoke runs only in the CI smoke step")
        }
        // 격리 릴레이는 엣지가 없으므로 쿠키가 아니라 assertion 헤더(.bearer)로 직결한다(CONTRACTS §2.1). disabled 모드라 값은 검증되지 않는다.
        let transport = URLSessionRelayTransport(baseURL: relayURL, credential: .bearer("smoke"), requestTimeout: 10)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("fc-smoke-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        // 같은 릴레이를 여러 번 써도 겹치지 않게 방 이름에 임의 접미사(서버 식별자 규칙 [a-z0-9-]).
        let room = "smoke-\(UUID().uuidString.prefix(8).lowercased())"
        try await TwoDeviceScenario(relay: transport, control: SupervisorControl(controlURL: controlURL), root: root, room: room)
            .run { print("[relay-smoke] \($0)") }
    }
}
