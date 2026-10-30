// status-v1(#560, STATUS-V1.md §3): 에이전트 작업 상태 임시 말풍선 — 매트릭스 「⏳ Working — 10s | Bash: …」 한 줄의 한데 판.
// 방 화면 타임라인 맨 아래, 보낸이마다 하나(`AppModel.agentStatuses`). 새 줄이 오면 본문만 바뀌고 답이 오면 사라진다(저장하지 않는다).
import SwiftUI

extension Strings {
    /// 화면 낭독기 라벨: 「공명 작업 상태, ⏳ Working — 10s」. 5초마다 바뀌는 본문을 따로 알리지는 않는다(라이브 영역 아님).
    static func agentStatusAccessibility(_ name: String, _ text: String) -> String { "\(name) 작업 상태, \(text)" }
}

struct AgentStatusRow: View {
    let name: String
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Circle().fill(AgentPalette.accent).frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(.caption2).foregroundStyle(.secondary)
                Text(text).font(.footnote).foregroundStyle(.secondary).lineLimit(3)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14).fill(AgentPalette.cardFill.opacity(0.6)))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(AgentPalette.cardStroke, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Strings.agentStatusAccessibility(name, text))
    }
}
