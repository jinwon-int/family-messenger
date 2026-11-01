// #497: 첨부 말풍선이 보일 준비물(미리보기 비트맵 + 공유용 임시 파일)을 **한 번** 만들어 앱 프로세스에 둔다.
//
// 종전에는 `AttachmentBubble` 의 `@State data` 에만 있어서
//   ① 새 글이 오면 끝에서 3번째 행이 꼬리(lazy 아님)에서 LazyVStack 으로 옮겨지며 뷰가 새로 만들어져 상태가 사라지고,
//      「📎 불러오는 중」 한 줄로 줄었다가 다시 이미지로 커졌다 — 상대가 사진을 보낸 뒤 화면이 위로 튀었다 내려오기를 반복한 원인.
//   ② body 를 다시 계산할 때마다(폴링 4초마다 AppModel 이 바뀐다) 원본 해상도 디코드 + 최대 5 MiB 파일 쓰기를 메인 스레드에서 했다.
// 여기서는 캐시에 있으면 말풍선이 **첫 프레임부터** 실제 높이로 그려지고, 디코드·파일 쓰기는 백그라운드에서 행마다 한 번이다.
import Foundation
import FamilyMLSCore
#if canImport(UIKit)
import UIKit
import ImageIO

/// 말풍선 하나의 준비물. `thumbnail == nil` = 이미지가 아니거나 디코드하지 못했다(파일 말풍선으로 보인다).
struct AttachmentPreview {
    let thumbnail: UIImage?
    let shareURL: URL?
    /// 내용으로 정한 MIME(v1 = 수신 때 sniff, file-v2 = 복호화한 바이트를 sniff — 보낸 쪽 힌트가 아니다)와 실제 바이트 수.
    var mime: String = AttachmentFormat.fallbackMime
    var size: Int = 0
    /// #647: 원본의 표시 방향 픽셀 크기(ImageIO 헤더) — 없으면 썸네일 비트맵 크기. 말풍선 크기·구 사진 크기 기억에 쓴다.
    var pixelSize: PixelSize? = nil
}

/// 방·seq → 준비물. `NSCache` 는 스레드 안전하고 메모리 압박 때 스스로 비운다(비워지면 말풍선이 다시 준비할 뿐).
final class AttachmentPreviewCache {
    static let shared = AttachmentPreviewCache()

    private final class Entry {
        let preview: AttachmentPreview
        init(_ preview: AttachmentPreview) { self.preview = preview }
    }

    private let cache = NSCache<NSString, Entry>()

    /// 사진을 키우며(긴 변 360pt) 축소 비트맵도 커졌다(3배 화면 ≈ 1080px) — 개수 상한만으로는 수백 MB 가 될 수 있어 비트맵 바이트로도 묶는다.
    init(countLimit: Int = 300, totalCostLimit: Int = 128 * 1024 * 1024) {
        cache.countLimit = countLimit
        cache.totalCostLimit = totalCostLimit
    }

    /// 캐시 비용 = 축소 비트맵의 픽셀 바이트(RGBA) — 공유 파일은 디스크라 세지 않는다.
    static func cost(of preview: AttachmentPreview) -> Int {
        guard let cg = preview.thumbnail?.cgImage else { return 1 }
        return max(1, cg.bytesPerRow * cg.height)
    }

    private static func key(room: RoomID, seq: Int64) -> NSString { "\(room)\u{1F}\(seq)" as NSString }

    func preview(room: RoomID, seq: Int64) -> AttachmentPreview? {
        cache.object(forKey: Self.key(room: room, seq: seq))?.preview
    }

