// 첨부(§9-4): 모델의 내 첨부 기록·한도 거절(가짜 엔진 + 메모리 릴레이, AppModelTests.swift) + 사진 축소(UIKit) + 공유용 임시 파일.
// 와이어 규칙·수신 분기는 Core `SyncAttachmentTests` 가 덮는다.
import XCTest
import UIKit
import FamilyMLSCore
@testable import FamilyChat

/// `FakeEngine`(AppModelTests)과 같지만 `.members` 에 이 기기가 든 roster 프레임을 돌려준다 — 송신 경로(`isJoined`)를 지나기 위해.
/// 프레임 = u32le count ‖ (u32le idLen ‖ id ‖ 32B key)*  (CommitPolicy.parseRosterFrame).
final class MemberFakeEngine: MlsEngine {
    let identity: DeviceID
    var state: Data
    init(identity: DeviceID, state: Data = Data("s0".utf8)) { self.identity = identity; self.state = state }
    func dispatch(_ method: EngineMethod, _ input: Data) throws -> Data {
        if method == .members {
            var frame = Data()
            func u32(_ v: Int) { var le = UInt32(v).littleEndian; frame.append(Data(bytes: &le, count: 4)) }
            u32(1); u32(identity.utf8.count); frame.append(Data(identity.utf8)); frame.append(Data(repeating: 0xab, count: 32))
            return frame
        }
        state.append(1)
        return Data("ct:".utf8) + input
    }
    func exportState() throws -> Data { state }
    func publicKey() throws -> Data { Data(repeating: 0xab, count: 32) }
    func fingerprint() throws -> String { String(repeating: "f", count: 64) }
    func hasPending() throws -> Bool { false }
}

struct MemberFakeFactory: MlsEngineFactory {
    func create(identity: DeviceID) throws -> MlsEngine { MemberFakeEngine(identity: identity) }
    func importState(identity: DeviceID, bytes: Data) throws -> MlsEngine { MemberFakeEngine(identity: identity, state: bytes) }
}

@MainActor
final class AttachmentTests: XCTestCase {
    private func readyModel() async -> (AppModel, InMemoryRelay) {
        let relay = InMemoryRelay()
        let deps = AppModel.Dependencies(
            engineFactory: MemberFakeFactory(), stateStore: InMemoryStateStore(), messageStore: InMemoryMessageStore(),
            outbox: InMemoryOutboxStore(), cursors: InMemoryCursorStore(),
            identityProvider: { "mom-iphone-a1b2c3" }, expectedDecryptFormat: { 2 }, makeTransport: { _ in relay })
        let model = AppModel(dependencies: deps)
        await model.bootstrap(); model.login(.bearer("t")); await model.refresh()
        XCTAssertEqual(model.phase, .ready)
        return (model, relay)
    }

    func testTextSendStillRecordsATextRow() async throws {
        let (model, _) = await readyModel()
        guard case .sent(let clientId, _, _)? = await model.send(room: "family", text: "hi") else { return XCTFail("\(String(describing: model.lastError))") }
        XCTAssertFalse(AttachmentFormat.isAttachment(clientId: clientId))
        XCTAssertEqual(model.messages(room: "family").first?.kind, .text)
        XCTAssertEqual(model.messages(room: "family").first?.body, "hi")
    }

