import Foundation

enum PaywallContext {
    case aiSearch
    case bulkRetag
    case insightsNarrative

    var featureTitle: String {
        switch self {
        case .aiSearch:           return "AI 自然言語検索"
        case .bulkRetag:          return "AI 一括リタグ"
        case .insightsNarrative:  return "Insights AI 解釈"
        }
    }

    var featureDescription: String {
        switch self {
        case .aiSearch:
            return "「先月会ったIT系の営業さん」など自然な言葉で名刺を検索できます。"
        case .bulkRetag:
            return "既存の名刺すべてに AI がタグを自動で振り直します。"
        case .insightsNarrative:
            return "集計グラフをAIが読み解き、次にアプローチすべき人を提案します。"
        }
    }
}
