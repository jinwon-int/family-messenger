// #520 — 잠금화면 본문 노출 없음(#243 2-c 기준 「나」, 설계 B). NSE 카테고리·등록 카테고리·미리보기 판정·모델 갱신.
// 실제 잠금화면 표시는 기기 설정(미리보기)·Face ID 인증 여부에 달려 있어 여기서는 볼 수 없다 — 실기기 묶음 측정(#520 항목 1)이 맡는다.
import XCTest
import UserNotifications
import FamilyMLSCore
@testable import FamilyChat

@MainActor
final class LockScreenPreviewTests: XCTestCase {

    // MARK: - NSE 내용 쓰기(NotificationService.apply 가 부르는 같은 코드)

    /// 복호화 결과: 제목·본문은 그대로(잠금 해제 배너 「본문 10/10」 유지) + 카테고리.
    func testDecryptedContentKeepsBodyAndGetsCategory() {
        let content = UNMutableNotificationContent()
        let result = ProcessedNotification(title: "진원", body: "저녁 먹자", outcome: .decrypted(seq: 79))
        NotificationContentWriter.apply(result, to: content)
        XCTAssertEqual(content.title, "진원")
        XCTAssertEqual(content.body, "저녁 먹자")
        XCTAssertEqual(content.categoryIdentifier, NotificationCategory.message)
    }

    /// 대체 알림(시작 직후·기한·실패)도 같은 카테고리 — 어느 경로든 잠금 상태 규칙이 같다.
    func testFallbackContentGetsCategoryToo() {
        let content = UNMutableNotificationContent()
        NotificationContentWriter.apply(.fallback("initial"), to: content)
        XCTAssertEqual(content.body, Strings.pushFallbackBody)
        XCTAssertEqual(content.categoryIdentifier, NotificationCategory.message)
    }

    // MARK: - 앱이 등록하는 카테고리

    /// 숨김 일반 문구 = 「새 메시지」, 제목(보낸 사람)도 숨김(`hiddenPreviewsShowTitle` 없음), 동작 버튼 없음.
    func testRegisteredCategoryHidesBodyAndTitleWhenPreviewsHidden() {
        let category = NotificationCategory.messageCategory()
        XCTAssertEqual(category.identifier, NotificationCategory.message)
        XCTAssertEqual(category.hiddenPreviewsBodyPlaceholder, Strings.pushHiddenPreviewPlaceholder)
        XCTAssertFalse(category.options.contains(.hiddenPreviewsShowTitle))
        XCTAssertFalse(category.options.contains(.hiddenPreviewsShowSubtitle))
        XCTAssertTrue(category.actions.isEmpty)
        XCTAssertNotEqual(Strings.pushHiddenPreviewPlaceholder, Strings.pushFallbackBody,
                          "잠금 숨김 문구와 NSE 실패 대체 문구는 구별된다(해제 후 진단)")
    }

    // MARK: - 미리보기 판정

    func testClassifyMatrix() {
        typealias P = LockScreenPreview.Previews
        XCTAssertEqual(LockScreenPreview.classify(authorized: true, lockScreenEnabled: true, previews: .always), .always)
        XCTAssertEqual(LockScreenPreview.classify(authorized: true, lockScreenEnabled: true, previews: .whenUnlocked), .whenUnlocked)
        XCTAssertEqual(LockScreenPreview.classify(authorized: true, lockScreenEnabled: true, previews: .never), .never)
        XCTAssertEqual(LockScreenPreview.classify(authorized: true, lockScreenEnabled: true, previews: .unknown), .unknown)
        // 권한 없음·잠금화면 꺼짐이 먼저 — 미리보기 「항상」이어도 잠금화면에는 아무것도 없다.
        for previews in [P.always, .whenUnlocked, .never, .unknown] {
            XCTAssertEqual(LockScreenPreview.classify(authorized: false, lockScreenEnabled: true, previews: previews), .off)
            XCTAssertEqual(LockScreenPreview.classify(authorized: true, lockScreenEnabled: false, previews: previews), .off)
        }
    }

    func testOnlyAlwaysWarns() {
        XCTAssertTrue(LockScreenPreview.always.needsWarning)
        for value in [LockScreenPreview.unknown, .off, .whenUnlocked, .never] {
            XCTAssertFalse(value.needsWarning, "\(value)")
        }
    }

    func testSettingsLabelsAreDistinct() {
        let all: [LockScreenPreview] = [.unknown, .off, .whenUnlocked, .never, .always]
        XCTAssertEqual(Set(all.map(Strings.lockPreview)).count, all.count, "측정 기록에 쓰이므로 값마다 문구가 달라야 한다")
    }

    // MARK: - 모델 갱신

    private func makeModel(reading values: [LockScreenPreview]) -> (AppModel, () -> Int) {
        var queue = values
        var reads = 0
        var deps = AppModel.Dependencies(
            engineFactory: FakeFactory(), stateStore: InMemoryStateStore(), messageStore: InMemoryMessageStore(),
            outbox: InMemoryOutboxStore(), cursors: InMemoryCursorStore(),
            identityProvider: { "owner-iphone-abc123" }, expectedDecryptFormat: { 2 },
            makeTransport: { _ in nil })
        deps.lockScreenPreview = {
            reads += 1
            return queue.isEmpty ? .unknown : queue.removeFirst()
        }
        return (AppModel(dependencies: deps), { reads })
    }

    /// 시작 전 = 모름. 읽으면 반영, 전면 복귀(설정 앱에서 바꾸고 돌아옴)에 다시 읽는다.
    func testModelReadsPreviewAtStartAndOnForeground() async {
        let (model, reads) = makeModel(reading: [.always, .whenUnlocked])
        XCTAssertEqual(model.lockScreenPreview, .unknown)

        await model.refreshLockScreenPreview()
        XCTAssertEqual(model.lockScreenPreview, .always)
        XCTAssertTrue(model.lockScreenPreview.needsWarning)

        await model.foregrounded()
        XCTAssertEqual(model.lockScreenPreview, .whenUnlocked)
        XCTAssertFalse(model.lockScreenPreview.needsWarning)
        XCTAssertEqual(reads(), 2)
    }
}
