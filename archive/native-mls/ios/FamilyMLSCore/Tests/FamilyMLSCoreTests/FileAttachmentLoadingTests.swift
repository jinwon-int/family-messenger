// `AttachmentLoading`(#364) — FileSQLiteStore: 행 머리는 BLOB 없이 크기만, 본체는 seq 로 한 건.
import XCTest
@testable import FamilyMLSCore

final class FileAttachmentLoadingTests: XCTestCase {
    func testHeadsCarrySizesWithoutBlobsAndAttachmentReadsOneBody() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("fmatt-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = try FileSQLiteStore(directory: dir)
        let blob = Data(repeating: 0xC3, count: 300_000)
        try store.insert(MessageRecord(room: "r", seq: 1, senderDevice: "a-pc", clientId: "c1", kind: .text, body: "hi", attachment: nil,
                                       receivedAt: Date(), decryptedBy: .app))
        try store.insert(MessageRecord(room: "r", seq: 2, senderDevice: "a-pc", clientId: AttachmentFormat.newClientId(), kind: .attachment,
                                       body: "image/jpeg", attachment: blob, receivedAt: Date(), decryptedBy: .nse))
        let heads = try store.messageHeads(room: "r", after: 0, limit: 10)
        XCTAssertEqual(heads.map { $0.record.seq }, [1, 2])
        XCTAssertEqual(heads.map(\.attachmentBytes), [0, blob.count])
        XCTAssertTrue(heads.allSatisfy { $0.record.attachment == nil }, "no blob in the timeline read")
        XCTAssertEqual(heads[1].record.body, "image/jpeg")
        XCTAssertEqual(heads[1].record.decryptedBy, .nse)
        XCTAssertEqual(try store.attachment(room: "r", seq: 2), blob)
        XCTAssertNil(try store.attachment(room: "r", seq: 1), "text rows have no body")
        XCTAssertNil(try store.attachment(room: "r", seq: 9))
        XCTAssertEqual(try store.messages(room: "r", after: 0, limit: 10)[1].attachment, blob, "the frozen MessageStore read is unchanged")
        try? FileManager.default.removeItem(at: dir)
    }
}
