// 에이전트 대화 화면 조각(#405 P1): 에이전트 카드(마크다운) · 승인 카드(허락/거절) · 생각 중 · "내 마지막 말" 바.
// 판정은 모두 Core(AgentMarkdown·AgentApproval·LastSent)가 하고, 여기는 그리기만 한다.
// 받은 글은 신뢰하지 않는다(웹 rich-text.js 원칙): 링크는 눌러도 열리지 않게 글자로만 두고, 이미지는 그리지 않는다.
import SwiftUI
import Combine
import FamilyMLSCore

/// 에이전트 색(앱 아이콘의 파란 점) — 디자인 1차부터 `Hande`(밤 토큰)의 별칭. 테마를 따라야 하는 뷰는 `@Environment(\.hande)`.
enum AgentPalette {
    static let accent = Hande.agent
    static let cardFill = Hande.agent.opacity(0.10)
    static let cardStroke = Hande.agent.opacity(0.35)
    static let ember = Hande.ember
}

/// 에이전트 이름 머리줄: ● 공명 · 불지기
struct AgentHeader: View {
    let name: String
    @Environment(\.hande) private var p
    var body: some View {
        HStack(spacing: 6) {
            SeatDot(agent: true, size: 8)
            Text(name).font(.caption.weight(.semibold)).foregroundStyle(p.agentText)
            Text("· \(Strings.agentBadge)").font(.caption).foregroundStyle(p.agentText.opacity(0.8))
        }
        .accessibilityElement(children: .combine)
    }
}

/// 에이전트 답장: 말풍선 대신 화면 폭 카드 + 마크다운 블록. 밤 = 파랑 fill 10% / stroke 35%, 낮불 = 흰 면 + 파랑 점선(1d).
struct AgentMessageCard: View {
    let name: String
    let text: String
    var time: Date? = nil
    @Environment(\.hande) private var p

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            AgentHeader(name: name)
            MarkdownBlocksView(blocks: AgentMarkdown.parse(text))
            // 시간은 카드 오른쪽 아래(오너 2026-10-30 — 전에는 머리줄 오른쪽 위). 글을 다 읽은 자리에 둔다.
            if let time {
                Text(Strings.messageTime(time)).font(.caption2).foregroundStyle(p.inkDim)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .foregroundStyle(p.ink)
        .background(RoundedRectangle(cornerRadius: 18).fill(p.agentFill))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(p.agentStroke, style: StrokeStyle(lineWidth: p.lineWidth, dash: p.agentDash)))
        // 복사는 카드 바깥(MessageRow)의 꾹 누르기 메뉴 「복사」·「선택해서 복사」가 맡는다(2026-10-30). 종전 `.textSelection(.enabled)` 는
        // 블록(문단)마다 따로 전체 복사만 됐고, 그 길게 누르기가 카드 메뉴를 가로채서 뺐다.
        .contentShape(.contextMenuPreview, RoundedRectangle(cornerRadius: 18))
    }
}

