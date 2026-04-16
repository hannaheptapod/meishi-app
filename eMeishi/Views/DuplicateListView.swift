import SwiftUI

// 重複候補の一覧画面
struct DuplicateListView: View {

    @Binding var pairs: [DuplicatePair]
    let onMerge: () -> Void

    @State private var selectedPair: DuplicatePair? = nil

    var body: some View {
        List {
            if pairs.isEmpty {
                ContentUnavailableView(
                    "重複なし",
                    systemImage: "checkmark.circle",
                    description: Text("重複している名刺は見つかりませんでした")
                )
            } else {
                ForEach(pairs) { pair in
                    Button {
                        selectedPair = pair
                    } label: {
                        DuplicatePairRow(pair: pair)
                    }
                    .tint(.primary)
                }
            }
        }
        .navigationTitle("重複チェック")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $selectedPair) { pair in
            DuplicateMergeView(pair: pair) {
                selectedPair = nil
                onMerge()
            }
        }
    }
}

// MARK: - 重複ペア行

private struct DuplicatePairRow: View {

    let pair: DuplicatePair

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("類似度 \(pair.scoreText)")
                    .font(.caption)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(scoreColor(pair.score), in: Capsule())
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
            HStack(spacing: 12) {
                cardSummary(pair.cardA)
                Image(systemName: "arrow.left.arrow.right")
                    .foregroundStyle(.secondary)
                cardSummary(pair.cardB)
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func cardSummary(_ card: BusinessCard) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(card.fullName.isEmpty ? "（名前なし）" : card.fullName)
                .font(.subheadline).bold()
                .lineLimit(1)
            if let company = card.company, !company.isEmpty {
                Text(company)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func scoreColor(_ score: Double) -> Color {
        score >= 0.9 ? .red : score >= 0.8 ? .orange : .mint
    }
}
