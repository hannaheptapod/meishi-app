import Combine
import SwiftUI

nonisolated enum AppTab: Hashable, Sendable {
    case cards
    case browse
    case insights
    case settings
}

nonisolated enum CardListExternalFilter: Hashable, Sendable {
    case company(String)
    case area(String)
    case role(String)
    case month(String)
    case untagged
    case missingContact
    case recent(days: Int)
    case favorite

    var displayTitle: String {
        switch self {
        case .company(let value): "会社: \(value)"
        case .area(let value): "エリア: \(value)"
        case .role(let value): "職種: \(value)"
        case .month(let value): "年月: \(value)"
        case .untagged: "未整理: タグなし"
        case .missingContact: "情報不足: 電話・メールなし"
        case .recent(let days): "最近追加: \(days)日以内"
        case .favorite: "お気に入り"
        }
    }
}

@MainActor
final class AppNavigationState: ObservableObject {
    @Published var selectedTab: AppTab = .cards
    @Published var cardsPath = NavigationPath()
    @Published var browsePath = NavigationPath()
    @Published var insightsPath = NavigationPath()
    @Published var settingsPath = NavigationPath()
    @Published var externalFilter: CardListExternalFilter?
    @Published var isCardAdditionRequested = false
    @Published var isRootBarHidden = false

    func showCards(filteredBy filter: CardListExternalFilter) {
        externalFilter = filter
        selectedTab = .cards
        cardsPath = NavigationPath()
    }

    func requestCardAddition() {
        selectedTab = .cards
        isCardAdditionRequested = true
    }

    func consumeCardAdditionRequest() {
        isCardAdditionRequested = false
    }
}
