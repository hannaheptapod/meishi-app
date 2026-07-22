import Combine
import SwiftUI

nonisolated enum CardListRoute: Hashable, Sendable {
    case detail(URL)
    case settings
    case duplicates
}

nonisolated enum AppTab: Hashable, Sendable {
    case cards
    case insights
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
    @Published var cardsPath: [CardListRoute] = []
    @Published var insightsPath = NavigationPath()
    @Published var externalFilter: CardListExternalFilter?
    @Published var isCardAdditionRequested = false
    @Published var selectedCardForSplit: BusinessCard?
    @Published private(set) var isRootChromeSuppressed = false

    private var rootChromeSuppressors: Set<UUID> = []

    func pushCardsRoute(_ route: CardListRoute) {
        cardsPath.append(route)
    }

    func showCards(filteredBy filter: CardListExternalFilter) {
        externalFilter = filter
        selectedCardForSplit = nil
        selectedTab = .cards
        cardsPath = []
    }

    func requestCardAddition() {
        isCardAdditionRequested = true
    }

    func consumeCardAdditionRequest() {
        isCardAdditionRequested = false
    }

    func showSettings() {
        selectedCardForSplit = nil
        selectedTab = .cards
        cardsPath = [.settings]
    }

    /// ルート画面上の選択モードなどが、Tab Barと追加ボタンを隠す状態を所有者単位で管理する。
    func setRootChromeSuppressed(_ suppressed: Bool, owner: UUID) {
        if suppressed {
            rootChromeSuppressors.insert(owner)
        } else {
            rootChromeSuppressors.remove(owner)
        }
        isRootChromeSuppressed = !rootChromeSuppressors.isEmpty
    }
}
