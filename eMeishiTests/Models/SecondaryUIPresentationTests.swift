import CoreData
import Testing
@testable import eMeishi

@MainActor
struct SecondaryUIPresentationTests {
    @Test func secondaryViewTaskGateRejectsDuplicateAndStaleCompletion() {
        var gate = SecondaryViewTaskGate()

        guard let firstID = gate.begin() else {
            Issue.record("最初の操作を開始できませんでした")
            return
        }
        #expect(gate.begin() == nil)
        #expect(gate.accepts(firstID))

        gate.cancel()
        #expect(!gate.accepts(firstID))
        let cancelledFinish = gate.finish(firstID)
        #expect(!cancelledFinish)

        guard let secondID = gate.begin() else {
            Issue.record("取消後の操作を開始できませんでした")
            return
        }
        #expect(secondID != firstID)
        let staleFinish = gate.finish(firstID)
        let currentFinish = gate.finish(secondID)
        #expect(!staleFinish)
        #expect(currentFinish)
        #expect(gate.currentID == nil)
    }

    @Test func presentationDestinationsHaveStableDistinctIDs() {
        let context = makeTestContext()
        let cardA = makeCard(context: context, lastName: "試験A")
        let cardB = makeCard(context: context, lastName: "試験B")
        try? context.obtainPermanentIDs(for: [cardA, cardB])
        let pair = DuplicatePair(cardA: cardA, cardB: cardB, score: 0.8)
        let request = DuplicateMergeRequest(
            pair: pair,
            cardA: DuplicateMergeCardSnapshot(card: cardA),
            cardB: DuplicateMergeCardSnapshot(card: cardB)
        )

        #expect(DuplicateListPresentation.merge(request).id == "merge:\(request.id)")
        #expect(DuplicateListPresentation.paywall.id == "paywall")
        #expect(BulkTagAssignPresentation.tagManager.id != BulkTagAssignPresentation.paywall.id)
        #expect(TagManagementPresentation.create.id != TagManagementPresentation.edit(objectURI: "x-coredata://synthetic/tag/1").id)
        #expect(
            TagManagementPresentation.delete(
                TagDeletionRequest(
                    objectURI: "x-coredata://synthetic/tag/2",
                    displayName: "合成タグ"
                )
            ).id == "delete:x-coredata://synthetic/tag/2"
        )
        #expect(PaywallAlertDestination.purchaseFailure.id != PaywallAlertDestination.restoreFailure.id)
    }

    @Test func cardFormAlertsAreSerializedAcrossDismissal() {
        let firstID = UUID()
        let secondID = UUID()
        var state = QueuedPresentationState<CardFormAlertDestination>()

        let didRequestFirst = state.request(.llmDownload, id: firstID)
        let didRequestSecond = state.request(
            .saveFailure(message: "synthetic error"),
            id: secondID
        )
        #expect(didRequestFirst)
        #expect(didRequestSecond)
        #expect(state.active?.id == firstID)
        #expect(state.queued.map(\.id) == [secondID])

        let didClearFirst = state.clearActive(requestID: firstID)
        #expect(didClearFirst)
        #expect(state.active == nil)
        #expect(state.isDismissing)
        let didPresentSecond = state.presentNext(afterDismissing: firstID)
        #expect(didPresentSecond)
        #expect(state.active?.id == secondID)
    }

    @Test func settingsAsyncResultQueuesBehindCurrentConfirmation() {
        let confirmationID = UUID()
        let restoreID = UUID()
        var state = QueuedPresentationState<SettingsPresentation>()

        let didRequestConfirmation = state.request(
            .deleteAllConfirmation,
            id: confirmationID
        )
        let didRequestRestore = state.request(
            .alert(.purchaseRestore(message: "synthetic result")),
            id: restoreID
        )
        #expect(didRequestConfirmation)
        #expect(didRequestRestore)
        #expect(state.active?.id == confirmationID)

        let didClearConfirmation = state.clearActive(requestID: confirmationID)
        let didPresentRestore = state.presentNext(afterDismissing: confirmationID)
        #expect(didClearConfirmation)
        #expect(didPresentRestore)
        #expect(state.active?.id == restoreID)
    }

    @Test func tagEditorWaitsForDeleteDialogDismissalCompletion() {
        let deleteID = UUID()
        let createID = UUID()
        let deletion = TagDeletionRequest(
            objectURI: "x-coredata://synthetic/tag/delete-target",
            displayName: "合成タグ"
        )
        var state = QueuedPresentationState<TagManagementPresentation>()

        let didRequestDelete = state.request(.delete(deletion), id: deleteID)
        let didRequestCreate = state.request(.create, id: createID)
        #expect(didRequestDelete)
        #expect(didRequestCreate)
        #expect(state.active?.id == deleteID)
        #expect(state.queued.map(\.id) == [createID])

        let didClearDelete = state.clearActive(requestID: deleteID)
        #expect(didClearDelete)
        #expect(state.active == nil)
        #expect(state.dismissing?.id == deleteID)

        let staleDismissalAdvanced = state.presentNext(afterDismissing: UUID())
        #expect(!staleDismissalAdvanced)
        #expect(state.active == nil)
        let didPresentCreate = state.presentNext(afterDismissing: deleteID)
        #expect(didPresentCreate)
        #expect(state.active?.id == createID)
    }
}
