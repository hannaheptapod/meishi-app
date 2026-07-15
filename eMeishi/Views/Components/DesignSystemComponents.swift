import SwiftUI
import UIKit

struct ContentSurface<Content: View>: View {
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .padding(AppTheme.Spacing.large)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                AppTheme.contentSurface,
                in: .rect(cornerRadius: AppTheme.contentCornerRadius, style: .continuous)
            )
    }
}

struct InformationRow: View {
    let title: String
    let value: String
    let systemImage: String
    var actionSystemImage: String?
    var actionLabel: String?
    var action: (() -> Void)?

    var body: some View {
        HStack(spacing: AppTheme.Spacing.medium) {
            Image(systemName: systemImage)
                .frame(width: 24)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: AppTheme.Spacing.xSmall) {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.body)
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
            }

            Spacer(minLength: AppTheme.Spacing.small)

            if let action, let actionSystemImage, let actionLabel {
                Button(action: action) {
                    Image(systemName: actionSystemImage)
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(actionLabel)
            }
        }
        .padding(.vertical, AppTheme.Spacing.small)
    }
}

struct CardImageHero: View {
    let imageData: Data?
    let initials: String
    var maximumHeight: CGFloat = 320
    var onTap: (() -> Void)?

    var body: some View {
        Group {
            if let imageData, let image = UIImage(data: imageData) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: maximumHeight)
                    .clipShape(.rect(cornerRadius: AppTheme.imageCornerRadius, style: .continuous))
            } else {
                Text(initials.isEmpty ? "名刺" : initials)
                    .font(.largeTitle.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 180)
                    .background(AppTheme.auxiliarySurface)
                    .clipShape(.rect(cornerRadius: AppTheme.imageCornerRadius, style: .continuous))
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { onTap?() }
        .accessibilityAddTraits(onTap == nil ? [] : .isButton)
    }
}

struct InlineErrorView: View {
    let message: String
    var retryTitle = "再試行"
    var retry: (() -> Void)?

    var body: some View {
        ContentSurface {
            HStack(alignment: .top, spacing: AppTheme.Spacing.medium) {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: AppTheme.Spacing.small) {
                    Text(message)
                        .font(.subheadline)
                    if let retry {
                        Button(retryTitle, action: retry)
                    }
                }
            }
        }
    }
}

struct MetricBlock: View {
    let title: String
    let value: String
    var detail: String?

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.xSmall) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title2.weight(.semibold))
                .contentTransition(.numericText())
            if let detail {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(AppTheme.Spacing.medium)
        .background(AppTheme.contentSurface)
        .clipShape(.rect(cornerRadius: AppTheme.contentCornerRadius, style: .continuous))
    }
}

struct OCRStatusStepper: View {
    let state: OCRProcessingState
    let canContinueInBackground: Bool
    let onCancel: () -> Void

    private let phases: [OCRProcessingPhase] = [
        .imagePreparation, .textRecognition, .fieldAnalysis, .aiAssistance, .saving
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.medium) {
            ProgressView(value: state.progress)
                .tint(AppTheme.brandOrange)

            HStack(spacing: AppTheme.Spacing.xSmall) {
                ForEach(phases, id: \.rawValue) { phase in
                    Capsule()
                        .fill(color(for: phase))
                        .frame(maxWidth: .infinity, minHeight: 4, maxHeight: 4)
                }
            }
            .accessibilityHidden(true)

            HStack(alignment: .firstTextBaseline) {
                Text(state.phase.title)
                    .font(.headline)
                Spacer()
                Text(state.progress, format: .percent.precision(.fractionLength(0)))
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            if let remainingTimeText = state.remainingTimeText {
                Text(remainingTimeText)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            if canContinueInBackground {
                Label(
                    "読み取り中はアプリを閉じても処理を続けられます。進捗はDynamic Islandまたはロック画面で確認できます。",
                    systemImage: "iphone.and.arrow.forward"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Button("読み取りを中止", role: .cancel, action: onCancel)
                .font(.subheadline)
        }
        .accessibilityElement(children: .contain)
    }

    private func color(for phase: OCRProcessingPhase) -> Color {
        guard let currentIndex = phases.firstIndex(of: state.phase),
              let phaseIndex = phases.firstIndex(of: phase) else {
            return .secondary.opacity(0.18)
        }
        return phaseIndex <= currentIndex
            ? AppTheme.brandOrange
            : .secondary.opacity(0.18)
    }
}
