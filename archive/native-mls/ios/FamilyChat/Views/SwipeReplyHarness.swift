// 밀어서 답장 재현 화면(DEBUG 전용, 실행 인자 `-swipeReplyHarness`). 오너 2026-11-10 「최신 말풍선은 되는데 두 번째부터 잘 안 됨」을
// 시뮬레이터 UI 테스트(FamilyChatUITests)로 재현·검증한다. 실제 `MessageRow`·`SwipeToReply` 와 방 타임라인의 제스처 구성
// (ScrollView 위 동시 DragGesture 두 개 · 바닥 앵커)을 그대로 쓰고, 어느 행이 답장됐는지와 팬 판정 기록(`SwipeReplyTrace`)을 화면에 낸다.
#if DEBUG
import SwiftUI
import FamilyMLSCore

struct SwipeReplyHarness: View {
    /// 행 수(`-swipeReplyRows N`, 기본 8 — 한 화면에 다 들어가는 수).
    let rows: Int
    @State private var replied = "none"
    /// 판정 기록은 참조 상자에 모은다 — 끌기 도중 상태를 바꿔 화면을 다시 그리면 재현 조건이 달라진다. 「dump」를 눌러야 보인다.
    @State private var box = TraceBox()
    @State private var shown = ""
    @State private var followLatest = true

    init() {
        let args = ProcessInfo.processInfo.arguments
        if let i = args.firstIndex(of: "-swipeReplyRows"), i + 1 < args.count, let n = Int(args[i + 1]) {
            rows = max(1, n)
        } else {
            rows = 8
        }
    }

    private var items: [AppModel.TimelineItem] {
        (1...rows).map { n in
            let mine = n % 3 == 0
            let record = MessageRecord(room: "harness", seq: Int64(n), senderDevice: mine ? "me-phone" : "mom-phone",
                                       clientId: "c\(n)", kind: .text,
                                       body: "메시지 \(n) — 밀어서 답장 재현용 문장입니다",
                                       attachment: nil, receivedAt: Date(timeIntervalSince1970: 1_800_000_000 + Double(n) * 60),
                                       decryptedBy: .app)
            return AppModel.TimelineItem(record: record, attachmentBytes: 0)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Text("replied:\(replied)")
                .accessibilityIdentifier("harness-replied")
            Text(shown)
                .font(.caption2)
                .lineLimit(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("harness-trace")
            HStack {
                Button("clear") { replied = "none"; box.lines = []; shown = "" }
                    .accessibilityIdentifier("harness-clear")
                Button("dump") { shown = box.lines.suffix(12).joined(separator: "\n") }
                    .accessibilityIdentifier("harness-dump")
            }
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(items) { item in
                            MessageRow(item: item, mine: item.record.senderDevice == "me-phone",
                                       time: item.record.receivedAt,
                                       reply: { replied = String(item.id) })
                                .id(item.id)
                        }
                        Color.clear.frame(height: 1).id(Int64(-2))
                    }
                    .padding()
                }
                .coordinateSpace(name: "timeline")
                .modifier(BottomAnchoredTimeline())
                // 방 화면과 같은 타임라인 동시 제스처 두 개(스크롤 따라가기 · 넓은 뒤로가기).
                .simultaneousGesture(DragGesture(minimumDistance: 10)
                    .onChanged { _ in if followLatest { followLatest = false } }
                    .onEnded { _ in })
                .simultaneousGesture(DragGesture(minimumDistance: 20).onEnded { _ in })
                .onAppear { proxy.scrollTo(Int64(-2), anchor: .bottom) }
            }
        }
        .onAppear { SwipeReplyTrace.sink = { [box] line in box.lines.append(line) } }
    }
}
final class TraceBox {
    var lines: [String] = []
}
#endif
