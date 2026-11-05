// 미리보기 사이트 목록(#690 「계약 v2」 — 릴레이 `GET /v2/preview/sites`). 링크로 바꿀 호스트와 카드를 물을 호스트를 릴레이가 정한다
// — 다음 사이트부터는 릴레이만 고친다. 응답 `{"version":2,"sites":[{"id","name","hosts":[…],"preview":bool}, …]}`.
// 엄격한 디코드: version 이 정확히 2 가 아니면 실패, 형식이 틀린 항목(필드 없음·타입 다름·빈 이름·평범한 소문자 호스트 이름이 아닌 호스트)은
// 그 항목만 버린다, 남는 사이트가 없으면 실패. 실패·404(옛 릴레이·플래그 꺼짐)·로그인 전에는 **내장 폴백** = v1 동작
// (x 호스트 링크 + x status 경로 미리보기, 경로 규칙은 앱 `ServiceLinks.isStatusURL`). 순수 값·검증만 여기(Linux CI 대상).
import Foundation

/// 사이트 하나(계약 v2 레지스트리 한 줄).
public struct PreviewSite: Equatable, Sendable {
    public let id: String
    /// 카드에 작게 보이는 이름은 미리보기 응답의 `site` 를 쓴다 — 이 값은 목록용.
    public let name: String
    /// 소문자 호스트(정확히 일치).
    public let hosts: Set<String>
    /// true = 링크 + 미리보기 카드, false = 링크만.
    public let preview: Bool

    public init(id: String, name: String, hosts: Set<String>, preview: Bool) {
        self.id = id
        self.name = name
        self.hosts = hosts
        self.preview = preview
    }
}

public struct PreviewSites: Equatable, Sendable, Decodable {
    public static let version = 2
    public static let routePath = "/v2/preview/sites"

    /// 응답 순서 그대로(같은 id 는 처음 것만).
    public let sites: [PreviewSite]
    /// 내장 폴백(v1 동작)이다 — 카드 대상은 x status 경로 규칙으로 고른다.
    public let isFallback: Bool
    /// 사람·서비스 봇 말풍선에서 링크로 바꿀 호스트 = 모든 사이트 hosts 의 합집합.
    public let linkHosts: Set<String>
    /// 카드를 물을 호스트 = preview:true 사이트 hosts 의 합집합.
    public let previewHosts: Set<String>

    public init(sites: [PreviewSite], isFallback: Bool = false) {
        self.sites = sites
        self.isFallback = isFallback
        linkHosts = sites.reduce(into: Set<String>()) { $0.formUnion($1.hosts) }
        previewHosts = sites.filter(\.preview).reduce(into: Set<String>()) { $0.formUnion($1.hosts) }
    }

    /// v1 의 x.com 계열 호스트(#683).
    public static let xHosts: Set<String> = ["x.com", "www.x.com", "mobile.x.com", "twitter.com", "www.twitter.com", "mobile.twitter.com"]
    /// 받기 전·실패·404 에 쓰는 내장 목록 = v1(x 링크 + x status 미리보기).
    public static let fallback = PreviewSites(sites: [PreviewSite(id: "x", name: "X", hosts: xHosts, preview: true)], isFallback: true)

    /// 이 호스트(대소문자 무시)가 속한 첫 사이트.
    public func site(forHost host: String) -> PreviewSite? {
        let host = host.lowercased()
        return sites.first { $0.hosts.contains(host) }
    }

    /// 이 호스트(대소문자 무시)가 preview:true 사이트에 속한다.
    public func isPreviewHost(_ host: String) -> Bool {
        previewHosts.contains(host.lowercased())
    }

    // MARK: - 디코드 (엄격)

    private enum Keys: String, CodingKey { case version, sites }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: Keys.self)
        let version = try container.decode(Int.self, forKey: .version)
        guard version == Self.version else {
            throw DecodingError.dataCorruptedError(forKey: .version, in: container, debugDescription: "unsupported version \(version)")
        }
        var list = try container.nestedUnkeyedContainer(forKey: .sites)
        var sites: [PreviewSite] = []
        var ids = Set<String>()
        while !list.isAtEnd {
            if try list.decodeNil() { continue }
            // Entry 는 던지지 않는다(형식이 틀리면 nil) — 그래서 항목 하나가 틀려도 커서가 다음으로 넘어간다.
            guard let site = try list.decode(Entry.self).site, ids.insert(site.id).inserted else { continue }
            sites.append(site)
        }
        guard !sites.isEmpty else {
            throw DecodingError.dataCorruptedError(forKey: .sites, in: container, debugDescription: "no valid sites")
        }
        self.init(sites: sites)
    }

    private struct Entry: Decodable {
        let site: PreviewSite?

        init(from decoder: Decoder) {
            site = (try? Wire(from: decoder))?.validated
        }
    }

    private struct Wire: Decodable {
        let id: String
        let name: String
        let hosts: [String]
        let preview: Bool

        var validated: PreviewSite? {
            let shown = self.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard PreviewSites.isSiteID(id), !shown.isEmpty, shown.count <= 64,
                  !hosts.isEmpty, hosts.allSatisfy({ PreviewSites.isPlainHost($0) })
            else { return nil }
            return PreviewSite(id: id, name: shown, hosts: Set(hosts), preview: preview)
        }
    }

    /// 사이트 id: `[a-z0-9_-]{1,64}`(예: `x`, `naver-news`).
    static func isSiteID(_ id: String) -> Bool {
        (1...64).contains(id.utf8.count) && id.utf8.allSatisfy { (b: UInt8) -> Bool in
            switch b {
            case UInt8(ascii: "a")...UInt8(ascii: "z"), UInt8(ascii: "0")...UInt8(ascii: "9"), UInt8(ascii: "-"), UInt8(ascii: "_"):
                return true
            default:
                return false
            }
        }
    }

    /// 평범한 소문자 호스트 이름: `[a-z0-9-]` 라벨 둘 이상을 `.` 로 이은 것(라벨 1–63바이트, `-` 로 시작·끝나지 않음, 전체 ≤ 253),
    /// 마지막 라벨이 숫자만은 아님(IP 주소가 아님). 대문자·포트·사용자 정보·`*`·끝 `.` 은 거부.
    public static func isPlainHost(_ host: String) -> Bool {
        guard (1...253).contains(host.utf8.count) else { return false }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2 else { return false }
        for label in labels {
            let bytes = Array(label.utf8)
            guard (1...63).contains(bytes.count), bytes.first != UInt8(ascii: "-"), bytes.last != UInt8(ascii: "-"),
                  bytes.allSatisfy({ (b: UInt8) -> Bool in
                      switch b {
                      case UInt8(ascii: "a")...UInt8(ascii: "z"), UInt8(ascii: "0")...UInt8(ascii: "9"), UInt8(ascii: "-"):
                          return true
                      default:
                          return false
                      }
                  })
            else { return false }
        }
        return !labels[labels.count - 1].utf8.allSatisfy { (b: UInt8) -> Bool in UInt8(ascii: "0") <= b && b <= UInt8(ascii: "9") }
    }
}
