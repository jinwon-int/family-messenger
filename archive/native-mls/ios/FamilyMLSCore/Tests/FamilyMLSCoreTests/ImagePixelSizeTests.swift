// #647 ①: 첨부 사진 표시 방향 크기(설명자 w/h 힌트)·힌트와 실측 고르기·구 사진 잰 크기 LRU — 순수 Swift(Linux `swift test`).
// ImageIO 읽기(`ImagePixelSize.probe`)는 Apple 전용이라 FamilyChatTests/AttachmentSizeTests 가 EXIF 회전 JPEG 로 검증한다.
import XCTest
@testable import FamilyMLSCore

final class ImagePixelSizeTests: XCTestCase {
    func testPixelSizeStaysInsideTheDescriptorRange() {
        XCTAssertNotNil(PixelSize(width: 1, height: 1))
        XCTAssertNotNil(PixelSize(width: FileV2Format.maxDimension, height: FileV2Format.maxDimension))
        XCTAssertNil(PixelSize(width: 0, height: 10))
        XCTAssertNil(PixelSize(width: 10, height: -1))
        XCTAssertNil(PixelSize(width: FileV2Format.maxDimension + 1, height: 10), "w/h above 20000 are not encodable")
    }

    func testDisplayOrientationSwapsForRotatedExif() {
        // 1~4 = 그대로(뒤집기만), 5~8 = 90° 회전 → 가로·세로 바뀜. 값 없음·범위 밖은 1.
        for o in [1, 2, 3, 4] { XCTAssertEqual(ImagePixelSize.displayOriented(width: 4032, height: 3024, orientation: o), PixelSize(width: 4032, height: 3024), "\(o)") }
        for o in [5, 6, 7, 8] { XCTAssertEqual(ImagePixelSize.displayOriented(width: 4032, height: 3024, orientation: o), PixelSize(width: 3024, height: 4032), "\(o)") }
        XCTAssertEqual(ImagePixelSize.displayOriented(width: 4032, height: 3024, orientation: nil), PixelSize(width: 4032, height: 3024))
        XCTAssertEqual(ImagePixelSize.displayOriented(width: 4032, height: 3024, orientation: 9), PixelSize(width: 4032, height: 3024))
        XCTAssertNil(ImagePixelSize.displayOriented(width: 30000, height: 10, orientation: 6), "out of range → no hint")
        XCTAssertNil(ImagePixelSize.displayOriented(width: 0, height: 10, orientation: 1))
    }

    func testResolvePrefersTheHintWhenTheRatioAgrees() throws {
        let hint = try XCTUnwrap(PixelSize(width: 3024, height: 4032))
        let thumb = try XCTUnwrap(PixelSize(width: 809, height: 1080))   // 축소 썸네일 반올림(3:4 ≈ 0.749)
        XCTAssertEqual(ImagePixelSize.resolve(hint: hint, measured: thumb), hint, "same frame before and after the decode")
        let lie = try XCTUnwrap(PixelSize(width: 4032, height: 3024))
        XCTAssertEqual(ImagePixelSize.resolve(hint: lie, measured: thumb), thumb, "a wrong hint loses to the decoded image")
        XCTAssertEqual(ImagePixelSize.resolve(hint: nil, measured: thumb), thumb)
        XCTAssertEqual(ImagePixelSize.resolve(hint: hint, measured: nil), hint)
        XCTAssertNil(ImagePixelSize.resolve(hint: nil, measured: nil))
    }

    #if !canImport(ImageIO)
    func testProbeIsUnavailableWithoutImageIO() {
        XCTAssertNil(ImagePixelSize.probe(Data([0xFF, 0xD8, 0xFF, 0xE0])), "Linux: no w/h, the sender omits them")
    }
    #endif

    func testLRUKeepsTheMostRecentEntriesAndRoundTrips() throws {
        let a = try XCTUnwrap(PixelSize(width: 4, height: 3)), b = try XCTUnwrap(PixelSize(width: 3, height: 4))
        var lru = PixelSizeLRU(capacity: 3)
        XCTAssertTrue(lru.set("v2:aa", a))
        XCTAssertTrue(lru.set("v1:family\u{1F}7", b))
        XCTAssertTrue(lru.set("v2:cc", a))
        XCTAssertFalse(lru.set("v2:aa", a), "same value: no write needed, but it becomes the most recent")
        XCTAssertTrue(lru.set("v2:dd", b))   // 넘침 → 가장 오래된 v1:family·7 이 빠진다
        XCTAssertEqual(lru.count, 3)
        XCTAssertNil(lru.peek("v1:family\u{1F}7"))
        XCTAssertEqual(lru.peek("v2:aa"), a)
        XCTAssertTrue(lru.set("v2:cc", b), "changed value is a write")
        XCTAssertEqual(lru.encoded, ["v2:aa 4 3", "v2:dd 3 4", "v2:cc 3 4"], "oldest first")
        XCTAssertEqual(PixelSizeLRU(capacity: 3, encoded: lru.encoded), lru)
    }

    func testLRUDecodeSkipsBrokenLinesAndKeysMayHoldSpaces() throws {
        let lru = PixelSizeLRU(capacity: 10, encoded: ["v1:가족 방\u{1F}3 1200 1600", "garbage", "v2:x 0 5", "v2:y 5", " 3 4", "v2:z 20001 3", "v2:ok 7 9"])
        XCTAssertEqual(lru.count, 2)
        XCTAssertEqual(lru.peek("v1:가족 방\u{1F}3"), PixelSize(width: 1200, height: 1600))
        XCTAssertEqual(lru.peek("v2:ok"), PixelSize(width: 7, height: 9))
        var capped = PixelSizeLRU(capacity: 2, encoded: ["a 1 1", "b 2 2", "c 3 3"])
        XCTAssertEqual(capped.encoded, ["b 2 2", "c 3 3"], "a stored list longer than the cap keeps the newest")
        capped.removeAll()
        XCTAssertEqual(capped.count, 0)
    }
}
