// "이 기기 지우기"(§9-5) 문구. 앱 화면 전용 — NSE 소스 목록(project.yml)에 넣지 말 것.
import Foundation

extension Strings {
    static let wipeTitle = "이 기기 지우기"
    // 문구는 docs/hande/delete-account.md 「1. 이 기기의 자료」·Android `wipeDeviceHint` 와 같은 뜻(#584): 서버 쪽 기록은 「계정 및 데이터 삭제」 안내로.
    static let wipeHint = "로그아웃과 다릅니다. 이 기기의 암호화 상태(서명키)·대화 기록·기기 ID 를 모두 지우고 새 기기가 됩니다. 서버의 기기 기록은 이 앱이 지울 수 없으며 위 「계정 및 데이터 삭제」 안내로 운영자에게 요청합니다."
    static let wipeWarning = """
    이 기기는 새 기기 ID 와 새 지문을 갖게 됩니다. 되돌릴 수 없습니다.
    • 지금 기기 ID 는 다시 쓸 수 없습니다. 운영자가 옛 ID 를 폐기하고 새 ID 를 다시 등록해야 합니다.
    • 모든 대화방에 다시 초대받아야 합니다.
    • 이 기기의 대화 기록과 암호화 이력은 복구할 수 없습니다(다른 기기의 기록은 그대로입니다).
    계속할까요?
    """
    static let wipeConfirmButton = "지우고 새 기기로 시작"
    static let wipeDone = "지웠습니다. 새 기기로 로그인한 뒤 등록 정보를 운영자에게 다시 전달하세요."
    static func wipeFailed(_ reason: String) -> String { "지우지 못했습니다: \(reason). 앱을 완전히 종료한 뒤 다시 시도하세요." }
}
