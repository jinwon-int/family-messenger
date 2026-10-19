// 첨부(§9-4 "≤256 KiB 첨부") 화면 문구. 앱 전용 — NSE 소스 목록(project.yml)에 넣지 말 것. 한도 초과 문구는 Strings.attachmentTooLarge(AppModel 공용).
import Foundation

extension Strings {
    static let attachMenu = "첨부"
    static let attachPhoto = "사진 보내기"
    static let attachFile = "파일 보내기"
    static let attachPreparing = "첨부 준비 중…"
    static let attachPhotoUnreadable = "사진을 읽지 못했습니다. 다른 사진을 골라 주세요."
    static let attachFileUnreadable = "파일을 읽지 못했습니다."
    static let attachmentImage = "사진"
    static func attachmentFile(_ bytes: Int, _ mime: String) -> String { "📎 파일 · \(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)) · \(mime)" }
    static let attachmentSave = "저장·공유"
    /// 전체 화면 사진 보기(사진 탭).
    static let attachmentViewerClose = "닫기"
    static let attachmentViewerHint = "두 손가락으로 확대 · 두 번 탭"
    static func attachmentLoading(_ bytes: Int) -> String { "📎 불러오는 중 · \(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file))" }
    static let attachHint = "첨부는 5 MiB 까지입니다. 사진은 자동으로 줄여서 보냅니다. 파일 이름은 보내지 않습니다(받는 쪽에는 종류와 크기만 보입니다)."
}
