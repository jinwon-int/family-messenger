// status-v1(#560, STATUS-V1.md §3): 에이전트 작업 상태 임시 말풍선 — 매트릭스 「⏳ Working — 10s | Bash: …」 한 줄의 한데 판.
// 방 화면 타임라인 맨 아래, 보낸이마다 하나(`AppModel.agentStatuses`). 새 줄이 오면 본문만 바뀌고 답이 오면 사라진다(저장하지 않는다).
// 2026-10-30 오너: 흐리게(반투명) 보이지 않게 — 본문은 일반 글 색, 이름은 에이전트 색, 점선 테두리로만 임시 말풍선임을 구분한다.
import SwiftUI

extension Strings {
    /// 화면 낭독기 라벨: 「공명 작업 상태, ⏳ Working — 10s」. 5초마다 바뀌는 본문을 따로 알리지는 않는다(라이브 영역 아님).
    static func agentStatusAccessibility(_ name: String, _ text: String) -> String { "\(name) 작업 상태, \(text)" }
    /// 대화 목록 줄의 작업 상태(미리보기 자리): 「작업 중, ⏳ Working — 10s」.
    static func agentWorkingListAccessibility(_ text: String) -> String { "작업 중, \(text)" }
}

struct AgentStatusRow: View {
    let name: String
    let text: String
    /// 디자인 1차: 에이전트 색·선 굵기는 테마(밤/낮불)를 따른다.
    @Environment(\.hande) private var p

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            SeatDot(agent: true, size: 8)
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(.caption2.weight(.semibold)).foregroundStyle(p.agentText)
                Text(text).font(.footnote).foregroundStyle(p.ink).lineLimit(3)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14).fill(p.agentFill))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(p.agentStroke, style: StrokeStyle(lineWidth: p.lineWidth, dash: [4, 3])))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Strings.agentStatusAccessibility(name, text))
    }
}
