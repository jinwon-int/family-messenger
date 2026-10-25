// 단축어 동작 「에이전트에게 보내기」(화면 위임 1단계 — 텍스트). 뒷면 탭 → 단축어(화면 내용·클립보드) → 이 동작 →
// 한데 에이전트 방에 종단 간 암호화로 보낸다. 답은 그 노드 에이전트가 같은 방으로 보낸다.
//
// 결정: `openAppWhenRun = true` — 앱 프로세스의 같은 모델(`AppModelHost.shared`)로만 보낸다. 별도 확장을 두면 제3의 작성자가
// 생기고 내 글 평문(`unconfirmed`)이 앱과 공유되지 않는다(CONTRACTS §3.1 단일 작성자, NOTES-FINALIZER D4).
// 이 파일은 Linux 스모크(scripts/linux-smoke.sh) 복사 대상이 아니다 — AppIntents 는 Apple 전용.
import AppIntents
import FamilyMLSCore

/// 보낼 수 있는 에이전트 방. ID = 대화방 ID(노드 개인방은 노드 이름, 공명은 `family-acc`).
struct AgentRoomEntity: AppEntity {
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "에이전트 방"
    static var defaultQuery = AgentRoomQuery()

    let id: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: LocalizedStringResource(stringLiteral: Strings.roomLabel(id)))
    }
}

struct AgentRoomQuery: EntityQuery {
    @MainActor
    func entities(for identifiers: [String]) async throws -> [AgentRoomEntity] {
        identifiers.map(AgentRoomEntity.init(id:))
    }

    /// 단축어 편집기의 선택지: 이 기기가 참여한 방 중 에이전트 방. 앱이 아직 시작 전이면 시작해서 방 목록을 읽는다.
    @MainActor
    func suggestedEntities() async throws -> [AgentRoomEntity] {
        let model = AppModelHost.shared
        await model.bootstrap()
        return AgentRooms.pick(from: model.listedRooms.map(\.room)).map(AgentRoomEntity.init(id:))
    }
}

/// 에이전트 방 고르기 — 순수 함수(테스트 대상). 노드 개인방(`Strings.agentNames` 키)과 공명 방(`family-acc`).
enum AgentRooms {
    static func pick(from rooms: [String]) -> [String] {
        rooms.filter { Strings.agentNames[$0] != nil || $0 == "family-acc" }
    }
}

struct SendToAgentIntent: AppIntent {
    static var title: LocalizedStringResource = "에이전트에게 보내기"
    static var description = IntentDescription("한데 에이전트 방에 글을 종단 간 암호화로 보냅니다. 답은 한데 대화방으로 옵니다.")
    static var openAppWhenRun: Bool = true

    @Parameter(title: "에이전트 방")
    var room: AgentRoomEntity

    @Parameter(title: "내용", inputOptions: String.IntentInputOptions(multiline: true))
    var text: String

    static var parameterSummary: some ParameterSummary {
        Summary("\(\.$room)에게 \(\.$text) 보내기")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        switch await AppModelHost.shared.sendFromShortcut(room: room.id, text: text) {
        case .sent:
            return .result(dialog: IntentDialog(stringLiteral: Strings.shortcutSent(room.id)))
        case .queued:
            return .result(dialog: IntentDialog(stringLiteral: Strings.shortcutQueued(room.id)))
        case .failed(let reason):
            throw SendToAgentFailure(reason: reason)
        }
    }
}

/// 실패는 단축어를 멈추게 던진다(자동화가 실패를 알아차리게) — 사유 문장을 그대로 보인다.
struct SendToAgentFailure: Error, CustomLocalizedStringResourceConvertible {
    let reason: String
    var localizedStringResource: LocalizedStringResource { LocalizedStringResource(stringLiteral: reason) }
}
