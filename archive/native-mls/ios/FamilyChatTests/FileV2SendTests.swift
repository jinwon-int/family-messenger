// file-v2 송신(#499 3단계, FILE-V2.md §3) — AppModel(스위치 켬) → RoomSyncEngine.send(fileV2:) → blob 업로드 + 설명자 게시.
// 내 기록은 .fileV2(설명자만), 화면은 다른 기기와 같이 blob 을 받아 연다. 스위치 기본값은 꺼짐(v1 그대로).
import XCTest
import FamilyMLSCore
@testable import FamilyChat

@MainActor
final class FileV2SendTests: XCTestCase {
    static let jpeg = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 0x4A, 0x46, 0x49, 0x46, 0x00]) + Data(repeating: 9, count: 4000)

    private func readyModel(sendFileV2: Bool) async -> (AppModel, InMemoryRelay, InMemoryMessageStore) {
        let relay = InMemoryRelay()
        let messages = InMemoryMessageStore()
        var deps = AppModel.Dependencies(
            engineFactory: MemberFakeFactory(), stateStore: InMemoryStateStore(), messageStore: messages,
            outbox: InMemoryOutboxStore(), cursors: InMemoryCursorStore(),
            identityProvider: { "mom-iphone-a1b2c3" }, expectedDecryptFormat: { 2 }, makeTransport: { _ in relay })
        deps.sendFileV2 = sendFileV2
        let model = AppModel(dependencies: deps)
        await model.bootstrap(); model.login(.bearer("t")); await model.refresh()
        XCTAssertEqual(model.phase, .ready)
        return (model, relay, messages)
    }

    func testSwitchDefaultsOff() async {
        XCTAssertFalse(FileV2Format.sendDefault, "stage 3 ships off — flip only after every device receives v2")
        let (model, relay, _) = await readyModel(sendFileV2: FileV2Format.sendDefault)
        guard case .sent(let clientId, _, _)? = await model.sendAttachment(room: "family", data: Self.jpeg) else { return XCTFail() }
        XCTAssertTrue(AttachmentFormat.isAttachment(clientId: clientId), "v1 while the switch is off")
        XCTAssertEqual(relay.blobPosts, 0)
    }

    func testSendsBlobThenDescriptorAndRecordsOnlyTheDescriptor() async throws {
        let (model, relay, messages) = await readyModel(sendFileV2: true)
        let outcome = await model.sendAttachment(room: "family", data: Self.jpeg)
        guard case .sent(let clientId, let seq, _)? = outcome else { return XCTFail("\(String(describing: outcome)) \(String(describing: model.lastError))") }
        XCTAssertTrue(FileV2Format.isClientId(clientId), clientId)
        XCTAssertEqual(relay.blobPosts, 1)
        XCTAssertNil(model.lastError)
        // 내 기록: .fileV2, body = 내용으로 정한 MIME, attachment = 설명자(원본 바이트가 아니다).
        let row = try XCTUnwrap(messages.messages(room: "family", after: 0, limit: 10).first { $0.seq == seq })
        XCTAssertEqual(row.kind, .fileV2)
        XCTAssertEqual(row.body, "image/jpeg")
        XCTAssertNotEqual(row.attachment, Self.jpeg)
        let descriptor = try FileV2Format.parseDescriptor(try XCTUnwrap(row.attachment))
        XCTAssertEqual(descriptor.size, Self.jpeg.count)
        XCTAssertEqual(descriptor.mime, "image/jpeg")
        // 다른 기기와 같은 길로 열린다: blob GET → sha256 → GCM.
        let opened = try await model.fileV2Bytes(room: "family", seq: seq)
        XCTAssertEqual(opened, Self.jpeg)
        let page = try await relay.getEvents(room: "family", device: "mom-iphone-a1b2c3", after: 0, limit: 10, ack: nil)
        XCTAssertEqual(page.events.map(\.clientId), [clientId], "the relay row carries the file-v2 id")
        XCTAssertEqual(model.messages(room: "family").first?.record.kind, .fileV2)
    }

    func testUploadFailureSendsNothingAndCanBeRetried() async throws {
        let (model, relay, _) = await readyModel(sendFileV2: true)
        relay.failNextBlobPosts([RelayError.refused(code: "room_bytes_cap", status: 413)])
        let outcome = await model.sendAttachment(room: "family", data: Self.jpeg)
        XCTAssertNil(outcome)
        let page = try await relay.getEvents(room: "family", device: "mom-iphone-a1b2c3", after: 0, limit: 10, ack: nil)
        XCTAssertEqual(page.events.count, 0, "no descriptor without a stored blob")
        let failed = try XCTUnwrap(model.messages(room: "family").last)
        XCTAssertEqual(failed.record.kind, .fileV2)
        guard case .failed? = failed.outgoing else { return XCTFail("\(String(describing: failed.outgoing))") }
        await model.retry(outgoingId: failed.id, room: "family")
        XCTAssertEqual(relay.blobPosts, 2)
        let after = try await relay.getEvents(room: "family", device: "mom-iphone-a1b2c3", after: 0, limit: 10, ack: nil)
        XCTAssertEqual(after.events.count, 1)
        XCTAssertTrue(FileV2Format.isClientId(after.events[0].clientId))
        XCTAssertEqual(model.messages(room: "family").filter { $0.outgoing != nil }.count, 0)
    }

    func testOversizeIsRefusedBeforeUpload() async {
        let (model, relay, _) = await readyModel(sendFileV2: true)
        let refused = await model.sendAttachment(room: "family", data: Data(count: FileV2Format.maxFileBytes + 1))
        XCTAssertNil(refused)
        XCTAssertEqual(model.lastError, Strings.attachmentTooLarge(FileV2Format.maxFileBytes + 1))
        XCTAssertEqual(relay.blobPosts, 0)
    }

    func testSealProducesAnOpenableBlob() throws {
        let sealed = try FileV2Format.seal(Self.jpeg)
        XCTAssertEqual(sealed.ciphertext.count, Self.jpeg.count + FileV2Format.gcmTagBytes)
        XCTAssertFalse("\(sealed)".contains(FileV2Format.base64urlEncode(sealed.key)))
        let descriptor = try FileV2Format.parseDescriptor(try FileV2Format.encodeDescriptor(
            blob: sealed.blob, size: sealed.size, key: sealed.key, nonce: sealed.nonce, mime: "image/jpeg", name: "사진 \"1\".jpg"))
        XCTAssertEqual(descriptor.name, "사진 \"1\".jpg")
        XCTAssertEqual(try FileV2Format.open(sealed.ciphertext, descriptor), Self.jpeg)
        let again = try FileV2Format.seal(Self.jpeg)
        XCTAssertNotEqual(again.key, sealed.key, "fresh key per file")
        XCTAssertNotEqual(again.blob, sealed.blob)
    }
}
