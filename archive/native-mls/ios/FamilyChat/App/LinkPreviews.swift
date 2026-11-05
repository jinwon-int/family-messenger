// 링크 미리보기 카드(#683 2단계 계약 v1 → #690 계약 v2 클라이언트 절)의 앱 메모리 캐시 — 키 = 말풍선 링크 그대로(URL별 음성 캐시). 앱 전용(UIKit) —
// NSE·공유 확장 소스 목록과 Linux 스모크 복사 목록(scripts/linux-smoke.sh)에 넣지 말 것.
// 같은 주소는 프로세스 동안 한 번만 릴레이에 묻는다(동시에 여러 말풍선이 물어도 요청 하나). 성공(카드)과 실패(카드 없음:
// 404 라우트 없음·no_preview · 502 · 네트워크 · 디코드 · 글 없음)를 모두 담는다 — 실패는 릴레이 캐시와 같은 10분 뒤 다시 묻는다.
// 요청은 AppModel 이 지금의 릴레이 전송(`RelayTransport.linkPreview`·`linkPreviewImage`, 다른 요청과 같은 인증 헤더)으로 한다.
import Foundation
import FamilyMLSCore
import UIKit

@MainActor
final class LinkPreviewStore {
    static let shared = LinkPreviewStore()

    /// 카드에 그릴 것: 미리보기 + 받은 이미지(없거나 못 받았으면 nil — 글만으로 카드).
    struct Card {
        let preview: LinkPreview
        let image: UIImage?
    }

    enum Outcome {
        case card(Card)
        /// 카드 없이 링크만(조용히).
        case noCard

        var card: Card? {
            if case .card(let card) = self { return card }
            return nil
        }
    }

    typealias FetchPreview = (URL) async throws -> LinkPreview
    typealias FetchImage = (String) async throws -> Data

    private struct Entry {
        let outcome: Outcome
        let at: Date
    }

    /// 담아 둘 주소 수 상한(오래 담은 것부터 버린다).
    let limit: Int
    /// 실패(카드 없음)를 다시 묻기까지(릴레이 실패 캐시 10분과 같다). 성공은 프로세스 동안.
    let failureTTL: TimeInterval
    private let now: () -> Date
    private var entries: [String: Entry] = [:]
    private var order: [String] = []
    private var inFlight: [String: Task<Void, Never>] = [:]

    init(limit: Int = 256, failureTTL: TimeInterval = 600, now: @escaping () -> Date = { Date() }) {
        self.limit = max(1, limit)
        self.failureTTL = failureTTL
        self.now = now
    }

    /// 담아 둔 결과(없거나 실패가 만료됐으면 nil). 말풍선이 첫 프레임부터 카드 높이로 그려지게 body 에서 읽는다.
    func cached(_ url: URL) -> Outcome? {
        guard let entry = entries[url.absoluteString] else { return nil }
        if case .noCard = entry.outcome, now().timeIntervalSince(entry.at) >= failureTTL { return nil }
        return entry.outcome
    }

    /// 담아 둔 결과가 있으면 그대로, 같은 주소를 묻는 중이면 그 결과를 기다리고, 아니면 묻는다. 호출한 말풍선이 화면 밖으로 나가
    /// 취소돼도 요청은 끝까지 가서 담긴다(다시 보일 때 또 묻지 않게).
    func load(_ url: URL, fetch: @escaping FetchPreview, fetchImage: @escaping FetchImage) async -> Outcome {
        let key = url.absoluteString
        if let hit = cached(url) { return hit }
        if let running = inFlight[key] {
            await running.value
            return entries[key]?.outcome ?? .noCard
        }
        let task = Task { @MainActor [weak self] in
            let outcome = await LinkPreviewStore.resolve(url, fetch: fetch, fetchImage: fetchImage)
            self?.finish(key, outcome)
        }
        inFlight[key] = task
        await task.value
        return entries[key]?.outcome ?? .noCard
    }

    private func finish(_ key: String, _ outcome: Outcome) {
        inFlight[key] = nil
        if entries[key] == nil { order.append(key) }
        entries[key] = Entry(outcome: outcome, at: now())
        while order.count > limit { entries[order.removeFirst()] = nil }
    }

    /// 미리보기 → (있으면) 이미지. 미리보기 실패·글 없음 = 카드 없음, 이미지 실패 = 이미지 없는 카드.
    private static func resolve(_ url: URL, fetch: FetchPreview, fetchImage: FetchImage) async -> Outcome {
        guard let preview = try? await fetch(url), preview.hasText else { return .noCard }
        var image: UIImage?
        if let path = preview.image, let data = try? await fetchImage(path) {
            image = await decode(data)
        }
        return .card(Card(preview: preview, image: image))
    }

    /// 이미지(≤ 2 MiB)를 메인 밖에서 카드 크기로 축소 디코드(ImageIO, 첨부 썸네일과 같은 함수) — 원본 해상도 비트맵을 들고 있지 않는다.
    private static func decode(_ data: Data) async -> UIImage? {
        let maxPoints = imageMaxPoints   // 메인에서 읽어 값으로 넘긴다
        return await Task.detached(priority: .userInitiated) {
            AttachmentThumbnail.make(data, scale: 3, maxPoints: maxPoints)
        }.value
    }

    /// 축소 디코드의 긴 변(pt) — 카드 폭(`LinkPreviewCard.maxWidth` 280)보다 조금 크게(세로 사진도 200pt 높이에 선명하게).
    static let imageMaxPoints: CGFloat = 320
}

/// 말풍선 한 행이 받아 온 카드와 그 대상 링크(#690: 사이트 목록이 도착하면 대상이 바뀔 수 있다 — 다른 링크의 카드를 그리지 않게).
struct LoadedLinkPreview {
    let url: URL
    let card: LinkPreviewStore.Card
}

extension AppModel {
    /// 이 말풍선 링크의 미리보기 카드(캐시 `LinkPreviewStore.shared`). 로그인 전·로그아웃 뒤엔 묻지 않고 nil. 실패는 모두 nil(카드 없이 링크만).
    func linkPreviewCard(for url: URL) async -> LinkPreviewStore.Card? {
        guard canLoadLinkPreviews else { return nil }
        return await LinkPreviewStore.shared.load(url,
                                                  fetch: { try await self.linkPreview(url: $0) },
                                                  fetchImage: { try await self.linkPreviewImage(path: $0) }).card
    }
}
