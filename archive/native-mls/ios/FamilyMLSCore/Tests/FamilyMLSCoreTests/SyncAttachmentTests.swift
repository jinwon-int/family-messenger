// 첨부 송수신(AttachmentFormat + RoomSyncEngine.send(attachment:)) — 가짜 엔진·메모리 릴레이(SyncFakes.swift). 와이어 규칙은 relay-app 과 동일해야 한다.
import XCTest
@testable import FamilyMLSCore

final class SyncAttachmentTests: XCTestCase {
    let alice = "alice-pc"

    private func joinedHarness() throws -> SyncHarness {
        let h = try SyncHarness()
        try h.store.seed(room: h.room, .joined([alice, h.me].sorted(), epoch: 1, pending: nil))
        h.relay.epoch = 1
        h.relay.members = [alice, h.me]
        return h
    }

    /// 가짜 암호문(바이트 평문) — `SyncHarness.ciphertext(from:clientId:text:)` 의 Data 판.
    private func ciphertext(from sender: DeviceID, bytes: Data) -> Data {
        var plain = bytes; plain.append(0)
        return FakeMlsEngine.ciphertextMagic + Framing.encryptInput(room: sender, clientId: sender, plaintext: plain)
    }

    static let jpegHead = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 0x4A, 0x46, 0x49, 0x46, 0x00])

    // MARK: 형식

    func testClientIdRuleMatchesRelayApp() {
        let id = AttachmentFormat.newClientId(uuid: UUID(uuidString: "0F3C2A9B-1D2E-4F5A-8B6C-7D8E9FA0B1C2")!)
        XCTAssertEqual(id, "file-v1-0f3c2a9b-1d2e-4f5a-8b6c-7d8e9fa0b1c2", "lowercase uuid — the web regex is [a-f0-9-]")
        XCTAssertTrue(AttachmentFormat.isAttachment(clientId: id))
        XCTAssertFalse(AttachmentFormat.isAttachment(clientId: "file-v1-0F3C2A9B-1D2E-4F5A-8B6C-7D8E9FA0B1C2"), "uppercase is text to the web")
        XCTAssertFalse(AttachmentFormat.isAttachment(clientId: "file-v1-abc"))
        XCTAssertFalse(AttachmentFormat.isAttachment(clientId: "me-iphone-aaaaaa-c1"))
        XCTAssertFalse(AttachmentFormat.isAttachment(clientId: ""))
        XCTAssertEqual(id.count, 44, "fits the relay's 64-char client_id limit")
    }

    func testMimeSniffing() {
        XCTAssertEqual(AttachmentFormat.sniffMime(Self.jpegHead), "image/jpeg")
        XCTAssertEqual(AttachmentFormat.sniffMime(Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 1])), "image/png")
        XCTAssertEqual(AttachmentFormat.sniffMime(Data("GIF89a".utf8)), "image/gif")
        XCTAssertEqual(AttachmentFormat.sniffMime(Data([0x00, 0x00, 0x00, 0x18]) + Data("ftypheic".utf8) + Data(count: 4)), "image/heic")
        XCTAssertEqual(AttachmentFormat.sniffMime(Data([0x00, 0x00, 0x00, 0x18]) + Data("ftypisom".utf8) + Data(count: 4)), "video/mp4")
        XCTAssertEqual(AttachmentFormat.sniffMime(Data("%PDF-1.7".utf8)), "application/pdf")
        XCTAssertEqual(AttachmentFormat.sniffMime(Data("hello".utf8)), AttachmentFormat.fallbackMime)
        XCTAssertEqual(AttachmentFormat.sniffMime(Data()), AttachmentFormat.fallbackMime)
        XCTAssertTrue(AttachmentFormat.isImage(mime: "image/heic"))
        XCTAssertEqual(AttachmentFormat.fileExtension(mime: "image/jpeg"), "jpg")
        XCTAssertEqual(AttachmentFormat.fileExtension(mime: "x/y"), "bin")
    }

    // MARK: 송신

    func testSendAttachmentUsesFileV1ClientIdAndRawBytes() async throws {
        let h = try joinedHarness()
        let bytes = Self.jpegHead + Data(repeating: 0xAB, count: 1000)
        let outcome = try await h.sync.send(attachment: bytes)
        guard case .sent(let clientId, _, false) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertTrue(AttachmentFormat.isAttachment(clientId: clientId), clientId)
        XCTAssertEqual(h.relay.posts[0].clientId, clientId)
        XCTAssertEqual(h.relay.posts[0].kind, .application)
        // 가짜 암호문 = magic ‖ sender ‖ AAD client_id(기기 ID 그대로) ‖ 평문 ‖ generation
        let framed = Data(h.relay.posts[0].bytes.dropFirst(FakeMlsEngine.ciphertextMagic.count))
        var at = 0
        XCTAssertEqual(try Framing.readString(framed, &at), h.me)
        XCTAssertEqual(try Framing.readString(framed, &at), h.me, "AAD client_id stays the device id — the file-v1 id is relay-only")
        XCTAssertEqual(framed.subdata(in: at..<(framed.count - 1)), bytes, "raw file bytes, no envelope")
        XCTAssertEqual(try h.outbox.pending(room: h.room), [])
    }

    func testSendAttachmentRejectsOversizeBeforeEncrypting() async throws {
        let h = try joinedHarness()
        let big = Data(count: AttachmentFormat.maxBytes + 1)
        do { _ = try await h.sync.send(attachment: big); XCTFail("must refuse") }
        catch { XCTAssertEqual(error as? SyncError, .attachmentTooLarge(AttachmentFormat.maxBytes + 1)) }
        XCTAssertEqual(h.factory.log.count(.encrypt), 0, "no ratchet use for a refused attachment")
        XCTAssertEqual(h.relay.posts.count, 0)
        _ = try await h.sync.send(attachment: Data(count: AttachmentFormat.maxBytes))   // 정확히 한도는 허용
        XCTAssertEqual(h.relay.posts.count, 1)
    }

    func testCasRetryReencryptsWithAFreshFileV1Id() async throws {
        let h = try joinedHarness()
        h.relay.postErrors = [RelayError.cas(epoch: 2, revision: 1)]
        let outcome = try await h.sync.send(attachment: Self.jpegHead)
        guard case .sent(let second, _, _) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(h.relay.posts.count, 2)
        let first = h.relay.posts[0].clientId
        XCTAssertTrue(AttachmentFormat.isAttachment(clientId: first))
        XCTAssertTrue(AttachmentFormat.isAttachment(clientId: second))
        XCTAssertNotEqual(first, second, "a re-encryption is a new delivery — new relay id")
        XCTAssertEqual(try h.outbox.pending(room: h.room), [])
    }

    func testTextSendStillUsesTheDeviceClientId() async throws {
        let h = try joinedHarness()
        guard case .sent(let clientId, _, _) = try await h.sync.send(text: "hi") else { return XCTFail() }
        XCTAssertTrue(clientId.hasPrefix(h.me))
        XCTAssertFalse(AttachmentFormat.isAttachment(clientId: clientId))
    }

    // MARK: 수신

    func testIncomingFileV1EventIsStoredAsAttachmentWithSniffedMime() async throws {
        let h = try joinedHarness()
        let bytes = Self.jpegHead + Data(repeating: 1, count: 300)
        let seq = h.relay.inject(device: alice, kind: .application, bytes: ciphertext(from: alice, bytes: bytes),
                                 clientId: AttachmentFormat.newClientId())
        let pass = try await h.sync.syncOnce()
        XCTAssertEqual(pass.inserted, [seq])
        let stored = try XCTUnwrap(h.messages.messages(room: h.room, after: 0, limit: 10).first)
        XCTAssertEqual(stored.kind, .attachment)
        XCTAssertEqual(stored.body, "image/jpeg", "display meta = sniffed MIME (NSE shows 「사진」)")
        XCTAssertEqual(stored.attachment, bytes)
        XCTAssertEqual(stored.senderDevice, alice)
    }

    func testIncomingNonMatchingClientIdStaysText() async throws {
        let h = try joinedHarness()
        h.relay.inject(device: alice, kind: .application, bytes: ciphertext(from: alice, bytes: Data("hello".utf8)), clientId: "File-V1-not-really")
        _ = try await h.sync.syncOnce()
        let stored = try XCTUnwrap(h.messages.messages(room: h.room, after: 0, limit: 10).first)
        XCTAssertEqual(stored.kind, .text)
        XCTAssertEqual(stored.body, "hello")
        XCTAssertNil(stored.attachment)
    }

    func testIncomingAttachmentWithUnknownBytesIsOctetStream() async throws {
        let h = try joinedHarness()
        h.relay.inject(device: alice, kind: .application, bytes: ciphertext(from: alice, bytes: Data([0x00, 0x01, 0x02])),
                       clientId: AttachmentFormat.newClientId())
        _ = try await h.sync.syncOnce()
        let stored = try XCTUnwrap(h.messages.messages(room: h.room, after: 0, limit: 10).first)
        XCTAssertEqual(stored.kind, .attachment)
        XCTAssertEqual(stored.body, AttachmentFormat.fallbackMime)
        XCTAssertEqual(stored.attachment, Data([0x00, 0x01, 0x02]))
    }
}
