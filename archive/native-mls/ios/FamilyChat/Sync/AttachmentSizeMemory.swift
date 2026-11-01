// #647 ①: 첨부 사진의 최종 크기를 디코드 **전에** 안다 — 말풍선 빈 자리를 처음부터 최종 썸네일과 같은 크기로 잡기 위해.
//   ① file-v2 설명자의 w/h 힌트(보내는 쪽이 채움, FILE-V2.md §1) → ② 이 기기가 전에 디코드해 잰 크기(구 사진: w/h 없는 설명자·v1).
// ②는 UserDefaults 에 LRU 2000건(`PixelSizeLRU`, FamilyMLSCore) — 키 = file-v2 blob id(내용 주소) 또는 v1 방·seq. 값은 픽셀 가로·세로뿐이다.
// 행별 설명자 읽기는 프로세스 동안 한 번(설명자는 바뀌지 않는다) — 말풍선 body 가 매번 DB 를 읽지 않게.
// 화면(AttachmentBubble)만 쓰지만 AppModel 의 「이 기기 지우기」가 비우므로 Sync/ 에 둔다(Linux 스모크도 같은 파일을 컴파일한다 — Foundation 만).
import Foundation
import FamilyMLSCore

@MainActor
final class AttachmentSizeMemory {
    static let shared = AttachmentSizeMemory()
    static let defaultsKey = "hande.attachmentPixelSizes"
    static let capacity = 2000   // init 기본값과 같다

    /// 한 첨부 행의 크기 출처: 기억 키 + 설명자 힌트(있으면).
    struct Row: Equatable {
        let key: String
        let hint: PixelSize?
    }

    private let defaults: UserDefaults
    private var lru: PixelSizeLRU
    private var rows: [String: Row] = [:]

    init(defaults: UserDefaults = .standard, capacity: Int = 2000) {
        self.defaults = defaults
        lru = PixelSizeLRU(capacity: capacity, encoded: defaults.stringArray(forKey: Self.defaultsKey) ?? [])
    }

    static func key(blob: String) -> String { "v2:\(blob)" }
    static func key(room: RoomID, seq: Int64) -> String { "v1:\(room)\u{1F}\(seq)" }

    /// 행의 크기 출처. file-v2 는 설명자를 한 번 읽어(`descriptor`) blob 키·w/h 를 기억한다 — 읽지 못하면(잠김 등) 기억하지 않고 다음에 다시.
    func row(room: RoomID, seq: Int64, isFileV2: Bool, descriptor: () -> FileV2Format.Descriptor?) -> Row {
        let rowKey = "\(room)\u{1F}\(seq)"
        if let known = rows[rowKey] { return known }
        guard isFileV2 else {
            let row = Row(key: Self.key(room: room, seq: seq), hint: nil)
            rows[rowKey] = row
            return row
        }
        guard let d = descriptor() else { return Row(key: Self.key(room: room, seq: seq), hint: nil) }
        let hint = d.width.flatMap { w in d.height.flatMap { h in PixelSize(width: w, height: h) } }
        let row = Row(key: Self.key(blob: d.blob), hint: hint)
        rows[rowKey] = row
        return row
    }

    /// 디코드 전에 아는 크기: 설명자 힌트 → 이 기기가 잰 크기.
    func knownSize(_ row: Row) -> PixelSize? { row.hint ?? lru.peek(row.key) }

    /// 디코드해 잰 크기를 기억한다(설명자 힌트가 있는 행은 기억할 필요 없다). 값이 바뀔 때만 저장한다.
    func remember(_ size: PixelSize, for row: Row) {
        guard row.hint == nil, lru.set(row.key, size) else { return }
        defaults.set(lru.encoded, forKey: Self.defaultsKey)
    }

    /// 「이 기기 지우기」: 대화와 함께 잰 크기 기록도 남기지 않는다.
    func clear() {
        lru.removeAll()
        rows = [:]
        defaults.removeObject(forKey: Self.defaultsKey)
    }
}
