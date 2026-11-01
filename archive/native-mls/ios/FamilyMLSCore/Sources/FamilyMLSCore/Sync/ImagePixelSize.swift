// #647 ①: 첨부 사진의 **표시 방향** 픽셀 크기 — file-v2 설명자 선택 힌트 `w`/`h`(FILE-V2.md §1, 형식 변경 없음)를 보내는 쪽이 채우고,
// 받는 쪽은 사진을 디코드하기 전에 말풍선 자리를 최종 크기로 잡는다. 진입 뒤 사진 행 높이가 바뀌는 것이 타임라인 바닥 착지가
// 어긋나는 가장 큰 원천이었다(#497 2026-11-01 코멘트 후보 1, #647 근본 원인).
//
// 순수 부분(EXIF 방향 반영·범위 검사·힌트와 실측 고르기·LRU)은 Linux `swift test` 에서 돈다. ImageIO 읽기(`probe`)는 Apple 플랫폼에서만 —
// 비트맵을 펼치지 않고 헤더 속성만 읽는다. 검증은 FamilyChatTests/AttachmentSizeTests(시뮬레이터, EXIF 회전 JPEG 를 테스트 안에서 만든다).
import Foundation
#if canImport(ImageIO)
import ImageIO
#endif

/// 사진의 픽셀 크기(표시 방향). 두 변 모두 `1...FileV2Format.maxDimension` — 그 밖이면 만들지 않는다(설명자에 실을 수 없는 값).
public struct PixelSize: Equatable, Hashable, Sendable {
    public let width: Int
    public let height: Int

    public init?(width: Int, height: Int) {
        let range = 1...FileV2Format.maxDimension
        guard range.contains(width), range.contains(height) else { return nil }
        self.width = width
        self.height = height
    }
}

public enum ImagePixelSize {
    /// 저장된 가로·세로 + EXIF/TIFF 방향(1~8) → 화면에 보이는 방향의 크기. 5~8 은 90° 회전이라 두 변이 바뀐다.
    /// 방향 값이 없거나 범위 밖이면 1(그대로)로 본다 — ImageIO 썸네일(`kCGImageSourceCreateThumbnailWithTransform`)과 같은 판단.
    public static func displayOriented(width: Int, height: Int, orientation: Int?) -> PixelSize? {
        if let orientation, (5...8).contains(orientation) { return PixelSize(width: height, height: width) }
        return PixelSize(width: width, height: height)
    }

    /// 받은 힌트(설명자 w/h 또는 기기가 전에 잰 크기)와 디코드한 실측 중 화면에 쓸 크기.
    /// 둘의 가로세로 비가 `tolerance`(상대 2%) 안이면 **힌트**를 쓴다 — 빈 자리와 로딩 뒤 크기가 정확히 같아야 행 높이가 안 바뀐다
    /// (실측은 축소 썸네일 반올림으로 1px 쯤 다를 수 있다). 비가 크게 다르면(틀린·악의적 힌트) 실측이 이긴다. 실측이 없으면 힌트.
    public static func resolve(hint: PixelSize?, measured: PixelSize?, tolerance: Double = 0.02) -> PixelSize? {
        guard let measured else { return hint }
        guard let hint else { return measured }
        let a = Double(hint.width) / Double(hint.height)
        let b = Double(measured.width) / Double(measured.height)
        return abs(a - b) / b <= tolerance ? hint : measured
    }

    #if canImport(ImageIO)
    /// 이미지 바이트 → 표시 방향 픽셀 크기. 헤더 속성(PixelWidth/PixelHeight/Orientation)만 읽고 디코드하지 않는다.
    /// 이미지가 아니거나 크기를 모르거나 범위 밖이면 nil — 보내는 쪽은 그때 w/h 를 빼고 보낸다(받는 쪽은 4:3 자리로 시작).
    public static func probe(_ data: Data) -> PixelSize? {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, options), CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, options) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue
        else { return nil }
        let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue
        return displayOriented(width: width, height: height, orientation: orientation)
    }
    #else
    /// ImageIO 가 없는 플랫폼(Linux `swift test`·linux-smoke) — 크기를 모른다(w/h 없이 보낸다).
    public static func probe(_ data: Data) -> PixelSize? { nil }
    #endif
}

/// 키 → 픽셀 크기, 최근 쓴 것부터 `capacity` 건만 남기는 작은 LRU(#647: 구 사진 — w/h 없는 설명자·v1 — 의 잰 크기를 기억).
/// 저장은 문자열 배열(`encoded`, 오래된 것부터 `"<키> <가로> <세로>"`) — UserDefaults·plist 에 그대로 들어가고 Linux 에서도 같다.
public struct PixelSizeLRU: Equatable {
    public let capacity: Int
    private var sizes: [String: PixelSize] = [:]
    /// 오래된 것 → 최근 것. `capacity` 가 작아(기본 2000) 배열 이동 비용은 무시할 만하다.
    private var order: [String] = []

    public init(capacity: Int = 2000, encoded: [String] = []) {
        self.capacity = max(1, capacity)
        for line in encoded {
            // 키에 공백이 있어도 되게 뒤에서 두 칸을 숫자로 읽는다. 깨진 줄은 버린다.
            let parts = line.split(separator: " ", omittingEmptySubsequences: false)
            guard parts.count >= 3, let w = Int(parts[parts.count - 2]), let h = Int(parts[parts.count - 1]),
                  let size = PixelSize(width: w, height: h) else { continue }
            let key = parts.dropLast(2).joined(separator: " ")
            guard !key.isEmpty else { continue }
            set(key, size)
        }
    }

    public var count: Int { order.count }

    /// 읽기만(순서 그대로) — 화면 body 에서 부른다.
    public func peek(_ key: String) -> PixelSize? { sizes[key] }

    /// 넣거나 고치고 가장 최근으로 옮긴다. 넘치면 가장 오래된 것부터 버린다. 반환: 저장할 변화가 있었는가(값이 새로 들어왔거나 바뀜).
    @discardableResult
    public mutating func set(_ key: String, _ size: PixelSize) -> Bool {
        let changed = sizes[key] != size
        if sizes[key] != nil, let at = order.firstIndex(of: key) { order.remove(at: at) }
        sizes[key] = size
        order.append(key)
        while order.count > capacity { sizes[order.removeFirst()] = nil }
        return changed
    }

    public mutating func removeAll() {
        sizes = [:]
        order = []
    }

    public var encoded: [String] { order.compactMap { key in sizes[key].map { "\(key) \($0.width) \($0.height)" } } }
}
