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
}

/// 방·seq → 준비물. `NSCache` 는 스레드 안전하고 메모리 압박 때 스스로 비운다(비워지면 말풍선이 다시 준비할 뿐).
final class AttachmentPreviewCache {
    static let shared = AttachmentPreviewCache()

    private final class Entry {
        let preview: AttachmentPreview
        init(_ preview: AttachmentPreview) { self.preview = preview }
    }

    private let cache = NSCache<NSString, Entry>()

    init(countLimit: Int = 300) { cache.countLimit = countLimit }

    private static func key(room: RoomID, seq: Int64) -> NSString { "\(room)\u{1F}\(seq)" as NSString }

    func preview(room: RoomID, seq: Int64) -> AttachmentPreview? {
        cache.object(forKey: Self.key(room: room, seq: seq))?.preview
    }

    /// 백그라운드에서 축소 디코드 + 공유 파일을 만들고 캐시에 넣는다. 이미 있으면 그대로 돌려준다.
    func prepare(record: MessageRecord, bytes: Data, scale: CGFloat) async -> AttachmentPreview {
        if let cached = preview(room: record.room, seq: record.seq) { return cached }
        let made = await Task.detached(priority: .userInitiated) { () -> AttachmentPreview in
            let thumbnail = AttachmentFormat.isImage(mime: record.body) ? AttachmentThumbnail.make(bytes, scale: scale) : nil
            return AttachmentPreview(thumbnail: thumbnail, shareURL: AttachmentExport.temporaryURL(for: record, bytes: bytes))
        }.value
        cache.setObject(Entry(made), forKey: Self.key(room: record.room, seq: record.seq))
        return made
    }
}

/// 말풍선용 축소 디코드(ImageIO). 원본(최대 5 MiB, 수천만 화소)을 비트맵으로 펼치지 않고 긴 변 = 말풍선 최대 크기 × 화면 배율로만 만든다.
/// EXIF 방향은 반영한다. 전체 화면 보기는 누를 때 원본을 따로 디코드한다(확대용).
enum AttachmentThumbnail {
    /// 말풍선의 이미지 최대 변(pt) — `AttachmentBubble` 의 frame 과 같다.
    static let maxPoints: CGFloat = 220

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
