import SwiftUI

// MARK: - 一覧行

struct CardRowView: View {

    @ObservedObject var card: BusinessCard

    var body: some View {
        HStack(spacing: 12) {
            CardThumbnailView(card: card, size: 64)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 4) {
                    Text(card.fullName.isEmpty ? "（名前なし）" : card.fullName)
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    if card.isFavorite {
                        Image(systemName: "star.fill")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.yellow)
                    }
                }
                if let company = card.company, !company.isEmpty {
                    Text(company)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.secondary.opacity(0.9))
                        .lineLimit(1)
                }
                let dept = card.department ?? ""
                let ttl = card.title ?? ""
                let deptTitle = [dept, ttl].filter { !$0.isEmpty }.joined(separator: " ")
                if !deptTitle.isEmpty {
                    Text(deptTitle)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                if !cardTags.isEmpty {
                    HStack(spacing: 4) {
                        if let tag = cardTags.first {
                            HStack(spacing: 3) {
                                Circle()
                                    .fill(tag.color)
                                    .frame(width: 6, height: 6)
                                Text(tag.tagName)
                            }
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        }
                        if cardTags.count > 1 {
                            Text("+\(cardTags.count - 1)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .lineLimit(1)
                }
            }

            Spacer(minLength: 8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, AppTheme.Spacing.large)
        .padding(.vertical, AppTheme.Spacing.medium)
        .background(
            AppTheme.contentSurface,
            in: .rect(cornerRadius: AppTheme.contentCornerRadius, style: .continuous)
        )
        .contentShape(RoundedRectangle(cornerRadius: AppTheme.contentCornerRadius, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(cardAccessibilityLabel)
    }

    private var cardTags: [Tag] {
        let set = card.tags as? Set<Tag> ?? []
        return set.sorted { ($0.name ?? "") < ($1.name ?? "") }
    }

    private var cardAccessibilityLabel: String {
        var parts = [card.fullName.isEmpty ? "名前なし" : card.fullName]
        if let company = card.company, !company.isEmpty { parts.append(company) }
        if card.isFavorite { parts.append("お気に入り") }
        if !cardTags.isEmpty {
            parts.append("タグ: " + cardTags.map(\.tagName).joined(separator: "、"))
        }
        return parts.joined(separator: "、")
    }

}
