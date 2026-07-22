import SwiftUI

struct PaywallFeatureListView: View {

    let context: PaywallContext

    /// `Identifiable.id` は非隔離要件のため、MainActor既定のView型から分離する。
    nonisolated private struct Feature {
        let context: PaywallContext
        let icon: String
        let title: String
    }

    private var features: [Feature] {
        var list: [Feature] = [
            Feature(context: .aiSearch, icon: "magnifyingglass", title: "AI 自然言語検索"),
            Feature(context: .bulkRetag, icon: "tag", title: "AI 一括リタグ"),
            Feature(context: .insightsNarrative, icon: "chart.bar.doc.horizontal", title: "Insights AI 解釈"),
            Feature(context: .duplicateAI, icon: "person.2.slash", title: "AI 重複検出"),
        ]
        // 現在の context に該当する機能を先頭へ
        if let idx = list.firstIndex(where: { $0.context == context }) {
            let item = list.remove(at: idx)
            list.insert(item, at: 0)
        }
        return list
    }

    var body: some View {
        let items = Array(features.enumerated())
        VStack(alignment: .leading, spacing: 8) {
            ForEach(items, id: \.offset) { _, feature in
                HStack(spacing: 10) {
                    Image(systemName: feature.icon)
                        .foregroundStyle(Color.accentColor)
                        .frame(width: 20)
                    Text(feature.title)
                        .font(.subheadline)
                        .foregroundStyle(.primary)
                    Spacer()
                    Image(systemName: "checkmark")
                        .foregroundStyle(Color.accentColor)
                        .font(.caption.weight(.bold))
                }
            }
        }
    }
}
