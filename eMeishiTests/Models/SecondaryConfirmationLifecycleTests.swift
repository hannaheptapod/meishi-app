import Foundation
import Testing
@testable import eMeishi

@MainActor
struct SecondaryConfirmationLifecycleTests {
    @Test func cloudResetCommitWaitsForMatchingDismissal() {
        let requestID = UUID()
        var presentation = QueuedPresentationState<AdvancedSettingsPresentation>()
        var commit = DismissalCommitState<AdvancedSettingsConfirmationCommit>()

        let didRequest = presentation.request(.zoneResetConfirmation, id: requestID)
        let didSchedule = commit.schedule(.resetCloudZone, for: requestID)
        let didClear = presentation.clearActive(requestID: requestID)
        #expect(didRequest)
        #expect(didSchedule)
        #expect(didClear)

        let staleCommit = commit.take(afterDismissing: UUID())
        #expect(staleCommit == nil)
        #expect(commit.hasPendingCommit)
        let acceptedCommit = commit.take(afterDismissing: requestID)
        #expect(acceptedCommit == .resetCloudZone)
        #expect(!commit.hasPendingCommit)
    }

    @Test func modelDeletionCommitCannotBeConsumedByStaleDismissal() {
        let previousID = UUID()
        let currentID = UUID()
        var presentation = QueuedPresentationState<ModelManagementPresentation>()
        var commit = DismissalCommitState<ModelManagementConfirmationCommit>()

        let didRequest = presentation.request(.deleteConfirmation, id: currentID)
        let didSchedule = commit.schedule(.deleteModel, for: currentID)
        let didClear = presentation.clearActive(requestID: currentID)
        #expect(didRequest)
        #expect(didSchedule)
        #expect(didClear)

        let stalePresentationAdvanced = presentation.presentNext(afterDismissing: previousID)
        let staleCommit = commit.take(afterDismissing: previousID)
        let acceptedCommit = commit.take(afterDismissing: currentID)
        let hasQueuedPresentation = presentation.presentNext(afterDismissing: currentID)
        #expect(!stalePresentationAdvanced)
        #expect(staleCommit == nil)
        #expect(acceptedCommit == .deleteModel)
        #expect(!hasQueuedPresentation)
        #expect(presentation.dismissing == nil)
    }
}
