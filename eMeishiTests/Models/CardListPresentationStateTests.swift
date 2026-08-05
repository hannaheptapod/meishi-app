import Foundation
import Testing
@testable import eMeishi

struct CardListPresentationStateTests {
    private let syntheticCardURI = URL(string: "x-coredata://synthetic/Card/p1")!
    private let secondSyntheticCardURI = URL(string: "x-coredata://synthetic/Card/p2")!

    @Test
    func onlyOnePresentationIsActiveAtATime() {
        var state = CardListPresentationState()

        state.request(.sheet(.editCard(objectURI: syntheticCardURI)))
        state.request(.confirmation(.deleteCard(objectURI: secondSyntheticCardURI)))

        #expect(state.active?.destination == .sheet(.editCard(objectURI: syntheticCardURI)))
        #expect(state.queued.map(\.destination) == [
            .confirmation(.deleteCard(objectURI: secondSyntheticCardURI)),
        ])
    }

    @Test
    func dismissalAndNextPresentationAreSeparatePhases() {
        let sheetID = UUID()
        let confirmationID = UUID()
        var state = CardListPresentationState()

        state.request(.sheet(.tagManager), id: sheetID)
        state.request(.confirmation(.importContacts), id: confirmationID)

        let didClearSheet = state.clearActive(requestID: sheetID)
        #expect(didClearSheet)
        #expect(state.active == nil)
        #expect(state.queued.count == 1)
        #expect(state.isDismissing)

        let didPresentConfirmation = state.presentNext(afterDismissing: sheetID)
        #expect(didPresentConfirmation)
        #expect(state.active?.id == confirmationID)
        #expect(state.queued.isEmpty)
        #expect(!state.isDismissing)
    }

    @Test
    func staleDismissalCannotCloseNewPresentation() {
        let staleID = UUID()
        let currentID = UUID()
        var state = CardListPresentationState()

        state.request(.sheet(.tagManager), id: staleID)
        let didClearStaleSheet = state.clearActive(requestID: staleID)
        #expect(didClearStaleSheet)
        state.request(.sheet(.paywall), id: currentID)
        state.presentNext(afterDismissing: staleID)

        let staleDismissalWasAccepted = state.clearActive(requestID: staleID)
        #expect(!staleDismissalWasAccepted)
        #expect(state.active?.id == currentID)
    }

    @Test
    func identicalPendingRequestIsDeduplicated() {
        var state = CardListPresentationState()
        let result = CardListPresentationDestination.Alert.importResult(message: "合成データを1件処理しました")

        state.request(.sheet(.tagManager))
        let didQueueResult = state.request(.alert(result))
        let didQueueDuplicate = state.request(.alert(result))
        #expect(didQueueResult)
        #expect(!didQueueDuplicate)
        #expect(state.queued.count == 1)
    }

    @Test
    func requestArrivingDuringDismissalDoesNotOvertakeQueue() {
        let sheetID = UUID()
        var state = CardListPresentationState()

        state.request(.sheet(.tagManager), id: sheetID)
        state.request(.confirmation(.importContacts))
        let didClearSheet = state.clearActive(requestID: sheetID)
        #expect(didClearSheet)

        state.request(.alert(.error(message: "合成エラー")))

        #expect(state.active == nil)
        #expect(state.queued.map(\.destination) == [
            .confirmation(.importContacts),
            .alert(.error(message: "合成エラー")),
        ])
        let didPresentConfirmation = state.presentNext(afterDismissing: sheetID)
        #expect(didPresentConfirmation)
        #expect(state.active?.destination == .confirmation(.importContacts))
    }

    @Test
    func cardTargetsRemainStableURIsInsteadOfManagedObjects() {
        var state = CardListPresentationState()
        let targets: Set<URL> = [syntheticCardURI, secondSyntheticCardURI]

        state.request(.sheet(.bulkTag(cardURIs: targets)))

        #expect(state.active?.destination == .sheet(.bulkTag(cardURIs: targets)))
    }
}
