// 한데 공유 확장(#643) 화면 문구. 확장은 앱의 `Strings.swift`(NSE·Linux 스모크 공용, 다른 앱 타입에 의존)를 링크하지 않고
// 방 표시 이름(`Strings+Names.swift` 의 `roomLabel`)만 함께 컴파일한다 — 그래서 `Strings` 자리를 여기서 연다(확장 타깃 전용 파일).
// 앱 쪽 전달 문구(`shareRoomGone`·`shareFileUnreadable`)는 AppModel 이 쓰므로 앱의 Strings.swift 에 있다.
import Foundation
import FamilyMLSCore

enum Strings {}

extension Strings {
    static let shareTitle = "한데로 보내기"
    static let shareSend = "보내기"
    static let shareCancel = "취소"
    static let sharePickRoom = "보낼 대화방"
    static let shareLoading = "공유한 내용을 읽는 중…"
    static let shareNoRooms = "보낼 대화방을 아직 모릅니다. 한데 앱을 한 번 열어 로그인하고 대화방 목록을 불러온 뒤 다시 공유해 주세요."
    static let shareHowItWorks = "「보내기」를 누르면 알림이 뜹니다. 알림을 누르거나 한데를 열면 그 대화방으로 보냅니다(24시간 안)."
    static func shareFiles(_ count: Int) -> String { "사진·파일 \(count)개" }
    static let shareNothing = "보낼 수 있는 내용이 없습니다(글·링크·사진·동영상·파일만 보낼 수 있습니다)."
    static func shareTooMany(_ count: Int, _ limit: Int) -> String { "한 번에 \(limit)개까지 보낼 수 있습니다(지금 \(count)개)." }
    static func shareTooLarge(_ name: String, _ bytes: Int, _ limit: Int) -> String {
        bytes == 0 ? "빈 파일은 보낼 수 없습니다: \(name)"
            : "「\(name)」이(가) 너무 큽니다(\(megabytes(bytes)) — 파일 하나는 \(megabytes(limit))까지)."
    }
    static func shareUnreadable(_ name: String) -> String { "「\(name)」을(를) 읽지 못했습니다." }
    static func shareSaveFailed(_ detail: String) -> String { "맡기지 못했습니다: \(detail)" }
    /// 로컬 알림 — 잠금화면에도 보이므로 방 이름·내용을 싣지 않는다(#520 과 같은 원칙).
    static let shareNotificationTitle = "한데"
    static let shareNotificationBody = "공유한 내용을 보낼 준비가 됐습니다. 누르면 한데에서 보냅니다."

    static func shareProblem(_ failure: ShareHandoff.Failure) -> String {
        switch failure {
        case .empty: return shareNothing
        case .tooManyAttachments(let count, let limit): return shareTooMany(count, limit)
        case .fileTooLarge(let name, let bytes, let limit): return shareTooLarge(name, bytes, limit)
        case .unreadable(let name): return shareUnreadable(name)
        }
    }

    private static func megabytes(_ bytes: Int) -> String {
        let mb = Double(bytes) / 1_048_576
        return mb >= 10 ? "\(Int(mb.rounded())) MB" : String(format: "%.1f MB", mb)
    }
}