    static let jpegHead = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 0x4A, 0x46, 0x49, 0x46, 0x00])

    func testSendAttachmentRecordsOwnRowWithSniffedMime() async throws {
        let (model, relay) = await readyModel()
        let bytes = Self.jpegHead + Data(repeating: 7, count: 500)
        let outcome = await model.sendAttachment(room: "family", data: bytes)
        guard case .sent(let clientId, let seq, _)? = outcome else { return XCTFail("\(String(describing: outcome))") }
        XCTAssertTrue(AttachmentFormat.isAttachment(clientId: clientId))
        XCTAssertNil(model.lastError)
        let mine = model.messages(room: "family")
        XCTAssertEqual(mine.map(\.seq), [seq])
        XCTAssertEqual(mine.first?.kind, .attachment)
        XCTAssertEqual(mine.first?.body, "image/jpeg")
        XCTAssertEqual(mine.first?.attachment, bytes)
        XCTAssertEqual(mine.first?.senderDevice, "mom-iphone-a1b2c3")
        let page = try await relay.getEvents(room: "family", device: "mom-iphone-a1b2c3", after: 0, limit: 10, ack: nil)
        XCTAssertEqual(page.events.map(\.clientId), [clientId], "the relay row carries the file-v1 id")
    }

    func testOversizeAttachmentIsRefusedBeforeSending() async {
        let (model, relay) = await readyModel()
        let outcome = await model.sendAttachment(room: "family", data: Data(count: AttachmentFormat.maxBytes + 1))
        XCTAssertNil(outcome)
        XCTAssertEqual(model.lastError, Strings.attachmentTooLarge(AttachmentFormat.maxBytes + 1))
        let page = try? await relay.getEvents(room: "family", device: "mom-iphone-a1b2c3", after: 0, limit: 10, ack: nil)
        XCTAssertEqual(page?.events.count ?? 0, 0)
    }

    // MARK: 사진 축소

    private func bigImage(side: CGFloat) -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: side, height: side)).image { ctx in
            // 압축이 잘 안 되는 잡음 패턴 — 한도 초과를 확실히 만든다.
            for y in stride(from: 0, to: Int(side), by: 4) {
                for x in stride(from: 0, to: Int(side), by: 4) {
                    UIColor(red: CGFloat((x * 7) % 255) / 255, green: CGFloat((y * 13) % 255) / 255, blue: CGFloat((x ^ y) % 255) / 255, alpha: 1).setFill()
                    ctx.fill(CGRect(x: x, y: y, width: 4, height: 4))
                }
            }
        }
    }

    func testPreparePhotoShrinksALargeImageUnderTheLimitAsJPEG() throws {
        let raw = try XCTUnwrap(bigImage(side: 2400).pngData())
        XCTAssertGreaterThan(raw.count, AttachmentFormat.maxBytes, "fixture must exceed the limit")
        let prepared = try XCTUnwrap(AttachmentPreparer.preparePhoto(raw))
        XCTAssertLessThanOrEqual(prepared.count, AttachmentFormat.maxBytes)
        XCTAssertEqual(AttachmentFormat.sniffMime(prepared), "image/jpeg")
        XCTAssertNotNil(UIImage(data: prepared))
    }

    func testPreparePhotoKeepsASmallJPEGUntouched() {
        let small = Self.jpegHead + Data(repeating: 0, count: 100)
        XCTAssertEqual(AttachmentPreparer.preparePhoto(small), small, "no re-encode when already small and web-readable")
    }

    func testPreparePhotoRejectsGarbage() {
        XCTAssertNil(AttachmentPreparer.preparePhoto(Data(repeating: 0x42, count: AttachmentFormat.maxBytes + 10)))
    }

    func testPrepareFileOnlyChecksTheLimit() {
        XCTAssertEqual(AttachmentPreparer.prepareFile(Data(count: AttachmentFormat.maxBytes)), Data(count: AttachmentFormat.maxBytes))
        XCTAssertNil(AttachmentPreparer.prepareFile(Data(count: AttachmentFormat.maxBytes + 1)))
    }

    // MARK: 공유용 임시 파일

    func testTemporaryExportUsesWebNamingAndExtension() throws {
        let record = MessageRecord(room: "family", seq: 42, senderDevice: "dad-pc", clientId: AttachmentFormat.newClientId(), kind: .attachment,
                                   body: "application/pdf", attachment: Data("%PDF-1.7".utf8), receivedAt: Date(), decryptedBy: .app)
        let url = try XCTUnwrap(AttachmentExport.temporaryURL(for: record))
        XCTAssertEqual(url.lastPathComponent, "attachment-42.pdf")
        XCTAssertEqual(try Data(contentsOf: url), Data("%PDF-1.7".utf8))
        XCTAssertNil(AttachmentExport.temporaryURL(for: MessageRecord(room: "family", seq: 1, senderDevice: "dad-pc", clientId: "c", kind: .text,
                                                                        body: "hi", attachment: nil, receivedAt: Date(), decryptedBy: .app)))
    }
}
