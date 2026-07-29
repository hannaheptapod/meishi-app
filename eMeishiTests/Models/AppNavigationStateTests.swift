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
        state.showCardRoute(.settings)
        state.insightsPath.append("synthetic-insight-detail")

        state.requestCardAddition()

        #expect(state.isCardAdditionRequested)
        #expect(state.selectedTab == .insights)
        #expect(state.activeCardsRoute == .settings)
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

        state.showCardRoute(.settings)

        #expect(state.activeCardsRoute == .settings)
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

    @Test func settingsSelectsCardsAndUsesTheCanonicalRoute() {
        let state = AppNavigationState()
        state.selectedTab = .insights

        state.showSettings()

        #expect(state.selectedTab == .cards)
        #expect(state.activeCardsRoute == .settings)
    }

    @Test func navigationBackReturnsEveryDestinationToTheCardsRoot() {
        let state = AppNavigationState()

        for route in [CardListRoute.settings, .duplicates] {
            state.showCardRoute(route)
            state.returnToCardsRoot()

            #expect(state.activeCardsRoute == nil)
        }
    }
}
