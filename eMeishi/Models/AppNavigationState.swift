import Combine
import Foundation
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

/// 名刺一覧ルートでTab Barを隠す必要がある操作状態。
/// 画面インスタンスのUUIDではなく、UI上の意味をそのまま状態として保持する。
nonisolated enum CardListRootMode: Hashable, Sendable {
    case browsing
    case selecting
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
    @Published private(set) var activeCardsRoute: CardListRoute?
    @Published var insightsPath = NavigationPath()
    @Published var externalFilter: CardListExternalFilter?
    @Published var isCardAdditionRequested = false
    @Published var isAISearchPaywallRequested = false
    @Published private(set) var cardListRootMode: CardListRootMode = .browsing
    @Published private(set) var isCardListBackgroundInteractionBlocked = false

    var selectedCardURI: URL? {
        guard case .detail(let objectURI) = activeCardsRoute else { return nil }
        return objectURI
    }

    var isRootChromeSuppressed: Bool {
        selectedTab == .cards && cardListRootMode == .selecting
    }

    /// Tab Barの表示判断はルートだけが行う。
    /// 詳細遷移と選択モードが別々のViewからvisibilityを上書きしないよう、
    /// 画面状態をここで1つの判定へ集約する。
    func shouldHideRootTabBar(isCompactWidth: Bool) -> Bool {
        guard selectedTab == .cards else { return false }
        if cardListRootMode == .selecting { return true }
        return isCompactWidth && activeCardsRoute != nil
    }

    /// 現在の詳細列を指定した画面へ置き換える。
    /// compactでもregularでも同じNavigationSplitViewを使うため、履歴を幅別に分岐させない。
    func showCardRoute(_ route: CardListRoute) {
        activeCardsRoute = route
    }

    func showCardDetail(_ objectURI: URL) {
        showCardRoute(.detail(objectURI))
    }

    func clearSelectedCardRoute() {
        guard case .detail = activeCardsRoute else { return }
        activeCardsRoute = nil
    }

    /// compactのNavigationSplitViewで戻る操作が行われたとき、
    /// ルート種別に関わらず名刺一覧へ戻す。
    func returnToCardsRoot() {
        activeCardsRoute = nil
    }

    func showCards(filteredBy filter: CardListExternalFilter) {
        externalFilter = filter
        selectedTab = .cards
        activeCardsRoute = nil
        cardListRootMode = .browsing
    }

    func requestCardAddition() {
        isCardAdditionRequested = true
    }

    func consumeCardAdditionRequest() {
        isCardAdditionRequested = false
    }

    func requestAISearchPaywall() {
        isAISearchPaywallRequested = true
    }

    func consumeAISearchPaywallRequest() {
        isAISearchPaywallRequested = false
    }

    func showSettings() {
        selectedTab = .cards
        showCardRoute(.settings)
        cardListRootMode = .browsing
    }

    func setCardListSelectionActive(_ isActive: Bool) {
        let newMode: CardListRootMode = isActive ? .selecting : .browsing
        guard cardListRootMode != newMode else { return }
        cardListRootMode = newMode
    }


    /// コンテキストメニューのdismiss完了までは、Tab Bar・検索・toolbarを含む
    /// ルート全域への背面入力を遮断する。
    func setCardListBackgroundInteractionBlocked(_ isBlocked: Bool) {
        guard isCardListBackgroundInteractionBlocked != isBlocked else { return }
        isCardListBackgroundInteractionBlocked = isBlocked
    }
}