    /// 백그라운드에서 축소 디코드 + 공유 파일을 만들고 캐시에 넣는다. 이미 있으면 그대로 돌려준다.
    func prepare(record: MessageRecord, bytes: Data, scale: CGFloat) async -> AttachmentPreview {
        if let cached = preview(room: record.room, seq: record.seq) { return cached }
        let made = await Task.detached(priority: .userInitiated) { () -> AttachmentPreview in
            let thumbnail = AttachmentFormat.isImage(mime: record.body) ? AttachmentThumbnail.make(bytes, scale: scale) : nil
            let pixels = thumbnail.flatMap { thumb in
                ImagePixelSize.probe(bytes) ?? thumb.cgImage.flatMap { PixelSize(width: $0.width, height: $0.height) }
            }
            return AttachmentPreview(thumbnail: thumbnail, shareURL: AttachmentExport.temporaryURL(for: record, bytes: bytes),
                                     mime: record.body, size: bytes.count, pixelSize: pixels)
        }.value
        cache.setObject(Entry(made), forKey: Self.key(room: record.room, seq: record.seq), cost: Self.cost(of: made))
        return made
    }
}

/// 말풍선용 축소 디코드(ImageIO). 원본(최대 5 MiB, 수천만 화소)을 비트맵으로 펼치지 않고 긴 변 = 말풍선 최대 크기 × 화면 배율로만 만든다.
/// EXIF 방향은 반영한다. 전체 화면 보기는 누를 때 원본을 따로 디코드한다(확대용).
enum AttachmentThumbnail {
    /// 말풍선 안 사진의 최대 가로·세로(pt) — `AttachmentBubble` 의 frame 과 같다. 오너 요청(2026-10-27): 종전 220pt 정사각형 →
    /// 가로 280 · 세로 360(세로 사진이 좁아지지 않게 세로를 더 준다). 좁은 화면에서는 SwiftUI 가 남은 폭에 맞춰 줄인다.
    static let maxWidth: CGFloat = 280
    static let maxHeight: CGFloat = 360
    /// 축소 디코드의 긴 변(pt) = 위 둘 중 큰 값.
    static let maxPoints: CGFloat = 360
    /// 사진 모서리 — 말풍선 곡률(BubbleShape 18pt) − 사진 말풍선 여백(3pt).
    static let cornerRadius: CGFloat = 15
    /// 크기를 모를 때의 자리(4:3 가로) — 종전 `AttachmentBubble.placeholderSize`.
    static let fallbackSize = CGSize(width: maxWidth, height: maxWidth * 3 / 4)
    /// 아주 긴 파노라마·띠 사진도 누를 수 있는 높이·폭(pt) — 그보다 얇으면 이 값으로 세우고 사진은 가운데를 채워 자른다.
    static let minSide: CGFloat = 48

    /// #647 ①: 말풍선 안 사진의 크기(pt) — **빈 자리와 로딩된 썸네일이 같은 함수**를 쓴다(크기를 알면 로딩 전후 행 높이가 같다).
    /// 표시 방향 픽셀 크기의 비를 지켜 `maxWidth`×`maxHeight`(280×360) 상자에 맞춘다(작은 사진도 상자까지 — 종전 resizable·scaledToFit 과 같다).
    /// 모르면 `fallbackSize`(4:3). 남은 폭이 이보다 좁은 화면에서는 두 상태 모두 같은 비로 줄어든다(`AttachmentBubble.photoFrame`).
    static func displaySize(pixelWidth: Int?, pixelHeight: Int?) -> CGSize {
        guard let pixelWidth, let pixelHeight, pixelWidth > 0, pixelHeight > 0 else { return fallbackSize }
        let w = CGFloat(pixelWidth), h = CGFloat(pixelHeight)
        let scale = min(maxWidth / w, maxHeight / h)
        return CGSize(width: max(minSide, min(maxWidth, w * scale)), height: max(minSide, min(maxHeight, h * scale)))
    }

    static func displaySize(_ pixels: PixelSize?) -> CGSize { displaySize(pixelWidth: pixels?.width, pixelHeight: pixels?.height) }

    static func make(_ data: Data, scale: CGFloat, maxPoints: CGFloat = AttachmentThumbnail.maxPoints) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: Int((maxPoints * max(scale, 1)).rounded(.up)),
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return UIImage(cgImage: image, scale: max(scale, 1), orientation: .up)
    }
}
#endif
