import SwiftUI

// MARK: - 一覧行

struct CardRowView: View {

    @ObservedObject var card: BusinessCard
    var compact = false
    var isSelected = false
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        rowLayout
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, compact ? AppTheme.Spacing.medium : AppTheme.Spacing.large)
        .padding(.vertical, compact ? AppTheme.Spacing.small : AppTheme.Spacing.medium)
        .background(
            isSelected ? AppTheme.brandOrange.opacity(0.14) : AppTheme.contentSurface,
            in: .rect(cornerRadius: AppTheme.contentCornerRadius, style: .continuous)
        )
        .contentShape(RoundedRectangle(cornerRadius: AppTheme.contentCornerRadius, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(cardAccessibilityLabel)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    @ViewBuilder
    private var rowLayout: some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.medium) {
                CardThumbnailView(card: card, size: thumbnailSize)
                cardText
            }
        } else {
            HStack(spacing: compact ? AppTheme.Spacing.small : AppTheme.Spacing.medium) {
                CardThumbnailView(card: card, size: thumbnailSize)
                cardText
                Spacer(minLength: AppTheme.Spacing.small)
            }
            .frame(minHeight: compact ? 60 : 76)
        }
    }

    private var thumbnailSize: CGFloat {
        compact ? 56 : 72
    }

    private var cardText: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: AppTheme.Spacing.xSmall) {
                Text(card.fullName.isEmpty ? "（名前なし）" : card.fullName)
                    .font(.headline.weight(.bold))
                    .foregroundStyle(.primary)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
                    .contentTransition(.interpolate)
                if card.isFavorite {
                    Image(systemName: "star.fill")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.yellow)
                        .accessibilityHidden(true)
                }
            }
            if let company = card.company, !company.isEmpty {
                Text(company)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
                    .contentTransition(.interpolate)
            }
            let department = card.department ?? ""
            let title = card.title ?? ""
            let affiliation = [department, title].filter { !$0.isEmpty }.joined(separator: " ")
            if !affiliation.isEmpty {
                Text(affiliation)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
                    .contentTransition(.interpolate)
            }
            if !cardTags.isEmpty {
                HStack(spacing: AppTheme.Spacing.xSmall) {
                    if let tag = cardTags.first {
                        HStack(spacing: 3) {
                            Circle()
                                .fill(tag.color)
                                .frame(width: 6, height: 6)
                            Text(tag.tagName)
                        }
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(tag.color.opacity(0.12), in: .capsule)
                    }
                    if cardTags.count > 1 {
                        Text("+\(cardTags.count - 1)")
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(AppTheme.auxiliarySurface, in: .capsule)
                    }
                }
                .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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

/// 不透明なカードを直接押している間だけ押下状態を表示する。
/// 前面の検索・タブなどへのタッチには反応させない。
struct CardRowButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .brightness(configuration.isPressed ? -0.025 : 0)
            .animation(
                reduceMotion ? nil : .snappy(duration: 0.16, extraBounce: 0),
                value: configuration.isPressed
            )
    }
}
