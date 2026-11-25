// Siri·단축어 「공명에게 묻기」·「공명에게 기록 맡기기」(AskAgentIntent·RecordNoteIntent) 문구. 화면 전용 — Linux 스모크 복사 목록에 넣지 않는다.
import Foundation
extension Strings {
    /// 금지어(승인·머지·배포·삭제·보내기 등)가 든 글은 보내지 않는다 — 그런 일은 대화방에서 사람이 직접 한다.
    static let siriRisky = "승인·머지·배포·삭제·보내기 같은 일은 Siri로 맡기지 않아요. 한데 대화방에서 직접 해 주세요."
    static func siriTooLong(_ limit: Int) -> String { "너무 길어요. \(limit)자 안으로 줄여 주세요." }
    /// 시간 안에 답이 왔다 — 앞부분만 보이고(잘렸으면 「전체는 한데에서」), 전체는 방에 있다.
    static func siriAnswered(_ room: String, _ snippet: String) -> String { "\(roomLabel(room)): \(snippet)" }
    static let siriMoreInApp = "… (전체는 한데에서)"
    /// 시간 안에 답이 오지 않았다 — 성공으로 끝내고 다시 보내지 않는다(중복 질문 방지).
    static func siriWaiting(_ room: String) -> String {
        "\(roomLabel(room))에게 물었어요. 아직 생각 중이라 답은 한데 「\(roomLabel(room))」 방과 알림으로 옵니다."
    }
    static func siriNoted(_ room: String) -> String { "\(roomLabel(room))에게 기록을 맡겼어요. 한데 「\(roomLabel(room))」 방에 남았습니다." }
}