struct MarkdownBlocksView: View {
    let blocks: [AgentMarkdown.Block]
    @Environment(\.hande) private var p

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
                RoundedRectangle(cornerRadius: 1).fill(p.agent.opacity(0.6)).frame(width: 3)
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
/// 디자인 1차 1c 허락 카드: 에이전트 파랑 테두리 + fill · 머리 「공명이 허락을 구합니다」 · 본문 줄(머리말 + 내용) · 허락(불)/거절(면) 48pt
/// → 처리 기다림 → 결과(글자·아이콘으로만, 초록/빨강 없음). 봇이 대상·내용·영향 3줄을 보내게 되면 본문 줄만 늘린다.
struct ApprovalCard: View {
    let name: String
    let request: AgentApproval.Request
    let state: AgentApproval.State
    let enabled: Bool
    var time: Date? = nil
    let decide: (Bool) -> Void
    @Environment(\.hande) private var p

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                SeatDot(agent: true, size: 8)
                Text(Strings.approvalTitle(name)).font(.subheadline.weight(.semibold)).foregroundStyle(p.agentText)
                Spacer()
                Text("#\(request.number)").font(.caption).foregroundStyle(p.inkDim)
            }
            if !request.summary.isEmpty {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(Strings.approvalSummaryLabel).font(.subheadline).foregroundStyle(p.inkDim).frame(width: 40, alignment: .leading)
                    Text(request.summary).font(.subheadline).foregroundStyle(p.ink).textSelection(.enabled)
                }
            }
            switch state {
            case .open:
                HStack(spacing: 10) {
                    Button { decide(true) } label: { Text(Strings.approvalAllow) }
                        .buttonStyle(HandePrimaryButtonStyle())
                    Button { decide(false) } label: { Text(Strings.approvalDeny) }
                        .buttonStyle(HandeSecondaryButtonStyle())
                }
                .disabled(!enabled)
            case .answered:
                Label(Strings.approvalSending, systemImage: "hourglass").font(.footnote).foregroundStyle(p.inkDim)
            case .allowed:
                Label(Strings.approvalAllowed, systemImage: "checkmark.circle").font(.footnote).foregroundStyle(p.ink)
            case .denied:
                Label(Strings.approvalDenied, systemImage: "xmark.circle").font(.footnote).foregroundStyle(p.ink)
            case .closed:
                Label(Strings.approvalClosed, systemImage: "minus.circle").font(.footnote).foregroundStyle(p.inkDim)
            }
            // 시간은 카드 오른쪽 아래(오너 2026-10-30, AgentMessageCard 와 같은 자리).
            if let time {
                Text(Strings.messageTime(time)).font(.caption2).foregroundStyle(p.inkDim)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 20).fill(p.isDay ? p.surface : p.agent.opacity(state == .open ? 0.08 : 0.05)))
        .overlay(RoundedRectangle(cornerRadius: 20).stroke(state == .open ? p.agent.opacity(p.isDay ? 1 : 0.45) : p.agentStroke,
                                                          lineWidth: state == .open ? p.lineWidth + 0.5 : p.lineWidth))
    }
}

/// agent-choices-v1(#620 · 복수 선택 #624): 에이전트 글 끝 번호 선택지 — 말풍선 아래 카드. 행을 누르면 그 행 체크 토글(여러 개 가능),
/// 하나라도 체크돼 있으면 [보내기]가 고른 번호를 넘기고, 방 화면이 줄마다 `N. 라벨`(`AgentChoices.composeReply`)을 평소 전송 경로로 보낸다.
/// 판정·상태는 Core `AgentChoices`, 여기는 그리기만.
/// open = 선택 카드 · answered(S) = 한 줄 「✓ N번 선택 — 라벨」 / 「✓ 1, 3번 선택 — 라벨1 · 라벨3」 · closed = 그리지 않는다.
struct AgentChoicesCard: View {
    let choices: AgentChoices
    let state: AgentChoices.State
    /// 방이 준비됐고 보내는 중이 아니다(보내는 동안 카드 비활성).
    let enabled: Bool
    /// 체크한 번호 — 대화방이 글 seq 별로 들고 있다(§3.1 #629: ⌥1~9 단축키도 같은 선택을 토글한다).
    @Binding var selected: Set<Int>
    /// 고른 번호(오름차순).
    let send: ([Int]) -> Void
    @Environment(\.hande) private var p

