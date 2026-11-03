// #666 공유 시트 맨 윗줄 대화 추천 — 앱이 언제 무엇을 기부·삭제하는지(Intents 자체는 부르지 않는다, 기록기 도너).
import XCTest
import FamilyMLSCore
@testable import FamilyChat

@MainActor
final class ShareSuggestionTests: XCTestCase {
    private final class Recorder {
        var donated: [(conversation: String, title: String)] = []
        var deleted: [[String]] = []
        var deletedAll = 0
        var donor: ShareSuggestionDonor {
            ShareSuggestionDonor(donate: { [unowned self] c, t in self.donated.append((c, t)) },
                                 delete: { [unowned self] in self.deleted.append($0) },
                                 deleteAll: { [unowned self] in self.deletedAll += 1 })
        }
    }

    private let scope = ServerScope(baseURL: ServerSelection.testing.baseURL).id

    private func readyModel(_ recorder: Recorder) async -> (AppModel, InMemoryRelay, InMemoryMessageStore) {
        let relay = InMemoryRelay()
        let messages = InMemoryMessageStore(seedRooms: [
            RoomRecord(room: "family", epoch: 0, revision: 0, haltedReason: nil, displayOrder: 0),
            RoomRecord(room: "jingun", epoch: 0, revision: 0, haltedReason: nil, displayOrder: 1),
        ])
        var deps = AppModel.Dependencies(
            engineFactory: MemberFakeFactory(), stateStore: InMemoryStateStore(), messageStore: messages,
            outbox: InMemoryOutboxStore(), cursors: InMemoryCursorStore(),
            identityProvider: { "mom-iphone-a1b2c3" }, expectedDecryptFormat: { 2 }, makeTransport: { _ in relay })
        deps.shareSuggestions = recorder.donor
        let model = AppModel(dependencies: deps)
        await model.bootstrap(); model.login(.bearer("t")); await model.refresh()
        XCTAssertEqual(model.phase, .ready)
        return (model, relay, messages)
    }

    func testOpeningARoomDonatesItUnderTheScopedIdentifierWithTheScreenName() async {
        let recorder = Recorder()
        let (model, _, _) = await readyModel(recorder)

        model.roomShown("family")

        XCTAssertEqual(recorder.donated.map(\.conversation), ["\(scope)/family"])
        XCTAssertEqual(recorder.donated.map(\.title), [Strings.roomLabel("family")])
        XCTAssertEqual(ShareSuggestions.room(conversation: recorder.donated[0].conversation, scope: scope), "family",
                       "확장이 같은 규칙으로 되돌린다")
    }

    func testSendingDonatesTheRoomAgain() async {
        let recorder = Recorder()
        let (model, _, _) = await readyModel(recorder)

        guard case .sent? = await model.send(room: "family", text: "hi") else { return XCTFail("\(String(describing: model.lastError))") }

        XCTAssertEqual(recorder.donated.map(\.conversation), ["\(scope)/family"])
    }

    func testARoomThatIsNoLongerShareableIsNotDonatedAndIsDeleted() async throws {
        let recorder = Recorder()
        let (model, _, messages) = await readyModel(recorder)

        try messages.setHalted(room: "jingun", reason: "removed_from_room")
        await model.refresh()   // 방 목록 다시 읽기 → 공유 대상에서 빠짐 → 추천에서 내림
        model.roomShown("jingun")

        XCTAssertTrue(recorder.deleted.contains(["\(scope)/jingun"]), "\(recorder.deleted)")
        XCTAssertTrue(recorder.donated.isEmpty, "정지된 방은 올리지 않는다")
    }

    func testChangingTheServerDeletesEverySuggestion() async {
        let recorder = Recorder()
        let (model, _, _) = await readyModel(recorder)

        await model.changeServer()

        XCTAssertEqual(recorder.deletedAll, 1)
        XCTAssertEqual(model.phase, .needsServer)
    }
}
