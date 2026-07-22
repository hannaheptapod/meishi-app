import Foundation

enum PaywallContext: Hashable {
    case general
    case aiSearch
    case bulkRetag
    case insightsNarrative
    case duplicateAI

    var featureTitle: String {
        switch self {
        case .general:            return "eMeishi Pro"
        case .aiSearch:           return "AI 自然言語検索"
        case .bulkRetag:          return "AI 一括リタグ"
        case .insightsNarrative:  return "Insights AI 解釈"
        case .duplicateAI:        return "AI 重複検出"
        }
    }

    var featureDescription: String {
        switch self {
        case .general:
            return "名刺整理とAI機能を、すべての対応端末で利用できます。"
        case .aiSearch:
            return "「先月会ったIT系の営業さん」など自然な言葉で名刺を検索できます。"
        case .bulkRetag:
            return "既存の名刺すべてに AI がタグを自動で振り直します。"
        case .insightsNarrative:
            return "集計グラフをAIが読み解き、次にアプローチすべき人を提案します。"
        case .duplicateAI:
            return "ルールベースでは検出しづらい表記揺れの重複候補を AI が追加で見つけます。"
        }
    }
}
