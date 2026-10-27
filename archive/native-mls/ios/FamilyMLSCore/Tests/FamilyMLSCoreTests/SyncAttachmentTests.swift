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

    // MARK: NSE 보호 — 큰 application 은 커서 앞에서 멈춘다(#364)

    func testApplicationOverTheProcessCapIsDeferredAndLeftForAnUncappedCaller() async throws {
        let h = try joinedHarness()
        let small = h.relay.inject(device: alice, kind: .application, bytes: ciphertext(from: alice, bytes: Data("hi".utf8)))
        let bigBytes = ciphertext(from: alice, bytes: Data(repeating: 0xAA, count: 4_000))
        let big = h.relay.inject(device: alice, kind: .application, bytes: bigBytes, clientId: AttachmentFormat.newClientId())
        let after = h.relay.inject(device: alice, kind: .application, bytes: ciphertext(from: alice, bytes: Data("later".utf8)))

        h.configuration.maxApplicationBytes = 1_000     // NSE 와 같은 캡
        let capped = try h.restart()
        let passes = try await capped.syncAll()
        XCTAssertEqual(passes.count, 1, "syncAll stops at the deferral")
        XCTAssertEqual(passes[0].deferredSeq, big)
        XCTAssertEqual(passes[0].inserted, [small], "everything before the big event is processed")
        XCTAssertEqual(passes[0].cursor, small, "the cursor stays right before the deferred event")
        XCTAssertFalse(passes[0].hasMore)
        XCTAssertEqual(try h.cursors.cursor(room: h.room), small)
        XCTAssertEqual(try h.messages.messages(room: h.room, after: 0, limit: 10).map(\.seq), [small])
        // 같은 캡으로 다시 돌려도 같은 자리에서 멈춘다(무한 루프·중복 없음).
        let again = try await capped.syncOnce()
        XCTAssertEqual(again.deferredSeq, big)
        XCTAssertEqual(again.inserted, [])

        h.configuration.maxApplicationBytes = nil       // 앱: 제한 없음 → 이어서 처리
        let app = try h.restart()
        let rest = try await app.syncAll()
        XCTAssertEqual(rest.flatMap(\.inserted), [big, after])
        XCTAssertEqual(try h.cursors.cursor(room: h.room), after)
        let stored = try h.messages.messages(room: h.room, after: 0, limit: 10)
        XCTAssertEqual(stored.map(\.seq), [small, big, after])
        XCTAssertEqual(stored[1].kind, .attachment)
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

    // MARK: 송신 — file-v2(#499 3단계)

    #if os(Linux) || !canImport(CryptoKit)
    /// Linux(AES 없음): 업로드·암호화(ratchet) 전에 멈춘다 — 설명자 없는 게시나 반쯤 보낸 상태가 생기지 않는다.
    func testFileV2SendStopsBeforeUploadWithoutCryptoKit() async throws {
        let h = try joinedHarness()
        do { _ = try await h.sync.send(fileV2: Self.jpegHead); XCTFail("must throw") }
        catch { XCTAssertEqual(error as? FileV2Format.OpenError, .unsupported) }
        XCTAssertEqual(h.relay.posts.count, 0)
        XCTAssertEqual(h.factory.log.count(.encrypt), 0)
    }
    #endif

    func testFileV2SendRefusesOversizeBeforeAnything() async throws {
        let h = try joinedHarness()
        do { _ = try await h.sync.send(fileV2: Data()); XCTFail("empty") }
        catch { XCTAssertEqual(error as? SyncError, .attachmentTooLarge(0)) }
        XCTAssertEqual(h.relay.posts.count, 0)
        XCTAssertEqual(h.factory.log.count(.encrypt), 0)
    }

    // MARK: 수신 — file-v2(#499): 설명자(파일 키)는 어떤 경우에도 .text 로 저장되지 않는다

    func testIncomingFileV2IsStoredAsDescriptorNeverText() async throws {
        let h = try joinedHarness()
        let descriptor = Data(FileV2FormatTests.desc(#","mime":"image/jpeg","name":"사진.jpg""#).utf8)
        let seq = h.relay.inject(device: alice, kind: .application, bytes: ciphertext(from: alice, bytes: descriptor),
                                 clientId: FileV2FormatTests.clientId)
        let pass = try await h.sync.syncOnce()
        XCTAssertEqual(pass.inserted, [seq])
        let stored = try XCTUnwrap(h.messages.messages(room: h.room, after: 0, limit: 10).first)
        XCTAssertEqual(stored.kind, .fileV2)
        XCTAssertEqual(stored.body, "image/jpeg", "display hint only — never the descriptor JSON")
        XCTAssertFalse(stored.body.contains(FileV2FormatTests.key))
        XCTAssertEqual(stored.attachment, descriptor, "history keeps the descriptor only (FILE-V2.md §4-2)")
        XCTAssertEqual(stored.clientId, FileV2FormatTests.clientId)
        XCTAssertEqual(stored.senderDevice, alice)
    }

    func testIncomingFileV2WithoutMimeHasEmptyBody() async throws {
        let h = try joinedHarness()
        h.relay.inject(device: alice, kind: .application, bytes: ciphertext(from: alice, bytes: Data(FileV2FormatTests.minimal.utf8)),
                       clientId: FileV2FormatTests.clientId)
        _ = try await h.sync.syncOnce()
        let stored = try XCTUnwrap(h.messages.messages(room: h.room, after: 0, limit: 10).first)
        XCTAssertEqual(stored.kind, .fileV2)
        XCTAssertEqual(stored.body, "")
    }

    func testIncomingBadFileV2IsUndecryptableAndDropsThePlaintext() async throws {
        let h = try joinedHarness()
        let cases: [(String, String)] = [
            (FileV2FormatTests.clientId, FileV2FormatTests.minimal.replacingOccurrences(of: #""v":2"#, with: #""v":3"#)),
            (FileV2FormatTests.clientId, "hello \(FileV2FormatTests.key)"),
            ("file-v2-not-a-uuid", FileV2FormatTests.minimal),   // 접두는 맞지만 정규형이 아님 — 글로 열지 않는다
        ]
        var seqs: [Int64] = []
        for (clientId, text) in cases {
            seqs.append(h.relay.inject(device: alice, kind: .application, bytes: ciphertext(from: alice, bytes: Data(text.utf8)), clientId: clientId))
        }
        let pass = try await h.sync.syncOnce()
        XCTAssertEqual(pass.inserted, seqs, "decryption succeeded — the pass still advances (ack)")
        let stored = try h.messages.messages(room: h.room, after: 0, limit: 10)
        XCTAssertEqual(stored.map(\.kind), [.undecryptable, .undecryptable, .undecryptable])
        for record in stored {
            XCTAssertEqual(record.body, "file_v2_descriptor")
            XCTAssertNil(record.attachment)
            XCTAssertFalse(record.body.contains(FileV2FormatTests.key))
        }
    }
}
