import SwiftUI

nonisolated enum DuplicateListPresentation: Identifiable, Sendable {
    case merge(DuplicateMergeRequest)
    case paywall

    var id: String {
        switch self {
        // `DuplicatePair.id` は UI target の既定 MainActor 隔離を受けるため、
        // Sendable な保存値だけから同じ安定 ID を構築する。
        case .merge(let request):
            return "merge:\(request.id)"
        case .paywall: return "paywall"
        }
    }
}

// 重複候補の一覧画面
struct DuplicateListView: View {

    @Binding var pairs: [DuplicatePair]
    let onMerge: () -> Void

    @EnvironmentObject private var entitlementStore: EntitlementStore
    @Environment(\.managedObjectContext) private var context
    @State private var presentation: DuplicateListPresentation?
    @State private var shouldRefreshAfterMerge = false

    var body: some View {
        List {
            if !entitlementStore.hasAccess {
                Section {
                    Button {
                        presentation = .paywall
                    } label: {
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: "sparkles")
                                .foregroundStyle(.tint)
                            VStack(alignment: .leading, spacing: 4) {
                                Text("AI 重複検出を有効にする")
                                    .font(.subheadline.bold())
                                    .foregroundStyle(.primary)
                                Text("表記揺れの重複候補を AI が追加で見つけます。eMeishi Pro でご利用いただけます。")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .foregroundStyle(.secondary)
                                .font(.caption)
                        }
                    }
                }
            }
            if pairs.isEmpty {
                ContentUnavailableView(
                    "重複なし",
                    systemImage: "checkmark.circle",
                    description: Text("重複している名刺は見つかりませんでした")
                )
            } else {
                ForEach(pairs) { pair in
                    Button {
                        presentation = .merge(mergeRequest(for: pair))
                    } label: {
                        DuplicatePairRow(pair: pair)
                    }
                    .tint(.primary)
                }
            }
        }
        .navigationTitle("重複チェック")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $presentation, onDismiss: completePresentationDismissal) { destination in
            switch destination {
            case .merge(let request):
                DuplicateMergeView(request: request) {
                    shouldRefreshAfterMerge = true
                    presentation = nil
                }
            case .paywall:
                PaywallView(context: .duplicateAI)
                    .environmentObject(entitlementStore)
            }
        }
    }

    /// 統合で変化した一覧は、親sheetのdismiss animationが完了してから更新する。
    /// 背面Listの差分更新をdismiss途中へ割り込ませない。
    private func completePresentationDismissal() {
        guard shouldRefreshAfterMerge else { return }
        shouldRefreshAfterMerge = false
        onMerge()
    }

    private func mergeRequest(for pair: DuplicatePair) -> DuplicateMergeRequest {
        let cardA = context.businessCard(forURIString: pair.cardAIDURI)
            .map(DuplicateMergeCardSnapshot.init(card:))
        let cardB = context.businessCard(forURIString: pair.cardBIDURI)
            .map(DuplicateMergeCardSnapshot.init(card:))
        return DuplicateMergeRequest(pair: pair, cardA: cardA, cardB: cardB)
    }
}

// MARK: - 重複ペア行

private struct DuplicatePairRow: View {

    let pair: DuplicatePair

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                DuplicateScoreBadge(scoreText: pair.scoreText)
                if pair.isAIDetected {
                    HStack(spacing: 2) {
                        Image(systemName: "sparkles")
                            .font(.caption2)
                        Text("AI検出")
                            .font(.caption2)
                    }
                    .foregroundStyle(.tint)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.tint.opacity(0.12), in: Capsule())
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .foregroundStyle(.secondary)
                    .font(.caption)
            }
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: AppTheme.Spacing.small) {
                    cardSummary(pair.cardASummary)
                    Divider()
                    cardSummary(pair.cardBSummary)
                }
            } else {
                HStack(spacing: AppTheme.Spacing.medium) {
                    cardSummary(pair.cardASummary)
                    Image(systemName: "arrow.left.arrow.right")
                        .foregroundStyle(.secondary)
                    cardSummary(pair.cardBSummary)
                }
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func cardSummary(_ card: DuplicateCardSummary) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(card.fullName.isEmpty ? "（名前なし）" : card.fullName)
                .font(.subheadline).bold()
                .lineLimit(1)
            if !card.company.isEmpty {
                Text(card.company)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