    var body: some View {
        switch state {
        case .open:
            VStack(alignment: .leading, spacing: 4) {
                openCard
                // §3.1(#629): 하드웨어 키보드가 있으면 카드 아래 작은 안내.
                if HardwareKeyboard.isConnected {
                    Text(Strings.choiceKeyHint)
                        .font(.caption2)
                        .foregroundStyle(p.inkDim)
                        .padding(.horizontal, 4)
                }
            }
        case .answered(let numbers):
            Text(Strings.choiceAnswered(numbers, labels: numbers.map { choices.label(of: $0) ?? "" }))
                .font(.footnote)
                .foregroundStyle(p.inkDim)
                .lineLimit(1)
                .truncationMode(.tail)
                .padding(.horizontal, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .closed:
            EmptyView()
        }
    }

    private var openCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(choices.items, id: \.number) { item in
                row(item)
            }
            Button {
                if !selected.isEmpty { send(selected.sorted()) }
            } label: {
                Text(Strings.choiceSend)
            }
            .buttonStyle(HandePrimaryButtonStyle())
            .disabled(selected.isEmpty)
            .accessibilityLabel(Strings.choiceSendA11y(selected.sorted()))
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Hande.radiusM).fill(p.isDay ? p.surface : p.agent.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: Hande.radiusM).stroke(p.agentStroke, lineWidth: p.lineWidth))
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.6)
    }

    /// 행 = 체크 상자(둥근 사각 — 복수 선택 관례) + 번호 + 라벨(최대 3줄) + 권장 알약. 선택 표시는 에이전트 파랑(주황은 보내기 버튼만).
    private func row(_ item: AgentChoices.Item) -> some View {
        let isSelected = selected.contains(item.number)
        let isRecommended = choices.recommended == item.number
        return Button {
            if isSelected { selected.remove(item.number) } else { selected.insert(item.number) }
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                    .font(.body)
                    .foregroundStyle(isSelected ? p.agent : p.inkDim)
                Text("\(item.number)")
                    .font(.callout.weight(.semibold).monospacedDigit())
                    .foregroundStyle(p.ink)
                Text(item.label)
                    .font(.callout)
                    .foregroundStyle(p.ink)
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if isRecommended {
                    Text(Strings.choiceRecommended)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(p.agentText)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(p.agent.opacity(0.14)))
                        .overlay(Capsule().stroke(p.agent.opacity(0.5), lineWidth: 1))
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: Hande.radiusS).fill(isSelected ? p.agent.opacity(0.12) : Color.clear))
            .overlay(RoundedRectangle(cornerRadius: Hande.radiusS).stroke(isSelected ? p.agent : p.stroke, lineWidth: p.lineWidth))
            .contentShape(RoundedRectangle(cornerRadius: Hande.radiusS))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Strings.choiceRowA11y(item.number, label: item.label, recommended: isRecommended))
        .accessibilityValue(Strings.choiceRowA11yValue(isSelected))
        .accessibilityHint(Strings.choiceA11yHint)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}

/// 대화창 위 "내 마지막 말" 바(웹 last-sent.js). 오너 2026-11-01: 한 줄만 보이던 것을 웹처럼 펼쳐 **이전에 내가 한 말**(오늘 말 전부,
/// 적으면 지난 날 말로 10개까지 — `LastSent.earlier`)을 보인다.
/// - 접힘(기본)에서 바를 누르면 이동 대신 펼친다. 이전 말이 없으면 예전처럼 바로 그 메시지로 간다.
/// - 펼친 뒤 바를 누르면 가장 최근 내 말로, 목록 항목을 누르면 그 말로 간다. 접기는 오른쪽 화살표로만(웹과 같음).
/// - 펼침 상태는 방별로 기억한다(웹 `hande:lastSent:collapsed:<방>` 과 같은 뜻, 기기 로컬).
/// - 목록은 높이 상한 안에서 스크롤 — 펼쳐도 대화가 가려지지 않게.
struct LastSentBar: View {
    let room: RoomID
    let lastSent: LastSent
    let earlier: [LastSent]
    /// 그 메시지(seq)로 스크롤.
    let jump: (Int64) -> Void
    @Environment(\.hande) private var p
    @State private var expanded: Bool

