// #469 — 방 메시지가 500건을 넘어도 타임라인은 **최신** 500건을 보여야 한다(내가 방금 보낸 글이 사라지지 않는다).
import XCTest
import FamilyMLSCore
@testable import FamilyChat

@MainActor
final class TimelineTailTests: XCTestCase {
    func testTimelineShowsTheNewestWindowNotTheOldest() throws {
        let store = InMemoryMessageStore()
        for seq in Int64(1)...(Int64(AppModel.timelineLimit) + 3) {
            try store.insert(MessageRecord(room: "family", seq: seq, senderDevice: "mom-iphone-a1b2c3", clientId: "c\(seq)", kind: .text,
                                           body: "m\(seq)", attachment: nil, receivedAt: Date(), decryptedBy: .app))
        }
        let relay = InMemoryRelay()
        let deps = AppModel.Dependencies(
            engineFactory: AnyFactory(MemberFakeFactory()), stateStore: InMemoryStateStore(), messageStore: store,
            outbox: InMemoryOutboxStore(), cursors: InMemoryCursorStore(),
            identityProvider: { "mom-iphone-a1b2c3" }, expectedDecryptFormat: { 2 }, makeTransport: { _ in relay })
        let model = AppModel(dependencies: deps)

        let items = model.messages(room: "family")
        XCTAssertEqual(items.count, AppModel.timelineLimit)
        XCTAssertEqual(items.last?.record.seq, Int64(AppModel.timelineLimit) + 3, "the newest message is on screen")
        XCTAssertEqual(items.first?.record.seq, 4, "only the oldest rows fall out of the window")
        XCTAssertEqual(items.map(\.record.seq), items.map(\.record.seq).sorted())
    }
}
