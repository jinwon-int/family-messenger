// 사진 보기 실제 터치 회귀(#844, 오너 2026-11-19 「상대가 보낸 사진을 누르면 검은 화면이 뜨고 닫을 수 없다 — 어느 때는 보인다」).
// 재현 화면(`PhotoViewerHarness`, DEBUG 실행 인자 `-photoViewerHarness`)에서 실제 `MessageRow`·`AttachmentBubble` 의 사진을 누른다.
// 재현 화면의 모델은 부트스트랩하지 않아 아무것도 알리지 않는다 — 바퀴 사이 `/v2/watch` 를 기다리는 실제 앱과 같은 「조용한」 상태(#763).
//
// 조사 기록(#844): 종전 코드는 커버 내용이 `body` 가 읽지 않는 상태(`viewerImage`)에 달려 있어, 누른 직후 커버가 옛 값(nil)으로
// 비어(검은 화면) 뜨고 닫을 수단이 없었다. 모델이 알려 `body` 가 다시 계산돼야 사진이 들어왔다 — 4초 폴링 때는 수 초, watch 대기 때는 최대 25초.
// 아래는 `[photo]` 줄로 「조용한 동안 떴나 · 누른 뒤 썸네일이 가려졌나(=커버는 떴나) · 모델 알림 뒤 떴나」를 남긴다.
import XCTest

final class PhotoViewerUITests: XCTestCase {
    /// 재현 화면이 준비되고 이만큼 뒤에 모델 알림을 한 번 낸다 — 누르기·조용한 동안 판정(아래 `quietWindow`)이 그 전에 끝나야 한다.
    private static let publishAfter: TimeInterval = 20
    /// 모델 알림 없이 사진 보기가 떠야 하는 시간.
    private static let quietWindow: TimeInterval = 5

    override func setUp() {
        continueAfterFailure = true
    }

    /// 사진 보기(`ZoomableImageView` 의 스크롤 뷰·이미지 뷰, `ImageViewer` 의 공유 단추) — 식별자가 `photo-viewer` 로 시작한다.
    private func viewer(_ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "photo-viewer")).firstMatch
    }

    /// 말풍선의 사진 썸네일(접근성 이름 「사진」).
    private func thumbnail(_ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "사진")).firstMatch
    }

    private func waitGone(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: element)
        return XCTWaiter().wait(for: [gone], timeout: timeout) == .completed
    }

    /// 화면 가운데를 한 번 탭해 닫는다(사진 보기의 닫기 = 한 번 탭, #453).
    private func tapToClose(_ app: XCUIApplication) {
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
    }

    func testPhotoTapShowsViewerWhileModelIsQuiet() {
        let app = XCUIApplication()
        app.launchArguments = ["-photoViewerHarness", "-photoViewerPublishAfter", String(Int(Self.publishAfter))]
        app.launch()
        let thumb = thumbnail(app)
        XCTAssertTrue(thumb.waitForExistence(timeout: 15), "harness thumbnail did not appear")
        let readyState = app.staticTexts["harness-state"].label

        let tappedAt = Date()
        thumb.tap()
        let shownQuiet = viewer(app).waitForExistence(timeout: Self.quietWindow)
        let quietSeconds = Date().timeIntervalSince(tappedAt)
        // 커버가 뜨면 밑의 화면은 접근성 트리에서 빠진다 — 사진 보기는 없는데 썸네일도 없으면 「빈 커버」가 떠 있는 것이다.
        let thumbnailStillThere = thumbnail(app).exists
        var shownAfterPublish = shownQuiet
        if !shownQuiet {
            shownAfterPublish = viewer(app).waitForExistence(timeout: Self.publishAfter + 10)
        }
        let shownSeconds = Date().timeIntervalSince(tappedAt)
        print("[photo] state=\(readyState) quiet-shown=\(shownQuiet) quiet-wait=\(String(format: "%.1f", quietSeconds))s "
              + "thumbnail-under-cover-exists=\(thumbnailStillThere) shown-after-model-publish=\(shownAfterPublish) "
              + "shown-at=\(String(format: "%.1f", shownSeconds))s publish-after=\(Int(Self.publishAfter))s")
        XCTAssertTrue(shownQuiet, "photo viewer did not appear within \(Int(Self.quietWindow)) s of the tap while the model was quiet "
                      + "(blank cover: thumbnail-under-cover-exists=\(thumbnailStillThere), shown-after-model-publish=\(shownAfterPublish))")
        guard shownAfterPublish else { return }

        // 닫기: 한 번 탭 → 사진 보기가 사라지고 말풍선으로 돌아온다.
        tapToClose(app)
        let closed = waitGone(viewer(app), timeout: 5)
        let backOnRow = thumbnail(app).waitForExistence(timeout: 5)
        print("[photo] close closed=\(closed) back-on-row=\(backOnRow)")
        XCTAssertTrue(closed, "photo viewer did not close on a single tap")
        XCTAssertTrue(backOnRow, "timeline row did not come back after closing the viewer")
        guard closed, backOnRow else { return }

        // 같은 사진을 다시 눌러도 바로 뜬다.
        thumbnail(app).tap()
        let reopened = viewer(app).waitForExistence(timeout: Self.quietWindow)
        print("[photo] reopen shown=\(reopened)")
        XCTAssertTrue(reopened, "photo viewer did not reopen on the second tap")
        if reopened {
            tapToClose(app)
            XCTAssertTrue(waitGone(viewer(app), timeout: 5), "photo viewer did not close after reopening")
        }
    }
}
