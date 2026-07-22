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

enum ContentSectionStyle: Equatable {
    case standard
    case accent
}

/// 見出しとコンテンツ面の組み合わせを全画面で統一する。
/// コンテンツ面は不透明に保ち、Glassはシステムの操作面だけに任せる。
struct ContentSection<Content: View>: View {
    let title: String
    var style: ContentSectionStyle = .standard
    private let content: Content

    init(
        _ title: String,
        style: ContentSectionStyle = .standard,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.style = style
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.small) {
            Text(title)
                .font(.headline)
                .foregroundStyle(style == .accent ? AppTheme.brandOrange : .secondary)
                .padding(.horizontal, AppTheme.Spacing.xSmall)

            surface
        }
    }

    @ViewBuilder
    private var surface: some View {
        let base = VStack(alignment: .leading, spacing: AppTheme.Spacing.medium) {
            content
        }
            .padding(AppTheme.Spacing.large)
            .frame(maxWidth: .infinity, alignment: .leading)

        switch style {
        case .standard:
            base.background(
                AppTheme.contentSurface,
                in: .rect(cornerRadius: AppTheme.contentCornerRadius, style: .continuous)
            )
        case .accent:
            base.background(
                AppTheme.brandOrange.opacity(0.08),
                in: .rect(cornerRadius: AppTheme.contentCornerRadius, style: .continuous)
            )
        }
    }
}

/// 詳細画面などで使う「ラベル・値・任意の実行ボタン」の共通行。
/// 左右に同じ意味のアイコンを重複させず、行末だけを操作位置にする。
struct DetailValueRow: View {
    let title: String
    let value: String
    var isLink = false
    var actionLabel: String?
    var actionSystemImage: String?
    var action: (() -> Void)?
    @State private var copyFeedbackTrigger = 0

    var body: some View {
        HStack(alignment: .center, spacing: AppTheme.Spacing.medium) {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.xSmall) {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                valueText
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if let action, let actionSystemImage {
                Button(action: action) {
                    Image(systemName: actionSystemImage)
                        .font(.body.weight(.medium))
                        .symbolRenderingMode(.monochrome)
                        .foregroundStyle(.secondary)
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(actionLabel ?? "\(title)を開く")
                // 値そのものをリンクとして読み上げるため、同じ操作の重複読上げを避ける。
                .accessibilityHidden(true)
            }
        }
        .frame(minHeight: 72, alignment: .center)
        .contextMenu {
            Button("コピー", systemImage: "doc.on.doc") {
                UIPasteboard.general.string = value
                copyFeedbackTrigger += 1
            }
            ShareLink(item: value) {
                Label("共有", systemImage: "square.and.arrow.up")
            }
            if let action {
                Button(actionLabel ?? "開く", systemImage: actionSystemImage ?? "arrow.up.right") {
                    action()
                }
            }
        }
        .sensoryFeedback(.success, trigger: copyFeedbackTrigger)
    }

    @ViewBuilder
    private var valueText: some View {
        let text = Text(value)
            .font(.body)
            .foregroundStyle(isLink ? Color(uiColor: .link) : .primary)
            .multilineTextAlignment(.leading)
            .textSelection(.enabled)
            .contentTransition(.interpolate)

        if let action, isLink {
            text
                .onTapGesture(perform: action)
                .accessibilityAddTraits(.isLink)
        } else {
            text
        }
    }
}

struct CardImageHero: View {
    let imageData: Data?
    let cacheIdentifier: String
    let initials: String
    var maximumHeight: CGFloat = 320
    var onTap: (() -> Void)?
    @State private var decodedImage: UIImage?
    @State private var decodedImageIdentifier: String?

    @ViewBuilder
    var body: some View {
        Group {
            if let onTap {
                Button(action: onTap) {
                    heroContent
                }
                .buttonStyle(.plain)
                .accessibilityLabel("名刺画像を表示")
            } else {
                heroContent
            }
        }
        .task(id: cacheIdentifier) {
            guard let imageData else { return }
            if decodedImage != nil, decodedImageIdentifier == cacheIdentifier { return }
            let decoded = await CardImageDecodingService.shared.image(
                from: imageData,
                maximumPixelSize: maximumHeight * 3,
                cacheIdentifier: cacheIdentifier
            )
            guard !Task.isCancelled else { return }
            decodedImage = decoded?.image
            decodedImageIdentifier = decoded == nil ? nil : cacheIdentifier
        }
    }

    private var heroContent: some View {
        Group {
            if imageData != nil,
               decodedImageIdentifier == cacheIdentifier,
               let image = decodedImage {
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
                ProgressView()
                    .controlSize(.small)
                Spacer()
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
