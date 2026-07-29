import SwiftUI

/// 類似度は警告色ではなく数値を主情報として表示する。
struct DuplicateScoreBadge: View {
    let scoreText: String

    var body: some View {
        Text("類似度 \(scoreText)")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.primary)
            .padding(.horizontal, AppTheme.Spacing.small)
            .padding(.vertical, AppTheme.Spacing.xSmall)
            .background(AppTheme.auxiliarySurface, in: .capsule)
            .accessibilityLabel("類似度 \(scoreText)")
    }
}
