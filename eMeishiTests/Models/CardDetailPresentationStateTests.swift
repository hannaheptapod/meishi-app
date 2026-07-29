import Foundation
import Testing
@testable import eMeishi

struct CardDetailPresentationStateTests {
    private let syntheticCardURI = URL(string: "x-coredata://synthetic/Card/detail")!

    @Test
    func detailPresentationsAreSerializedAcrossPresentationStyles() {
        let editID = UUID()
        let imageID = UUID()
        let alertID = UUID()
        var state = CardDetailPresentationState()

        state.request(.sheet(.editCard(objectURI: syntheticCardURI)), id: editID)
        state.request(.fullScreen(.cardImage(objectURI: syntheticCardURI)), id: imageID)
        state.request(
            .alert(.message(title: "合成通知", message: "合成された確認メッセージ")),
            id: alertID
        )

        #expect(state.active?.id == editID)
        #expect(state.queued.map(\.id) == [imageID, alertID])

        let didClearEdit = state.clearActive(requestID: editID)
        let didPresentImage = state.presentNext(afterDismissing: editID)
        #expect(didClearEdit)
        #expect(didPresentImage)
        #expect(state.active?.id == imageID)
    }

    @Test
    func duplicateEditCompletionIsAcceptedOnlyOnce() {
        let editID = UUID()
        var state = CardDetailPresentationState()

        state.request(.sheet(.editCard(objectURI: syntheticCardURI)), id: editID)

        let didClearEdit = state.clearActive(requestID: editID)
        let duplicateClearWasAccepted = state.clearActive(requestID: editID)
        #expect(didClearEdit)
        #expect(!duplicateClearWasAccepted)
        #expect(state.dismissing?.id == editID)
    }

    @Test
    func detailTargetsAreStableValuesInsteadOfManagedObjects() {
        var state = CardDetailPresentationState()

        state.request(.fullScreen(.cardImage(objectURI: syntheticCardURI)))

        #expect(
            state.active?.destination == .fullScreen(.cardImage(objectURI: syntheticCardURI))
        )
    }
}
