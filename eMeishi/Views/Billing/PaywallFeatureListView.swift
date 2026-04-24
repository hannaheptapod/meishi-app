import SwiftUI

struct PaywallFeatureListView: View {

    let context: PaywallContext

    private struct Feature {
        let icon: String
        let title: String
        let comingSoon: Bool
    }

    private var features: [Feature] {
        var list: [Feature] = [
            Feature(icon: "magnifyingglass",        title: "AI 自然言語検索",            comingSoon: false),
            Feature(icon: "tag",                    title: "AI 一括リタグ",              comingSoon: false),
            Feature(icon: "chart.bar.doc.horizontal", title: "Insights AI 解釈",        comingSoon: false),
            Feature(icon: "person.2.slash",         title: "AI 重複検出",                comingSoon: false),
        ]
        // 現在の context に該当する機能を先頭へ
        if let idx = list.firstIndex(where: { $0.title == context.featureTitle }) {
            let item = list.remove(at: idx)
            list.insert(item, at: 0)
        }
        return list
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(features, id: \.title) { feature in
                HStack(spacing: 10) {
                    Image(systemName: feature.icon)
                        .foregroundStyle(feature.comingSoon ? Color.secondary : Color.accentColor)
                        .frame(width: 20)
                    Text(feature.title)
                        .font(.subheadline)
                        .foregroundStyle(feature.comingSoon ? .secondary : .primary)
                    Spacer()
                    if feature.comingSoon {
                        Text("近日公開")
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.quaternary, in: Capsule())
                            .foregroundStyle(.secondary)
                    } else {
                        Image(systemName: "checkmark")
                            .foregroundStyle(.accent)
                            .font(.caption.weight(.bold))
                    }
                }
            }
        }
    }
}