    /// 펼친 목록이 차지하는 최대 높이(pt) — 10개 이상이어도 대화 칸을 남긴다.
    static let earlierMaxHeight: CGFloat = 260
    /// 이 개수까지는 스크롤 없이 그린다(한 줄 ≈ 40pt → 상한 안).
    static let earlierUnscrolledMax = 5

    init(room: RoomID, lastSent: LastSent, earlier: [LastSent], jump: @escaping (Int64) -> Void) {
        self.room = room
        self.lastSent = lastSent
        self.earlier = earlier
        self.jump = jump
        _expanded = State(initialValue: UserDefaults.standard.bool(forKey: Self.expandedKey(room)))
    }

    static func expandedKey(_ room: RoomID) -> String { "hande.lastSent.expanded.\(room)" }

    private var showsEarlier: Bool { expanded && !earlier.isEmpty }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Button(action: tapBar) {
                    HStack(spacing: 8) {
                        Image(systemName: "arrow.turn.down.right").font(.caption).foregroundStyle(p.ember)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(Strings.lastSentLabel).font(.caption2).foregroundStyle(.secondary)
                            Text(Self.preview(lastSent.record)).font(.footnote).lineLimit(1)
                        }
                        Spacer(minLength: 8)
                        Text(Strings.lastSentReplies(lastSent.repliesAfter)).font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(.leading, 14)
                    .padding(.trailing, earlier.isEmpty ? 14 : 4)
                    .padding(.vertical, 8)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityHint(earlier.isEmpty || expanded ? Strings.lastSentJumpHint : Strings.lastSentExpand)
                .accessibilityIdentifier("last-sent-jump")
                if !earlier.isEmpty {
                    Button { setExpanded(!expanded) } label: {
                        Image(systemName: expanded ? "chevron.up" : "chevron.down")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 44, height: 40)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(expanded ? Strings.lastSentCollapse : Strings.lastSentExpand)
                    .accessibilityIdentifier("last-sent-toggle")
                }
            }
            if showsEarlier {
                Divider()
                // 몇 개뿐이면 그대로, 많으면(보통 10개 이상) 높이 상한 안에서 스크롤 — ScrollView 는 내용이 짧아도 상한까지 늘어나므로 나눈다.
                Group {
                    if earlier.count > Self.earlierUnscrolledMax {
                        ScrollView { earlierList }.frame(height: Self.earlierMaxHeight)
                    } else {
                        earlierList
                    }
                }
                .accessibilityElement(children: .contain)
                .accessibilityLabel(Strings.lastSentEarlierRegion)
                .accessibilityIdentifier("last-sent-earlier")
            }
        }
        .background(.ultraThinMaterial)
    }

    private var earlierList: some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(earlier, id: \.record.seq) { item in
                Button { jump(item.record.seq) } label: { earlierRow(item) }
                    .buttonStyle(.plain)
                    .accessibilityHint(Strings.lastSentJumpHint)
                Divider().padding(.leading, 14)
            }
        }
    }

    private func earlierRow(_ item: LastSent) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(Self.preview(item.record)).font(.footnote).lineLimit(2)
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 1) {
                Text(Strings.lastSentReplies(item.repliesAfter)).font(.caption2).foregroundStyle(.secondary)
                Text(Strings.lastSentTime(item.record.receivedAt)).font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .contentShape(Rectangle())
    }

    private func tapBar() {
        if earlier.isEmpty || expanded { jump(lastSent.record.seq) } else { setExpanded(true) }
    }

    private func setExpanded(_ next: Bool) {
        withAnimation(.easeOut(duration: 0.15)) { expanded = next }
        if next { UserDefaults.standard.set(true, forKey: Self.expandedKey(room)) }
        else { UserDefaults.standard.removeObject(forKey: Self.expandedKey(room)) }
    }

    static func preview(_ record: MessageRecord) -> String {
        record.kind.isFile ? Strings.attachmentImage : record.body.replacingOccurrences(of: "\n", with: " ")
    }
}
