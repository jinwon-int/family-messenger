// 사진 보기 재현 화면(DEBUG 전용, 실행 인자 `-photoViewerHarness`). 오너 2026-11-19 「상대가 보낸 사진을 누르면 검은 화면이 뜨고
// 닫을 수 없다 — 어느 때는 보인다」(#844)를 시뮬레이터 UI 테스트(FamilyChatUITests/PhotoViewerUITests)로 재현·검증한다.
//
// 실제 `MessageRow` → `AttachmentBubble`(받은 file-v2 사진, 준비물은 캐시에 미리 둔다)을 그대로 그리고, 모델은 부트스트랩하지 않는다 —
// 폴링이 없어 `AppModel` 이 아무것도 알리지 않는 「조용한」 상태다(바퀴 사이 `/v2/watch` 를 기다리는 실제 앱과 같다, #763).
// 조용한 동안에는 이 화면도 다시 그리지 않는다: 사진 보기가 뜨는지는 말풍선 자신의 상태만으로 정해져야 한다.
//
// `-photoViewerPublishAfter <초>`: 화면이 준비되고 그만큼 뒤에 모델 변경 알림을 한 번 낸다(바퀴 한 번을 흉내) —
// 사진 보기가 「알림이 와야만」 뜨는지 가려낸다.
#if DEBUG
import SwiftUI
import UIKit
import FamilyMLSCore

struct PhotoViewerHarness: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.displayScale) private var displayScale
    @State private var item: AppModel.TimelineItem?

    static let room: RoomID = "harness"

    /// `-photoViewerPublishAfter N` — 없으면 알림을 내지 않는다.
    private static var publishAfter: TimeInterval? {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-photoViewerPublishAfter"), i + 1 < args.count else { return nil }
        return TimeInterval(args[i + 1])
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(item == nil ? "harness-preparing" : "harness-ready")
                .accessibilityIdentifier("harness-state")
            if let item {
                MessageRow(item: item, mine: false)
            }
            Spacer()
        }
        .padding()
        .task {
            guard item == nil else { return }
            item = await Self.makeItem(scale: displayScale)
            guard let delay = Self.publishAfter else { return }
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            model.objectWillChange.send()
        }
    }

    /// 받은 file-v2 사진 한 장. 준비물(축소 비트맵 + 공유 파일)은 실제 경로(`AttachmentBubble.loadFileV2`)처럼 내용으로 정한 MIME 의
    /// 표시용 행으로 만들어 캐시에 둔다 — 말풍선은 첫 프레임부터 썸네일이고 릴레이·저장소에 닿지 않는다.
    @MainActor
    private static func makeItem(scale: CGFloat) async -> AppModel.TimelineItem? {
        let size = CGSize(width: 1200, height: 900)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.systemOrange.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            UIColor.white.setFill()
            context.fill(CGRect(x: 300, y: 225, width: 600, height: 450))
        }
        guard let bytes = image.jpegData(compressionQuality: 0.9) else { return nil }
        let seq: Int64 = 1
        let received = Date(timeIntervalSince1970: 1_800_000_000)
        let shown = MessageRecord(room: room, seq: seq, senderDevice: "mom-phone", clientId: "c1", kind: .attachment,
                                  body: AttachmentFormat.sniffMime(bytes), attachment: nil, receivedAt: received, decryptedBy: .app)
        _ = await AttachmentPreviewCache.shared.prepare(record: shown, bytes: bytes, scale: scale)
        let stored = MessageRecord(room: room, seq: seq, senderDevice: "mom-phone", clientId: "c1", kind: .fileV2,
                                   body: "image/jpeg", attachment: nil, receivedAt: received, decryptedBy: .app)
        return AppModel.TimelineItem(record: stored, attachmentBytes: 0)
    }
}
#endif
