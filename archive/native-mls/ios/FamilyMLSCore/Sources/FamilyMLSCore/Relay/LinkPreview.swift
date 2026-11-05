// 링크 미리보기(#683 2단계 「계약 v1」 → #690 「계약 v2」). 릴레이(`-link-preview` 켠 때만 라우트가 있다)가
// `GET /v2/preview?url=<말풍선 링크 그대로>` 에 `{url, site, title, description, image}` 로 답하고(사이트 판정·경로 규칙은 릴레이), `image` 는 릴레이 상대 경로 `/v2/preview/image?u=<원본>`
// 또는 null 이다. 요청은 `URLSessionRelayTransport` 가 **다른 릴레이 요청과 같은 인증 헤더**(CF Access 쿠키·assertion)로 보낸다 —
// 이미지도 같은 경로로 받는다(일반 이미지 로더에 URL 만 넘기면 인증이 빠진다). 순수 값·검증만 여기(Linux CI 대상).
import Foundation

/// `GET /v2/preview` 응답. 키가 없거나 null 이면 nil(릴레이는 og:title·og:description 둘 다 없으면 404 `no_preview`).
public struct LinkPreview: Equatable, Decodable, Sendable {
    /// 릴레이가 정규화한 주소(예: `https://x.com/{handle}/status/{id}`). 카드 탭은 말풍선의 원래 링크를 연다 — 이 값은 참고용.
    public var url: String?
    /// 사이트 이름(계약 v2, 예: `YouTube`·`네이버 뉴스`) — 카드에 작게.
    public var site: String?
    public var title: String?
    public var description: String?
    /// 릴레이 상대 경로 `/v2/preview/image?u=…`, 없으면 nil(이미지 없음·허용 호스트 밖).
    public var image: String?

    public init(url: String? = nil, site: String? = nil, title: String? = nil, description: String? = nil, image: String? = nil) {
        self.url = url
        self.site = site
        self.title = title
        self.description = description
        self.image = image
    }

    public static let routePath = "/v2/preview"
    public static let imageRoutePath = "/v2/preview/image"

    /// 카드의 사이트 이름(앞뒤 공백 제거, 비면 nil).
    public var shownSite: String? { Self.trimmed(site) }
    /// 카드 제목(앞뒤 공백 제거, 비면 nil).
    public var shownTitle: String? { Self.trimmed(title) }
    /// 카드 본문(앞뒤 공백 제거, 비면 nil).
    public var shownDescription: String? { Self.trimmed(description) }
    /// 카드로 그릴 글이 있다(제목·본문 중 하나라도). 없으면 카드 없이 링크만.
    public var hasText: Bool { shownTitle != nil || shownDescription != nil }

    /// 응답 `image`(릴레이 상대 경로)에서 원본 이미지 주소(`u`)를 꺼낸다. 경로가 정확히 `/v2/preview/image` 이고 스킴·호스트가 없으며,
    /// `u` 가 https + 평범한 호스트 이름(`PreviewSites.isPlainHost`, 사용자 정보·포트 없음)일 때만 — 아니면 nil(이미지 없이 글만 카드).
    /// 이미지 호스트 허용 목록(계약 v2: preview 사이트들의 이미지 호스트 합집합)은 **릴레이가** 판정한다 — 사이트가 늘어도 앱을 고치지
    /// 않게. 요청은 어떤 경우에도 이 릴레이 기준 주소(같은 인증)로만 나가므로 클라이언트에서 다른 호스트로 새지 않는다.
    public static func imageSource(_ path: String) -> String? {
        guard let parts = URLComponents(string: path), parts.scheme == nil, parts.host == nil,
              parts.percentEncodedPath == imageRoutePath,
              let source = parts.queryItems?.first(where: { $0.name == "u" })?.value,
              let target = URLComponents(string: source), target.scheme?.lowercased() == "https",
              target.user == nil, target.password == nil, target.port == nil,
              let host = target.host?.lowercased(), PreviewSites.isPlainHost(host)
        else { return nil }
        return source
    }

    private static func trimmed(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }
}
