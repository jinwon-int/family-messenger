// 첨부 보조(§9-4): ① 사진을 256 KiB 안으로 줄이기(JPEG 품질 → 축소 반복) ② 파일을 그대로(한도 검사만) ③ 받은 첨부를 공유용 임시 파일로.
// 와이어 형식(원본 바이트·client_id 규칙)은 Core `AttachmentFormat`. 여기는 UIKit 이 필요한 앱 전용 코드 — Linux 스모크 목록에 넣지 말 것.
import Foundation
import FamilyMLSCore
#if canImport(UIKit)
import UIKit
#endif

enum AttachmentPreparer {
    static let limit = AttachmentFormat.maxBytes
    /// 축소 하한(긴 변). 이보다 작아져도 한도를 못 맞추면 포기한다(그런 사진은 없다고 봐도 된다 — 320px JPEG q0.3 ≈ 20 KB).
    static let minLongSide: CGFloat = 320
    static let qualities: [CGFloat] = [0.85, 0.7, 0.55, 0.4, 0.3]

    /// 파일: 한도 안이면 그대로, 아니면 nil(줄일 수 없다).
    static func prepareFile(_ data: Data) -> Data? { data.count <= limit ? data : nil }

    #if canImport(UIKit)
    /// 사진: 한도 안의 JPEG/PNG/GIF/WebP 는 그대로(웹·NSE 가 읽는 형식). HEIC 나 한도 초과는 JPEG 로 다시 인코드하고,
    /// 그래도 크면 긴 변을 0.75 배씩 줄인다. 반환 nil = 디코드 실패 또는 줄여도 한도 초과.
    static func preparePhoto(_ data: Data, limit: Int = AttachmentPreparer.limit) -> Data? {
        let mime = AttachmentFormat.sniffMime(data)
        if data.count <= limit, ["image/jpeg", "image/png", "image/gif", "image/webp"].contains(mime) { return data }
        guard let image = UIImage(data: data) else { return nil }
        return shrink(image, limit: limit)
    }

    static func shrink(_ original: UIImage, limit: Int = AttachmentPreparer.limit) -> Data? {
        var image = original
        while true {
            for q in qualities {
                if let jpeg = image.jpegData(compressionQuality: q), jpeg.count <= limit { return jpeg }
            }
            let longSide = max(image.size.width, image.size.height) * image.scale
            guard longSide > minLongSide else { return nil }
            image = scaled(image, by: 0.75)
        }
    }

    private static func scaled(_ image: UIImage, by factor: CGFloat) -> UIImage {
        let size = CGSize(width: max(1, (image.size.width * image.scale * factor).rounded()),
                          height: max(1, (image.size.height * image.scale * factor).rounded()))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
    }
    #endif
}

/// 받은 첨부를 공유 시트에 넘길 임시 파일(앱 전용 tmp, 보호 등급 기본). 이름은 웹과 같은 규칙 `attachment-<seq>.<ext>`.
enum AttachmentExport {
    static func temporaryURL(for record: MessageRecord, bytes override: Data? = nil) -> URL? {
        guard let bytes = override ?? record.attachment else { return nil }
        let name = "attachment-\(record.seq).\(AttachmentFormat.fileExtension(mime: record.body))"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("hande-share", isDirectory: true).appendingPathComponent(name)
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try bytes.write(to: url, options: [.atomic])
            return url
        } catch {
            return nil
        }
    }
}
