// 에이전트 대화 화면 조각(#405 P1): 에이전트 카드(마크다운) · 승인 카드(허락/거절) · 생각 중 · "내 마지막 말" 바.
// 판정은 모두 Core(AgentMarkdown·AgentApproval·AgentThinking·LastSent)가 하고, 여기는 그리기만 한다.
// 받은 글은 신뢰하지 않는다(웹 rich-text.js 원칙): 링크는 눌러도 열리지 않게 글자로만 두고, 이미지는 그리지 않는다.
import SwiftUI
import Combine
import FamilyMLSCore

/// 에이전트 색(앱 아이콘의 파란 점). P2 테마에서 팔레트로 옮긴다.
enum AgentPalette {
    static let accent = Color(red: 0.38, green: 0.65, blue: 0.98)
    static let cardFill = Color(red: 0.38, green: 0.65, blue: 0.98).opacity(0.10)
    static let cardStroke = Color(red: 0.38, green: 0.65, blue: 0.98).opacity(0.35)
    static let ember = Color(red: 0.96, green: 0.62, blue: 0.26)
}

/// 에이전트 이름 머리줄: ● 공명 · 에이전트
struct AgentHeader: View {
    let name: String
    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(AgentPalette.accent).frame(width: 8, height: 8)
                .shadow(color: AgentPalette.accent.opacity(0.8), radius: 3)
            Text(name).font(.caption.weight(.semibold))
            Text("· \(Strings.agentBadge)").font(.caption).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}

/// 에이전트 답장: 말풍선 대신 화면 폭 카드 + 마크다운 블록.
struct AgentMessageCard: View {
    let name: String
    let text: String
    var time: Date? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            AgentHeader(name: name)
            MarkdownBlocksView(blocks: AgentMarkdown.parse(text))
            // 시간은 카드 오른쪽 아래(오너 2026-10-30 — 전에는 머리줄 오른쪽 위). 글을 다 읽은 자리에 둔다.
            if let time {
                Text(Strings.messageTime(time)).font(.caption2).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 16).fill(AgentPalette.cardFill))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(AgentPalette.cardStroke, lineWidth: 1))
        // 복사는 카드 바깥(MessageRow)의 꾹 누르기 메뉴 「복사」·「선택해서 복사」가 맡는다(2026-10-30). 종전 `.textSelection(.enabled)` 는
        // 블록(문단)마다 따로 전체 복사만 됐고, 그 길게 누르기가 카드 메뉴를 가로채서 뺐다.
        .contentShape(.contextMenuPreview, RoundedRectangle(cornerRadius: 16))
    }
}

struct MarkdownBlocksView: View {
    let blocks: [AgentMarkdown.Block]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
        }
    }

    @ViewBuilder private func blockView(_ block: AgentMarkdown.Block) -> some View {
        switch block {
        case .heading(let level, let text):
            InlineMarkdown(text).font(level <= 1 ? .title3.weight(.bold) : level == 2 ? .headline : .subheadline.weight(.semibold))
        case .paragraph(let text):
            InlineMarkdown(text).font(.callout)
        case .list(let items):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(item.marker ?? "•").font(.callout).foregroundStyle(.secondary)
                            .frame(minWidth: item.marker == nil ? 10 : 18, alignment: .trailing)
                        InlineMarkdown(item.text).font(.callout)
                    }
                    .padding(.leading, CGFloat(item.level) * 14)
                }
            }
        case .table(let header, let rows):
            MarkdownTable(header: header, rows: rows)
        case .code(let text):
            ScrollView(.horizontal, showsIndicators: false) {
                Text(text).font(.system(.caption, design: .monospaced)).padding(8)
            }
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.06)))
        case .quote(let text):
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 1).fill(AgentPalette.accent.opacity(0.6)).frame(width: 3)
                InlineMarkdown(text).font(.callout).foregroundStyle(.secondary)
            }
        case .rule:
            Divider()
        }
    }
}

/// 표: 가로로 넘치면 옆으로 민다. 머리줄은 흐린 글씨, 행 사이 가는 선.
struct MarkdownTable: View {
    let header: [String]
    let rows: [[String]]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
                GridRow {
                    ForEach(Array(header.enumerated()), id: \.offset) { _, cell in
                        InlineMarkdown(cell).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    }
                }
                Divider()
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    GridRow {
                        ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                            InlineMarkdown(cell).font(.caption)
                        }
                    }
                }
            }
            .padding(.vertical, 2)
        }
    }
}

