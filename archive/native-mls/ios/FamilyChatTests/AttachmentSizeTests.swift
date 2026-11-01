// #647 ①: 사진 말풍선 크기를 디코드 전에 최종 크기로 — 크기 함수(빈 자리·썸네일 공통)·ImageIO 표시 방향 읽기(EXIF 회전 JPEG 를
// 테스트 안에서 만든다)·구 사진 잰 크기 기억(UserDefaults)·송신 설명자 w/h. 순수 규칙(방향 교환·LRU)은 Core ImagePixelSizeTests(Linux).
import XCTest
import SwiftUI
import UIKit
import ImageIO
import UniformTypeIdentifiers
import FamilyMLSCore
@testable import FamilyChat

@MainActor
final class AttachmentSizeTests: XCTestCase {
    // MARK: 크기 함수

    func testDisplaySizeFitsThe280x360Box() {
        func size(_ w: Int?, _ h: Int?) -> CGSize { AttachmentThumbnail.displaySize(pixelWidth: w, pixelHeight: h) }
        XCTAssertEqual(size(4032, 3024), CGSize(width: 280, height: 210), "landscape 4:3 — width-bound")
        XCTAssertEqual(size(3024, 4032), CGSize(width: 270, height: 360), "portrait 3:4 — height-bound (was a 280×210 slot: +150pt)")
        XCTAssertEqual(size(1000, 1000), CGSize(width: 280, height: 280), "square")
        XCTAssertEqual(size(1920, 1080).height, 157.5, accuracy: 0.001, "16:9")
        XCTAssertEqual(size(100, 50), CGSize(width: 280, height: 140), "small photos fill the box like the old resizable/scaledToFit")
    }

    func testDisplaySizeKeepsExtremeRatiosTappable() {
        XCTAssertEqual(AttachmentThumbnail.displaySize(pixelWidth: 20000, pixelHeight: 100), CGSize(width: 280, height: AttachmentThumbnail.minSide))
        XCTAssertEqual(AttachmentThumbnail.displaySize(pixelWidth: 100, pixelHeight: 20000), CGSize(width: AttachmentThumbnail.minSide, height: 360))
    }

    func testDisplaySizeWithoutDimensionsIsTheOld4x3Slot() {
        XCTAssertEqual(AttachmentThumbnail.fallbackSize, CGSize(width: 280, height: 210))
        XCTAssertEqual(AttachmentBubble.placeholderSize, AttachmentThumbnail.fallbackSize)
        XCTAssertEqual(AttachmentThumbnail.displaySize(pixelWidth: nil, pixelHeight: nil), AttachmentThumbnail.fallbackSize)
        XCTAssertEqual(AttachmentThumbnail.displaySize(pixelWidth: 1200, pixelHeight: nil), AttachmentThumbnail.fallbackSize)
        XCTAssertEqual(AttachmentThumbnail.displaySize(pixelWidth: 0, pixelHeight: 10), AttachmentThumbnail.fallbackSize)
        XCTAssertEqual(AttachmentThumbnail.displaySize(nil), AttachmentThumbnail.fallbackSize)
    }

