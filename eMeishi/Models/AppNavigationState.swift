import Combine
import SwiftUI

nonisolated enum AppTab: Hashable, Sendable {
    case cards
    case insights
    case settings
}

nonisolated enum CardListExternalFilter: Hashable, Sendable {
    case company(String)
    case area(String)
    case role(String)
    case month(String)

    var displayTitle: String {
        switch self {
        case .company(let value): "会社: \(value)"
        case .area(let value): "エリア: \(value)"
        case .role(let value): "職種: \(value)"
        case .month(let value): "年月: \(value)"
        }
    }
}

@MainActor
final class AppNavigationState: ObservableObject {
    @Published var selectedTab: AppTab = .cards
    @Published var cardsPath = NavigationPath()
    @Published var insightsPath = NavigationPath()
    @Published var settingsPath = NavigationPath()
    @Published var externalFilter: CardListExternalFilter?

    func showCards(filteredBy filter: CardListExternalFilter) {
        externalFilter = filter
        selectedTab = .cards
        cardsPath = NavigationPath()
    }
}
