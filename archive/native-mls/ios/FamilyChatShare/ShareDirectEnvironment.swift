// #669 공유 확장의 직접 송신 조립(#664 과제 A) — 알림 확장(`NSEEnvironment`)과 같은 규칙으로 App Group 의 MLS 상태·messages.db 를
// flock 단일 작성자로 연다(#664 코드 근거: NSE 가 이미 같은 `RoomSyncEngine` 으로 쓴다 — 확장이 "두 번째 작성자"가 되는 문제는 없다).
// 아무것도 새로 만들지 않는다: 서버 스코프 디렉터리·기기 ID·자격증명 중 하나라도 없으면 nil → 확장은 종전처럼 맡기기만 한다(D-A1 폴백).
// 내 글 기록 재료(#665 `ownPending`)를 같은 DB 에 두므로 확장이 보낸 글도 앱 화면에 기록으로 이어진다(.queued 면 앱 flushOutbox 뒤).
import Foundation
import os
import FamilyMLSCore

struct ShareDirectEnvironment {
    let identity: DeviceID
    let credential: RelayCredential
    let relayURL: URL
    let stateStore: FileStateStore
    let database: FileSQLiteStore

    /// 실기기 메모리 측정(P2 산출물 → P3 문턱)용. 수치는 로그에만 — 화면에 내지 않는다.
    static let log = Logger(subsystem: "com.seoyoon-family.hande.share", category: "direct-send")

    /// 확장 예산 안: 락 대기 3 s(NSE 와 같음, CONTRACTS §3.1 ≤5 s), 페이지 100 × 최대 5. 기록 표시는 `.app` 그대로 — 열거형에
    /// 값을 늘리면 옛 앱이 확장이 넣은 행을 읽지 못한다.
    static var configuration: RoomSyncEngine.Configuration {
        var configuration = RoomSyncEngine.Configuration()
        configuration.lockTimeout = 3
        configuration.pageLimit = 100
        configuration.maxPages = 5
        return configuration
    }

    static func live(group: String, container: URL, server: ServerSelection) -> ShareDirectEnvironment? {
        let scope = ServerScope(baseURL: server.baseURL)
        let directory = scope.directory(in: container)
        // 앱이 아직 이 스코프를 만들지 않았다(업데이트 뒤 첫 실행 전) — 만들지 않는다. 기기 ID·자격증명도 읽기만.
        guard FileManager.default.fileExists(atPath: directory.path),
              let identity = SharedStorage.existingDeviceId(appGroup: group, scope: scope), !identity.isEmpty,
              let credential = SharedStorage.credentialStore(appGroup: group, scope: scope).load(),
              let sealer = try? SharedStorage.sealer(appGroup: group),
              let stateStore = try? FileStateStore(directory: directory.appendingPathComponent("mls", isDirectory: true), sealer: sealer),
              let database = try? FileSQLiteStore(directory: directory) else {
            return nil
        }
        return ShareDirectEnvironment(identity: identity, credential: credential, relayURL: server.baseURL,
                                      stateStore: stateStore, database: database)
    }

    /// 방의 엔진 — NSE 와 같은 시드 규칙(방 상태가 없을 때만 `_identity` 슬롯에서, 방 락 → identity 락 순서). 이 기기가 모르는 방이면 nil(맡기기).
    func engine(room: RoomID) throws -> RoomSyncEngine? {
        guard try database.rooms().contains(where: { $0.room == room }) else { return nil }
        let store = stateStore
        let lockTimeout = Self.configuration.lockTimeout
        let factory = SeededEngineFactory(base: FfiEngineFactory()) {
            guard let seed = try store.withExclusive(room: Strings.identityRoom, timeout: lockTimeout, { try $0.load() }) else {
                throw StateStoreError.io("identity slot missing")
            }
            return seed
        }
        // 요청 하나 30 s(앱 기본) — 8 MiB blob 업로드가 들어간다(NSE 의 10 s 는 알림 예산 때문).
        let transport = URLSessionRelayTransport(baseURL: relayURL, credential: credential)
        return try RoomSyncEngine(room: room, identity: identity, engineFactory: factory, stateStore: stateStore,
                                  outbox: database, cursors: database, messages: database, transport: transport,
                                  configuration: Self.configuration, ownPending: database)
    }
}

/// 조각 → 엔진 송신. 앱 `AppModel.sendAttachment` 와 같은 분기: file-v2 스위치가 켜져 있으면 봉인·업로드 → 설명자(사진이면 w/h 힌트),
/// 아니면 v1 첨부. 파일은 보낼 때만 메모리에 올린다(≤ `ShareDirectSend.maxDirectFileBytes`, 계획이 걸렀다).
final class ShareDirectSender: ShareDirectSending {
    private let engine: RoomSyncEngine
    private let store: ShareHandoffStore
    private let item: ShareHandoff.Item

    init(engine: RoomSyncEngine, store: ShareHandoffStore, item: ShareHandoff.Item) {
        self.engine = engine; self.store = store; self.item = item
    }

    func send(_ piece: ShareHandoff.Piece) async throws -> SendOutcome {
        switch piece {
        case .text:
            guard let text = item.text else { throw ShareHandoff.Failure.empty }
            return try await engine.send(text: text)
        case .file(let name):
            guard let data = try? Data(contentsOf: store.fileURL(item, name)) else { throw ShareHandoff.Failure.unreadable(name: name) }
            guard FileV2Format.sendDefault else { return try await engine.send(attachment: data) }
            let mime = AttachmentFormat.sniffMime(data)
            let pixels = AttachmentFormat.isImage(mime: mime) ? ImagePixelSize.probe(data) : nil
            let sent = try await engine.send(fileV2: data, mime: mime == AttachmentFormat.fallbackMime ? nil : mime,
                                             width: pixels?.width, height: pixels?.height)
            return sent.outcome
        }
    }
}

/// 이 프로세스의 물리 메모리(MB) — D-A4 문턱을 확정할 실기기 측정(TestFlight + Console) 재료. 못 읽으면 nil.
enum ShareFootprint {
    static func megabytes() -> Double? {
        #if canImport(Darwin)
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return Double(info.phys_footprint) / 1_048_576
        #else
        return nil
        #endif
    }
}