    /// 같은 틀이면 내용(로딩 글 / 썸네일)과 무관하게 같은 크기 — 좁은 화면에서는 두 상태 모두 같은 비로 줄어든다.
    func testPhotoFrameHasTheSameSizeLoadingAndLoadedAndShrinksOnNarrowScreens() throws {
        let size = AttachmentThumbnail.displaySize(pixelWidth: 3024, pixelHeight: 4032)
        let image = UIGraphicsImageRenderer(size: CGSize(width: 30, height: 40)).image { context in
            UIColor.orange.setFill(); context.fill(CGRect(x: 0, y: 0, width: 30, height: 40))
        }
        func fitted<V: View>(_ view: V, width: CGFloat) -> CGSize {
            let host = UIHostingController(rootView: view)
            return host.sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude))
        }
        let loading = AttachmentPhotoFrame(size: size, content: Text("사진 불러오는 중 1.2 MB").font(.footnote))
        let loaded = AttachmentPhotoFrame(size: size, content: Image(uiImage: image).resizable().scaledToFill())
        for width in [400.0, 270.0, 200.0] as [CGFloat] {
            let a = fitted(loading, width: width), b = fitted(loaded, width: width)
            XCTAssertEqual(a.width, b.width, accuracy: 0.01, "width \(width)")
            XCTAssertEqual(a.height, b.height, accuracy: 0.01, "height \(width)")
            XCTAssertEqual(a.width, min(width, size.width), accuracy: 0.5, "bounded by the frame, shrinks on narrow screens")
            XCTAssertEqual(a.height / a.width, size.height / size.width, accuracy: 0.01, "keeps the ratio")
        }
    }

    // MARK: 사진 옆 공유 아이콘(오너 요청 2026-11-01) — 「저장·공유」 줄 대신

    private final class FrameBox { var frame: CGRect? }

    /// 사진 말풍선(틀 + 3pt 테두리)을 `PhotoShareRow` 에 넣어 창에 띄우고, 행 크기와 행 안 말풍선 위치를 잰다.
    private func layout(mine: Bool, url: URL?, width: CGFloat = 400) throws -> (row: CGSize, bubble: CGRect, alone: CGSize) {
        let size = AttachmentThumbnail.displaySize(pixelWidth: 3024, pixelHeight: 4032)
        let bubble = AttachmentPhotoFrame(size: size, content: Text("사진 불러오는 중").font(.footnote)).padding(MessageRow.mediaInset)
        let box = FrameBox()
        let row = PhotoShareRow(mine: mine, shareURL: url) {
            bubble.background(GeometryReader { g in Color.clear.onAppear { box.frame = g.frame(in: .named("row")) } })
        }
        .coordinateSpace(name: "row")
        let host = UIHostingController(rootView: row)
        // 장면에 붙은 창이어야 그려진다(iOS 13+). 테스트 호스트 앱의 장면이 없으면 frame 창으로.
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        let window = scene.map { UIWindow(windowScene: $0) } ?? UIWindow()
        window.frame = CGRect(x: 0, y: 0, width: width, height: 800)
        window.rootViewController = host
        window.isHidden = false
        defer { window.isHidden = true }
        host.view.layoutIfNeeded()
        let deadline = Date().addingTimeInterval(3)
        while box.frame == nil && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        let proposal = CGSize(width: width, height: .greatestFiniteMagnitude)
        let alone = UIHostingController(rootView: bubble).sizeThatFits(in: proposal)
        return (host.sizeThatFits(in: proposal), try XCTUnwrap(box.frame, "bubble laid out"), alone)
    }

    func testShareIconSitsOutsideTheBubbleOnTheFarSide() throws {
        XCTAssertEqual(PhotoShareRow<EmptyView>.order(mine: false), [.bubble, .share], "received photo: icon outside the right edge")
        XCTAssertEqual(PhotoShareRow<EmptyView>.order(mine: true), [.share, .bubble], "my photo: icon outside the left edge")
        let slot = PhotoShareRow<EmptyView>.slot, gap = PhotoShareRow<EmptyView>.spacing
        XCTAssertGreaterThanOrEqual(slot, 44, "tap target ≥ 44pt")
        let received = try layout(mine: false, url: nil)
        XCTAssertEqual(received.bubble.minX, 0, accuracy: 0.5, "received: bubble first, icon slot to its right")
        let mine = try layout(mine: true, url: nil)
        XCTAssertEqual(mine.bubble.minX, slot + gap, accuracy: 0.5, "mine: icon slot first, bubble to its right")
        XCTAssertEqual(mine.row.width, received.row.width, accuracy: 0.5)
        XCTAssertEqual(received.row.width, received.alone.width + gap + slot, accuracy: 0.5, "icon slot is beside, not inside")
    }

    /// 공유 파일이 준비되기 전·후 행 높이 = 사진 말풍선 높이, 말풍선 위치·크기도 같다(아이콘은 높이를 보태지 않는다).
    func testShareIconDoesNotChangeTheRowWhenTheFileBecomesReady() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("attachment-647.jpg")
        for mine in [false, true] {
            let before = try layout(mine: mine, url: nil), after = try layout(mine: mine, url: url)
            XCTAssertEqual(before.row.height, before.alone.height, accuracy: 0.5, "row height = photo bubble height (mine \(mine))")
            XCTAssertEqual(after.row.height, before.row.height, accuracy: 0.01, "no height change when ready (mine \(mine))")
            XCTAssertEqual(after.row.width, before.row.width, accuracy: 0.01)
            XCTAssertEqual(after.bubble.minX, before.bubble.minX, accuracy: 0.01, "bubble does not move (mine \(mine))")
            XCTAssertEqual(after.bubble.size.width, before.bubble.size.width, accuracy: 0.01)
            XCTAssertEqual(after.bubble.size.height, before.bubble.size.height, accuracy: 0.01)
        }
    }

    /// 사진 힌트 행만 옆 아이콘(첫 프레임부터 자리) — 사진이 아닌 파일은 종전처럼 말풍선 안 「저장·공유」 줄.
    func testOnlyPhotoRowsShareBeside() {
        func record(_ mime: String) -> MessageRecord {
            MessageRecord(room: "family", seq: 1, senderDevice: "dad-pc", clientId: AttachmentFormat.newClientId(), kind: .attachment,
                          body: mime, attachment: nil, receivedAt: Date(), decryptedBy: .app)
        }
        XCTAssertTrue(AttachmentBubble.sharesBeside(record("image/jpeg")))
        XCTAssertTrue(AttachmentBubble.sharesBeside(record("image/heic")))
        XCTAssertFalse(AttachmentBubble.sharesBeside(record("application/pdf")))
        XCTAssertFalse(AttachmentBubble.sharesBeside(record("")))
    }

    // MARK: ImageIO 표시 방향 읽기

    /// 40×30 비트맵을 EXIF 방향과 함께 인코딩(디스크 픽스처 없이).
    private func encoded(_ type: UTType, width: Int = 40, height: Int = 30, orientation: Int? = nil) throws -> Data {
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                              space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(UIColor.systemTeal.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try XCTUnwrap(context.makeImage())
        let out = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(out, type.identifier as CFString, 1, nil))
        var properties: [CFString: Any] = [:]
        if let orientation { properties[kCGImagePropertyOrientation] = orientation }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return out as Data
    }

    func testProbeReadsTheDisplayOrientedSizeWithoutDecoding() throws {
        XCTAssertEqual(ImagePixelSize.probe(try encoded(.jpeg)), PixelSize(width: 40, height: 30))
        XCTAssertEqual(ImagePixelSize.probe(try encoded(.jpeg, orientation: 1)), PixelSize(width: 40, height: 30))
        XCTAssertEqual(ImagePixelSize.probe(try encoded(.jpeg, orientation: 6)), PixelSize(width: 30, height: 40), "EXIF 6 (rotate 90°) swaps w/h")
        XCTAssertEqual(ImagePixelSize.probe(try encoded(.jpeg, orientation: 8)), PixelSize(width: 30, height: 40))
        XCTAssertEqual(ImagePixelSize.probe(try encoded(.jpeg, orientation: 3)), PixelSize(width: 40, height: 30), "180° keeps w/h")
        XCTAssertEqual(ImagePixelSize.probe(try encoded(.png, width: 5, height: 7)), PixelSize(width: 5, height: 7))
        XCTAssertNil(ImagePixelSize.probe(Data("%PDF-1.7 not an image".utf8)))
        XCTAssertNil(ImagePixelSize.probe(Data()))
    }

    /// 보낸 쪽 힌트(probe)와 받는 쪽 썸네일(EXIF 반영 축소)의 비가 같다 → resolve 가 힌트를 고른다 → 로딩 전후 같은 틀.
    func testRotatedJpegHintAgreesWithTheDecodedThumbnail() async throws {
        let jpeg = try encoded(.jpeg, width: 400, height: 300, orientation: 6)
        let hint = try XCTUnwrap(ImagePixelSize.probe(jpeg))
        let record = MessageRecord(room: "family", seq: 41, senderDevice: "dad-pc", clientId: AttachmentFormat.newClientId(), kind: .attachment,
                                   body: "image/jpeg", attachment: nil, receivedAt: Date(), decryptedBy: .app)
        let made = await AttachmentPreviewCache(countLimit: 4).prepare(record: record, bytes: jpeg, scale: 3)
        let thumb = try XCTUnwrap(made.thumbnail?.cgImage)
        XCTAssertLessThan(thumb.width, thumb.height, "thumbnail is portrait (EXIF applied)")
        XCTAssertEqual(made.pixelSize, hint, "preview carries the original display-oriented size")
        XCTAssertEqual(ImagePixelSize.resolve(hint: hint, measured: PixelSize(width: thumb.width, height: thumb.height)), hint)
        XCTAssertEqual(AttachmentThumbnail.displaySize(hint), CGSize(width: 270, height: 360))
    }

    // MARK: 구 사진 크기 기억

    private func freshDefaults() throws -> UserDefaults {
        let name = "AttachmentSizeTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return defaults
    }

    func testMeasuredSizeOfALegacyPhotoIsRememberedAcrossLaunches() throws {
        let defaults = try freshDefaults()
        let memory = AttachmentSizeMemory(defaults: defaults)
        let row = memory.row(room: "family", seq: 7, isFileV2: false) { XCTFail("v1 has no descriptor"); return nil }
        XCTAssertNil(memory.knownSize(row), "first entry: unknown → 4:3 slot")
        let measured = try XCTUnwrap(PixelSize(width: 1200, height: 1600))
        memory.remember(measured, for: row)
        let relaunched = AttachmentSizeMemory(defaults: defaults)
        let again = relaunched.row(room: "family", seq: 7, isFileV2: false) { nil }
        XCTAssertEqual(relaunched.knownSize(again), measured, "second entry starts at the final size")
        XCTAssertNil(relaunched.knownSize(relaunched.row(room: "family", seq: 8, isFileV2: false) { nil }))
        relaunched.clear()
        XCTAssertNil(AttachmentSizeMemory(defaults: defaults).knownSize(again), "wipe forgets")
    }

    func testFileV2RowsUseTheDescriptorHintOrTheBlobKey() throws {
        let defaults = try freshDefaults()
        let memory = AttachmentSizeMemory(defaults: defaults)
        func descriptor(w: Int?, h: Int?, blob: String) throws -> FileV2Format.Descriptor {
            try FileV2Format.parseDescriptor(FileV2Format.encodeDescriptor(blob: blob, size: 10, key: Data(count: 32), nonce: Data(count: 12),
                                                                         mime: "image/jpeg", width: w, height: h))
        }
        let blobA = String(repeating: "a", count: 64), blobB = String(repeating: "b", count: 64)
        let hinted = try descriptor(w: 3024, h: 4032, blob: blobA)
        var reads = 0
        let row = memory.row(room: "family", seq: 1, isFileV2: true) { reads += 1; return hinted }
        _ = memory.row(room: "family", seq: 1, isFileV2: true) { reads += 1; return hinted }
        XCTAssertEqual(reads, 1, "the descriptor is read once per row")
        XCTAssertEqual(row.key, AttachmentSizeMemory.key(blob: blobA))
        XCTAssertEqual(memory.knownSize(row), PixelSize(width: 3024, height: 4032))
        memory.remember(try XCTUnwrap(PixelSize(width: 1, height: 1)), for: row)
        XCTAssertNil(defaults.stringArray(forKey: AttachmentSizeMemory.defaultsKey), "hinted rows need no memory")

        // 읽기 실패(잠김)는 기억하지 않는다 — 다음 body 에서 다시 읽는다.
        _ = memory.row(room: "family", seq: 2, isFileV2: true) { nil }
        let legacy = try descriptor(w: nil, h: nil, blob: blobB)
        let row2 = memory.row(room: "family", seq: 2, isFileV2: true) { legacy }
        XCTAssertEqual(row2.key, AttachmentSizeMemory.key(blob: blobB))
        XCTAssertNil(memory.knownSize(row2))
        memory.remember(try XCTUnwrap(PixelSize(width: 800, height: 600)), for: row2)
        XCTAssertEqual(AttachmentSizeMemory(defaults: defaults).knownSize(row2), PixelSize(width: 800, height: 600), "keyed by blob id")
    }

    // MARK: 송신 — 설명자 w/h

    func testFileV2SendCarriesTheDisplayOrientedSize() async throws {
        let relay = InMemoryRelay()
        let messages = InMemoryMessageStore()
        var deps = AppModel.Dependencies(
            engineFactory: MemberFakeFactory(), stateStore: InMemoryStateStore(), messageStore: messages,
            outbox: InMemoryOutboxStore(), cursors: InMemoryCursorStore(),
            identityProvider: { "mom-iphone-a1b2c3" }, expectedDecryptFormat: { 2 }, makeTransport: { _ in relay })
        deps.sendFileV2 = true
        let model = AppModel(dependencies: deps)
        await model.bootstrap(); model.login(.bearer("t")); await model.refresh()
        XCTAssertEqual(model.phase, .ready)

        let rotated = try encoded(.jpeg, width: 400, height: 300, orientation: 6)
        guard case .sent(_, let seq, _)? = await model.sendAttachment(room: "family", data: rotated) else {
            return XCTFail("\(String(describing: model.lastError))")
        }
        let row = try XCTUnwrap(messages.messages(room: "family", after: 0, limit: 10).first { $0.seq == seq })
        let descriptor = try FileV2Format.parseDescriptor(try XCTUnwrap(row.attachment))
        XCTAssertEqual(descriptor.width, 300, "display orientation: EXIF 6 swaps")
        XCTAssertEqual(descriptor.height, 400)

        // 사진이 아니면(또는 크기를 모르면) w/h 없이 그대로 보낸다.
        guard case .sent(_, let seq2, _)? = await model.sendAttachment(room: "family", data: Data("%PDF-1.7 hello".utf8)) else {
            return XCTFail("\(String(describing: model.lastError))")
        }
        let pdf = try FileV2Format.parseDescriptor(try XCTUnwrap(messages.messages(room: "family", after: 0, limit: 10).first { $0.seq == seq2 }?.attachment))
        XCTAssertNil(pdf.width)
        XCTAssertNil(pdf.height)
    }
}
