import SwiftUI

/// フォーム内のタグ選択を一貫した見た目・44pt以上の操作領域で提供する。
struct TagSelectionChip: View {
    let tag: TagDisplaySnapshot
    let isSelected: Bool
    let action: () -> Void

    private var tagColor: Color { Color(hex: tag.colorHex) }

    var body: some View {
        Button(action: action) {
            HStack(spacing: AppTheme.Spacing.xSmall) {
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.caption2.weight(.semibold))
                }
                Circle()
                    .fill(tagColor)
                    .frame(width: 8, height: 8)
                    .accessibilityHidden(true)
                Text(tag.name)
                    .font(.caption)
            }
            .padding(.horizontal, 10)
            .frame(minHeight: 44)
            .background(
                isSelected ? tagColor.opacity(0.18) : AppTheme.auxiliarySurface,
                in: .capsule
            )
            // 色覚・コントラストに依存せず、タグ色はドットと薄い面だけで伝える。
            .foregroundStyle(isSelected ? Color.primary : Color.secondary)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