/// 줄 안 서식(굵게·기울임·`코드`·취소선). 링크는 글자만 남기고 이동을 끈다. 해석이 안 되면 원문.
struct InlineMarkdown: View {
    let source: String
    init(_ source: String) { self.source = source }

    var body: some View { Text(Self.attributed(source)) }

    static func attributed(_ source: String) -> AttributedString {
        guard AgentMarkdown.hasInlineMarkup(source),
              var value = try? AttributedString(markdown: source, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))
        else { return AttributedString(source) }
        let linked = value.runs.filter { $0.link != nil }.map(\.range)
        for range in linked { value[range].link = nil }
        return value
    }
}

/// 봇의 `⚠️ 승인 필요 #n` 을 카드로. 버튼은 「승인 n」/「거절 n」 글을 대신 보낸다(봇이 owner actor 의 답만 받는다).
struct ApprovalCard: View {
    let name: String
    let request: AgentApproval.Request
    let state: AgentApproval.State
    let enabled: Bool
    var time: Date? = nil
    let decide: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("🔥")
                Text(Strings.approvalTitle(name)).font(.subheadline.weight(.semibold))
                Spacer()
                Text("#\(request.number)").font(.caption).foregroundStyle(.secondary)
            }
            if !request.summary.isEmpty {
                Text(request.summary).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
            }
            switch state {
            case .open:
                HStack(spacing: 8) {
                    Button { decide(true) } label: { Text(Strings.approvalAllow).frame(maxWidth: .infinity) }
                        .buttonStyle(.borderedProminent).tint(AgentPalette.ember)
                    Button { decide(false) } label: { Text(Strings.approvalDeny).frame(maxWidth: .infinity) }
                        .buttonStyle(.bordered)
                }
                .disabled(!enabled)
            case .answered:
                Label(Strings.approvalSending, systemImage: "hourglass").font(.footnote).foregroundStyle(.secondary)
            case .allowed:
                Label(Strings.approvalAllowed, systemImage: "checkmark.circle.fill").font(.footnote).foregroundStyle(.green)
            case .denied:
                Label(Strings.approvalDenied, systemImage: "xmark.circle.fill").font(.footnote).foregroundStyle(.red)
            case .closed:
                Label(Strings.approvalClosed, systemImage: "minus.circle").font(.footnote).foregroundStyle(.secondary)
            }
            // 시간은 카드 오른쪽 아래(오너 2026-10-30, AgentMessageCard 와 같은 자리).
            if let time {
                Text(Strings.messageTime(time)).font(.caption2).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 16).fill(AgentPalette.ember.opacity(state == .open ? 0.14 : 0.06)))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(AgentPalette.ember.opacity(state == .open ? 0.6 : 0.25), lineWidth: 1))
    }
}

/// "공명의 답 기다리는 중" — 정적 표시. 앱 추정(`AgentThinking`)이라 작업 중을 연상시키는 애니메이션은 쓰지 않는다(#601).
/// 실제 작업 신호(status-v1 `⏳` 말풍선, #560)가 생기면 그쪽이 "일하는 중"을 보여 준다.
struct AwaitingReplyRow: View {
    let name: String

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(AgentPalette.accent.opacity(0.5)).frame(width: 8, height: 8)
            Text(Strings.agentAwaitingReply(name)).font(.caption).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}

/// 대화창 위 "내 마지막 말" 바(웹 last-sent.js): 누르면 그 메시지로 간다.
struct LastSentBar: View {
    let lastSent: LastSent
    let jump: () -> Void

    var body: some View {
        Button(action: jump) {
            HStack(spacing: 8) {
                Image(systemName: "arrow.turn.down.right").font(.caption).foregroundStyle(AgentPalette.ember)
                VStack(alignment: .leading, spacing: 1) {
                    Text(Strings.lastSentLabel).font(.caption2).foregroundStyle(.secondary)
                    Text(preview).font(.footnote).lineLimit(1)
                }
                Spacer(minLength: 8)
                Text(Strings.lastSentReplies(lastSent.repliesAfter)).font(.caption).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.ultraThinMaterial)
        }
        .buttonStyle(.plain)
    }

    private var preview: String {
        lastSent.record.kind.isFile ? Strings.attachmentImage : lastSent.record.body.replacingOccurrences(of: "\n", with: " ")
    }
}
