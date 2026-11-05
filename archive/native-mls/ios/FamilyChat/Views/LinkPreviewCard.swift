// 링크 미리보기 카드(#683 2단계 계약 v1 · #690 계약 v2 클라이언트 절): 사람·서비스 봇 글 말풍선 아래. 이미지(있으면, 최대 높이 200·비율 유지) ·
// 사이트 이름(응답 `site`, 작게, #690) · 제목(og:title, 1줄) · 본문(og:description, 최대 4줄).
// 카드 탭 = 말풍선의 그 링크(클라이언트가 가진 원 링크 — 응답 `url` 아님) 열기(시스템 openURL — 1단계 링크 탭과 같다).
// 받기·캐시는 `LinkPreviewStore`(App/LinkPreviews.swift), 여기는 그리기만. 면 + 선(남의 말풍선과 같은 재질, AgentChoicesCard 반경 M).
import SwiftUI
import FamilyMLSCore

struct LinkPreviewCard: View {
    let url: URL
    let card: LinkPreviewStore.Card
    @Environment(\.hande) private var p
    @Environment(\.openURL) private var openURL

    /// 카드 최대 폭(pt) — 말풍선 안 사진(`AttachmentThumbnail.maxWidth`)과 같다.
    static let maxWidth: CGFloat = 280
    /// 이미지 최대 높이(pt, 계약 v1).
    static let maxImageHeight: CGFloat = 200
    /// 사이트 이름 줄 수(#690).
    static let siteLines = 1
    static let titleLines = 1
    static let descriptionLines = 4
    /// 카드 안쪽 여백(pt).
    static let inset: CGFloat = 12

    /// 이미지 자리 높이: 카드 안쪽 폭에 비율대로 놓은 높이, 최대 200. 크기를 모르면 200.
    static func imageHeight(_ size: CGSize) -> CGFloat {
        guard size.width > 0, size.height > 0 else { return maxImageHeight }
        return min(maxImageHeight, (maxWidth - inset * 2) * size.height / size.width)
    }

    var body: some View {
        Button { openURL(url) } label: {
            VStack(alignment: .leading, spacing: 6) {
                if let image = card.image {
                    // 자리 높이를 이미지 비에서 정해(≤ 200) 그 안에 비율 유지로 맞춘다 — 스크롤 안(세로 제안 없음)에서도 넘치지 않는다.
                    Color.clear
                        .frame(maxWidth: .infinity)
                        .frame(height: Self.imageHeight(image.size))
                        .overlay(Image(uiImage: image).resizable().scaledToFit())
                        .clipShape(RoundedRectangle(cornerRadius: Hande.radiusS))
                        .accessibilityHidden(true)
                }
                if let site = card.preview.shownSite {
                    // #690: 어느 사이트의 카드인지 작게(응답 `site`, 예: YouTube · 네이버 뉴스).
                    Text(site)
                        .font(.caption2)
                        .foregroundStyle(p.inkDim)
                        .lineLimit(Self.siteLines)
                        .accessibilityIdentifier("link-preview-site")
                }
                if let title = card.preview.shownTitle {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(p.ink)
                        .lineLimit(Self.titleLines)
                }
                if let description = card.preview.shownDescription {
                    Text(description)
                        .font(.footnote)
                        .foregroundStyle(p.ink)
                        .lineLimit(Self.descriptionLines)
                        .multilineTextAlignment(.leading)
                }
            }
            .padding(Self.inset)
            .frame(maxWidth: Self.maxWidth, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: Hande.radiusM).fill(p.surface))
            .overlay(RoundedRectangle(cornerRadius: Hande.radiusM).stroke(p.stroke, lineWidth: p.lineWidth))
            .contentShape(RoundedRectangle(cornerRadius: Hande.radiusM))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isLink)
        .accessibilityHint(Strings.linkPreviewHint)
        .accessibilityIdentifier("link-preview-card")
    }
}
