// Siri·단축어 「공명에게 묻기」·「공명에게 기록 맡기기」(App Intents 1단계). 읽기·덧붙이기만 연다 —
// 보내기(남에게)·삭제·승인·머지·배포는 열지 않는다. 규칙(금지어·머리글·기다리기)은 `AgentAsk`, 송신은 기존 `sendFromShortcut` 경로.
//
// 결정: `SendToAgentIntent` 와 같이 `openAppWhenRun = true` — 앱 프로세스의 같은 모델(`AppModelHost.shared`)로만 보낸다(단일 작성자,
// CONTRACTS §3.1 · NOTES-FINALIZER D4). 배경 실행(앱을 띄우지 않음)은 공유 확장 직접 송신(#669) 패턴을 재사용하는 후속 과제다.
// Siri AI 도구 표시(`.tool`)·Spotlight 색인(`IndexedEntity`)은 후속 단계(새 SDK 분기) — 도구 Intent 를 하나라도 넣으면 App Shortcuts 가
// Siri 에서 빠지므로 이번에는 넣지 않는다.
// 이 파일은 Linux 스모크(scripts/linux-smoke.sh) 복사 대상이 아니다 — AppIntents 는 Apple 전용.
import AppIntents
import FamilyMLSCore

struct AskAgentIntent: AppIntent {
    static var title: LocalizedStringResource = "공명에게 묻기"
    static var description = IntentDescription(
        "한데 에이전트 방(기본 공명)에 질문을 종단 간 암호화로 보내고 답을 잠시 기다립니다. 늦으면 답은 그 방과 알림으로 옵니다. 승인·머지·배포·삭제·보내기 같은 말이 든 질문은 보내지 않습니다.")
    static var openAppWhenRun: Bool = true

    @Parameter(title: "질문", inputOptions: String.IntentInputOptions(multiline: true), requestValueDialog: "무엇을 물어볼까요?")
    var question: String

    @Parameter(title: "에이전트 방", description: "비우면 공명 방")
    var agent: AgentRoomEntity?

    static var parameterSummary: some ParameterSummary {
        Summary("\(\.$agent)에게 \(\.$question) 묻기")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let room = agent?.id ?? AgentAsk.defaultRoom
        let model = AppModelHost.shared
        let outcome = await AgentAsk.run(.question, text: question,
                                         send: { await model.shortcutSend(room: room, text: $0) },
                                         awaitReply: { await model.awaitAgentReply(room: room, after: $0, timeout: $1) })
        if let reason = AgentAsk.failure(outcome) { throw SendToAgentFailure(reason: reason) }
        return .result(value: AgentAsk.value(outcome), dialog: IntentDialog(stringLiteral: AgentAsk.dialog(outcome, room: room)))
    }
}

struct RecordNoteIntent: AppIntent {
    static var title: LocalizedStringResource = "공명에게 기록 맡기기"
    static var description = IntentDescription(
        "한데 공명 방에 기록할 내용을 종단 간 암호화로 보냅니다. 공명은 덧붙이기만 합니다. 승인·머지·배포·삭제·보내기 같은 말이 든 글은 보내지 않습니다.")
    static var openAppWhenRun: Bool = true

    @Parameter(title: "내용", inputOptions: String.IntentInputOptions(multiline: true), requestValueDialog: "무엇을 기록할까요?")
    var text: String

    static var parameterSummary: some ParameterSummary {
        Summary("공명에게 \(\.$text) 기록 맡기기")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let room = AgentAsk.defaultRoom
        let model = AppModelHost.shared
        let outcome = await AgentAsk.run(.note, text: text,
                                         send: { await model.shortcutSend(room: room, text: $0) },
                                         awaitReply: { _, _ in nil })
        if let reason = AgentAsk.failure(outcome) { throw SendToAgentFailure(reason: reason) }
        return .result(dialog: IntentDialog(stringLiteral: AgentAsk.dialog(outcome, room: room)))
    }
}

/// Spotlight·동작 버튼·Siri(앱 이름과 함께)에서 바로 쓰는 문구. 문구마다 앱 이름(`.applicationName`)이 한 번 있어야 한다.
/// 한국어 문구는 `ko.lproj/AppShortcuts.strings` 에도 같은 키로 둔다(프로젝트 개발 언어와 무관하게 한국어 Siri 가 읽게).
struct HandeAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: AskAgentIntent(), phrases: [
            "\(.applicationName)에서 공명에게 묻기",
            "\(.applicationName)에서 공명에게 물어보기",
            "\(.applicationName)에서 에이전트에게 묻기",
        ])
        AppShortcut(intent: RecordNoteIntent(), phrases: [
            "\(.applicationName)에서 공명에게 기록 맡기기",
            "\(.applicationName)에서 공명에게 기록하기",
        ])
    }
}
