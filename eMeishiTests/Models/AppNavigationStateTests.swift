import Foundation
import SwiftUI
import Testing
@testable import eMeishi

@MainActor
struct AppNavigationStateTests {
    @Test func cardSelectionModeDerivesRootChromeVisibility() {
        let state = AppNavigationState()

        #expect(state.isRootChromeSuppressed == false)

        state.setCardListSelectionActive(true)
        #expect(state.cardListRootMode == .selecting)
        #expect(state.isRootChromeSuppressed == true)

        state.selectedTab = .insights
        #expect(state.isRootChromeSuppressed == false)

        state.setCardListSelectionActive(false)
        #expect(state.cardListRootMode == .browsing)
    }

    @Test func rootTabBarVisibilityHasOneCanonicalDecision() {
        let state = AppNavigationState()
        let syntheticURI = URL(string: "x-coredata://synthetic/card/root-visibility")!

        #expect(!state.shouldHideRootTabBar(isCompactWidth: true))
        #expect(!state.shouldHideRootTabBar(isCompactWidth: false))

        state.showCardDetail(syntheticURI)
        #expect(state.shouldHideRootTabBar(isCompactWidth: true))
        #expect(!state.shouldHideRootTabBar(isCompactWidth: false))

        state.setCardListSelectionActive(true)
        #expect(state.shouldHideRootTabBar(isCompactWidth: true))
        #expect(state.shouldHideRootTabBar(isCompactWidth: false))

        state.selectedTab = .insights
        #expect(!state.shouldHideRootTabBar(isCompactWidth: true))
        #expect(!state.shouldHideRootTabBar(isCompactWidth: false))
    }

    @Test func contextMenuBackgroundShieldIsRootOwned() {
        let state = AppNavigationState()

        state.setCardListBackgroundInteractionBlocked(true)
        #expect(state.isCardListBackgroundInteractionBlocked)

        state.setCardListBackgroundInteractionBlocked(false)
        #expect(!state.isCardListBackgroundInteractionBlocked)
    }

    @Test func additionRequestPreservesSelectedTabAndNavigationState() {
        let state = AppNavigationState()
        state.selectedTab = .insights
        state.showCardRoute(.duplicates)
        state.insightsPath.append("synthetic-insight-detail")

        state.requestCardAddition()

        #expect(state.isCardAdditionRequested)
        #expect(state.selectedTab == .insights)
        #expect(state.activeCardsRoute == .duplicates)
        #expect(state.insightsPath.count == 1)
    }

    @Test func externalFilterNavigationClearsSelectedCardAndSelectionMode() {
        let state = AppNavigationState()
        let syntheticURI = URL(string: "x-coredata://synthetic/card/1")!
        state.showCardDetail(syntheticURI)
        state.setCardListSelectionActive(true)

        state.showCards(filteredBy: .favorite)

        #expect(state.selectedTab == .cards)
        #expect(state.selectedCardURI == nil)
        #expect(state.activeCardsRoute == nil)
        #expect(state.cardListRootMode == .browsing)
    }

    @Test func cardNavigationUsesTheCanonicalRoute() {
        let state = AppNavigationState()

        state.showCardRoute(.duplicates)

        #expect(state.activeCardsRoute == .duplicates)
        #expect(state.selectedCardURI == nil)
    }

    @Test func cardSelectionProjectsFromTheCanonicalRoute() {
        let state = AppNavigationState()
        let syntheticURI = URL(string: "x-coredata://synthetic/card/2")!

        state.showCardDetail(syntheticURI)

        #expect(state.activeCardsRoute == .detail(syntheticURI))
        #expect(state.selectedCardURI == syntheticURI)

        state.clearSelectedCardRoute()
        #expect(state.selectedCardURI == nil)
        #expect(state.activeCardsRoute == nil)
    }

    @Test func replacingDestinationDoesNotLeaveAStaleCardSelection() {
        let state = AppNavigationState()
        let syntheticURI = URL(string: "x-coredata://synthetic/card/3")!

        state.showCardDetail(syntheticURI)
        state.showCardRoute(.duplicates)

        #expect(state.activeCardsRoute == .duplicates)
        #expect(state.selectedCardURI == nil)
    }

    @Test func settingsPreparationKeepsDetailRouteIntact() {
        let state = AppNavigationState()
        state.selectedTab = .insights
        let syntheticURI = URL(string: "x-coredata://synthetic/card/settings-sheet")!
        state.showCardDetail(syntheticURI)

        state.prepareForSettingsSheet()

        #expect(state.selectedTab == .cards)
        #expect(state.cardListRootMode == .browsing)
        // 設定はsheet提示なのでSplit Viewのdetail列（route）を奪わない
        #expect(state.activeCardsRoute == .detail(syntheticURI))
    }

    @Test func settingsSheetRequestIsHeldByRootPresentationRequestsUntilConsumed() {
        let requests = AppRootPresentationRequests()

        #expect(!requests.consumeSettingsSheetRequest())

        requests.requestSettingsSheet()
        #expect(requests.isSettingsSheetPending)
        #expect(requests.consumeSettingsSheetRequest())
        #expect(!requests.isSettingsSheetPending)
        #expect(!requests.consumeSettingsSheetRequest())
    }

    @Test func navigationBackReturnsEveryDestinationToTheCardsRoot() {
        let state = AppNavigationState()
        let syntheticURI = URL(string: "x-coredata://synthetic/card/back-route")!

        for route in [CardListRoute.detail(syntheticURI), .duplicates] {
            state.showCardRoute(route)
            state.returnToCardsRoot()

            #expect(state.activeCardsRoute == nil)
        }
    }
}
