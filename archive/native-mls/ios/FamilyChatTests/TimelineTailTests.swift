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
            engineFactory: MemberFakeFactory(), stateStore: InMemoryStateStore(), messageStore: store,
            outbox: InMemoryOutboxStore(), cursors: InMemoryCursorStore(),
            identityProvider: { "mom-iphone-a1b2c3" }, expectedDecryptFormat: { 2 }, makeTransport: { _ in relay })
        let model = AppModel(dependencies: deps)

        let items = model.messages(room: "family")
        XCTAssertEqual(items.count, AppModel.timelineLimit)
        XCTAssertEqual(items.last?.record.seq, Int64(AppModel.timelineLimit) + 3, "the newest message is on screen")
        XCTAssertEqual(items.first?.record.seq, 4, "only the oldest rows fall out of the window")
        XCTAssertEqual(items.map(\.record.seq), items.map(\.record.seq).sorted())
    }

    /// #472: 위로 읽으면 창이 한 페이지씩 넓어져 과거 글이 앞에 붙고, 가장 오래된 행까지 올리면 더 읽지 않는다. 방을 나가면 기본 창.
    func testLoadOlderGrowsTheWindowUntilTheOldestRow() throws {
        let store = InMemoryMessageStore()
        let total: Int64 = 1_200
        for seq in Int64(1)...total {
            try store.insert(MessageRecord(room: "family", seq: seq, senderDevice: "mom-iphone-a1b2c3", clientId: "c\(seq)", kind: .text,
                                           body: "m\(seq)", attachment: nil, receivedAt: Date(), decryptedBy: .app))
        }
        let relay = InMemoryRelay()
        let deps = AppModel.Dependencies(
            engineFactory: MemberFakeFactory(), stateStore: InMemoryStateStore(), messageStore: store,
            outbox: InMemoryOutboxStore(), cursors: InMemoryCursorStore(),
            identityProvider: { "mom-iphone-a1b2c3" }, expectedDecryptFormat: { 2 }, makeTransport: { _ in relay })
        let model = AppModel(dependencies: deps)

        XCTAssertTrue(model.canLoadOlder(room: "family"), "unread room: assume there may be more")
        var items = model.messages(room: "family")
        XCTAssertEqual(items.count, AppModel.timelineLimit)
        XCTAssertEqual(items.first?.record.seq, total - Int64(AppModel.timelineLimit) + 1)
        XCTAssertTrue(model.canLoadOlder(room: "family"))

        XCTAssertTrue(model.loadOlder(room: "family"))
        items = model.messages(room: "family")
        XCTAssertEqual(items.count, AppModel.timelineLimit + AppModel.olderPage, "one more page on top")
        XCTAssertEqual(items.last?.record.seq, total, "the newest row stays")
        XCTAssertEqual(items.map(\.record.seq), items.map(\.record.seq).sorted())

        var pages = 1
        while model.loadOlder(room: "family") {
            items = model.messages(room: "family")
            pages += 1
            XCTAssertLessThan(pages, 20, "must reach the oldest row")
        }
        XCTAssertEqual(items.count, Int(total), "every row is on the timeline")
        XCTAssertEqual(items.first?.record.seq, 1)
        XCTAssertFalse(model.canLoadOlder(room: "family"), "the oldest row is shown — nothing more to read")
        XCTAssertFalse(model.loadOlder(room: "family"), "idempotent at the end")

        model.resetTimelineWindow(room: "family")
        XCTAssertTrue(model.canLoadOlder(room: "family"))
        XCTAssertEqual(model.messages(room: "family").count, AppModel.timelineLimit, "leaving the room restores the default window")
    }

    /// #497 후속: 스크롤 결정은 진단 기록에 `scroll ` 접두로 남되, 한꺼번에 튀어도 `scrollNoteWindow` 초에 `scrollNoteBudget` 줄까지만
    /// (+ 억제 표시 1줄) — 동기화 기록을 밀어내지 않는다. 창이 지나면 다시 적는다.
    func testScrollNotesAreRateLimited() throws {
        let relay = InMemoryRelay()
        let deps = AppModel.Dependencies(
            engineFactory: MemberFakeFactory(), stateStore: InMemoryStateStore(), messageStore: InMemoryMessageStore(),
            outbox: InMemoryOutboxStore(), cursors: InMemoryCursorStore(),
            identityProvider: { "mom-iphone-a1b2c3" }, expectedDecryptFormat: { 2 }, makeTransport: { _ in relay })
        let model = AppModel(dependencies: deps)
        let t0 = Date()
        for i in 0..<(AppModel.scrollNoteBudget + 10) { model.noteScroll("family correct #\(i)", now: t0) }
        let burst = model.diagnostics.filter { $0.contains(" scroll ") }
        XCTAssertEqual(burst.count, AppModel.scrollNoteBudget + 1, "budget lines + one suppression marker")
        XCTAssertTrue(burst.last?.contains("억제") == true)
        model.noteScroll("family past-end", now: t0.addingTimeInterval(AppModel.scrollNoteWindow + 1))
        XCTAssertTrue(model.diagnostics.last?.hasSuffix("scroll family past-end") == true, "a new window records again")
        XCTAssertTrue(model.diagnosticsReport().contains("scroll family past-end"), "the copied report includes scroll lines")
    }

    /// 창보다 적은 방은 처음부터 끝에 닿은 것으로 본다(위로 올라가도 읽기 시도 없음).
    func testSmallRoomIsExhaustedAfterTheFirstRead() throws {
        let store = InMemoryMessageStore()
        for seq in Int64(1)...3 {
            try store.insert(MessageRecord(room: "r", seq: seq, senderDevice: "mom-iphone-a1b2c3", clientId: "c\(seq)", kind: .text,
                                           body: "m\(seq)", attachment: nil, receivedAt: Date(), decryptedBy: .app))
        }
        let relay = InMemoryRelay()
        let deps = AppModel.Dependencies(
            engineFactory: MemberFakeFactory(), stateStore: InMemoryStateStore(), messageStore: store,
            outbox: InMemoryOutboxStore(), cursors: InMemoryCursorStore(),
            identityProvider: { "mom-iphone-a1b2c3" }, expectedDecryptFormat: { 2 }, makeTransport: { _ in relay })
        let model = AppModel(dependencies: deps)
        XCTAssertEqual(model.messages(room: "r").count, 3)
        XCTAssertFalse(model.canLoadOlder(room: "r"))
        XCTAssertFalse(model.loadOlder(room: "r"))
    }
}
