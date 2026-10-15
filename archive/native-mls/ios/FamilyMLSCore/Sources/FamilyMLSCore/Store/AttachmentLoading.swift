// 첨부 지연 로딩(#364, 5 MiB 첨부): 타임라인은 BLOB 없이 읽고(`messageHeads`), 첨부 본체는 화면에 보일 때만(`attachment`).
// `MessageStore`(MessageRecord.swift, 동결)는 그대로 — 선택 적합 프로토콜. 앱은 `messageStore as? AttachmentLoading` 으로 묻고,
// 없으면 종전처럼 `messages(room:after:limit:)`(BLOB 포함)로 읽는다. 500행 × 5 MiB = 2.5 GB 를 한 번에 올리지 않기 위함.
import Foundation

public struct MessageHead: Equatable {
    /// `attachment == nil` 인 행(본문·메타는 그대로).
    public let record: MessageRecord
    /// 저장된 첨부 바이트 수(없으면 0) — 화면의 크기 표시·로드 여부 판단.
    public let attachmentBytes: Int
    public init(record: MessageRecord, attachmentBytes: Int) {
        self.record = record; self.attachmentBytes = attachmentBytes
    }
}

public protocol AttachmentLoading: AnyObject {
    func messageHeads(room: RoomID, after seq: Int64, limit: Int) throws -> [MessageHead]
    func attachment(room: RoomID, seq: Int64) throws -> Data?
}
