import SwiftUI

// MARK: - 一覧行

struct CardRowView: View {

    let item: CardListItemSnapshot
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
        .accessibilityLabel(item.row.accessibilityLabel)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    @ViewBuilder
    private var rowLayout: some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.medium) {
                CardThumbnailView(item: item, size: thumbnailSize)
                cardText
            }
        } else {
            HStack(spacing: compact ? AppTheme.Spacing.small : AppTheme.Spacing.medium) {
                CardThumbnailView(item: item, size: thumbnailSize)
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
        let snapshot = item.row
        return VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: AppTheme.Spacing.xSmall) {
                Text(snapshot.displayName)
                    .font(.headline.weight(.bold))
                    .foregroundStyle(.primary)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
                if snapshot.isFavorite {
                    Image(systemName: "star.fill")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.yellow)
                        .accessibilityHidden(true)
                }
            }
            if !snapshot.company.isEmpty {
                Text(snapshot.company)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
            }
            if !snapshot.affiliation.isEmpty {
                Text(snapshot.affiliation)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
            }
            if let tag = snapshot.firstTag {
                let tagColor = Color(hex: tag.colorHex)
                HStack(spacing: AppTheme.Spacing.xSmall) {
                    HStack(spacing: 3) {
                        Circle()
                            .fill(tagColor)
                            .frame(width: 6, height: 6)
                        Text(tag.name)
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(tagColor.opacity(0.12), in: .capsule)
                    if snapshot.additionalTagCount > 0 {
                        Text("+\(snapshot.additionalTagCount)")
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

}

/// 行の形状や明度は押下中も変えない。
///
/// `contextMenu` を画面外タップで閉じる入力は、その直下にある SwiftUI の
/// `Button` に一瞬だけ `isPressed` を伝えることがある。行側に押下演出を持たせると
/// メニューを閉じただけなのに背面カードが反応したように見えるため、一覧カードでは
/// 選択・遷移の結果だけをフィードバックとして扱う。
struct CardRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
    }
}
