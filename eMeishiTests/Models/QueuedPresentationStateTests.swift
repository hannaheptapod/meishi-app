import Foundation
import Testing
@testable import eMeishi

struct QueuedPresentationStateTests {
    private nonisolated enum SyntheticDestination: Equatable, Sendable {
        case sheet(Int)
        case alert(String)
    }

    @Test
    func fifoOrderIsPreservedAcrossDismissalBoundary() {
        let firstID = UUID()
        let secondID = UUID()
        let thirdID = UUID()
        var state = QueuedPresentationState<SyntheticDestination>()

        state.request(.sheet(1), id: firstID)
        state.request(.alert("合成通知A"), id: secondID)
        state.request(.alert("合成通知B"), id: thirdID)

        let didClearFirst = state.clearActive(requestID: firstID)
        let didPresentSecond = state.presentNext(afterDismissing: firstID)
        #expect(didClearFirst)
        #expect(didPresentSecond)
        #expect(state.active?.id == secondID)

        let didClearSecond = state.clearActive(requestID: secondID)
        let didPresentThird = state.presentNext(afterDismissing: secondID)
        #expect(didClearSecond)
        #expect(didPresentThird)
        #expect(state.active?.id == thirdID)
    }

    @Test
    func staleDismissalCompletionCannotAdvanceAnotherRequest() {
        let firstID = UUID()
        let secondID = UUID()
        var state = QueuedPresentationState<SyntheticDestination>()

        state.request(.sheet(1), id: firstID)
        state.request(.sheet(2), id: secondID)
        let didClearFirst = state.clearActive(requestID: firstID)
        let wrongDismissalAdvancedQueue = state.presentNext(afterDismissing: secondID)
        #expect(didClearFirst)
        #expect(!wrongDismissalAdvancedQueue)
        #expect(state.active == nil)
        #expect(state.dismissing?.id == firstID)

        let didPresentSecond = state.presentNext(afterDismissing: firstID)
        #expect(didPresentSecond)
        #expect(state.active?.id == secondID)
        let staleClearWasAccepted = state.clearActive(requestID: firstID)
        #expect(!staleClearWasAccepted)
        #expect(state.active?.id == secondID)
    }

    @Test
    func confirmationCommitRunsOnlyAfterMatchingDismissal() {
        let presentationID = UUID()
        var state = DismissalCommitState<SyntheticDestination>()

        let didSchedule = state.schedule(.alert("合成操作"), for: presentationID)
        #expect(didSchedule)
        #expect(state.hasPendingCommit)
        let staleCommit = state.take(afterDismissing: UUID())
        #expect(staleCommit == nil)
        #expect(state.hasPendingCommit)

        let commit = state.take(afterDismissing: presentationID)
        #expect(commit == .alert("合成操作"))
        #expect(!state.hasPendingCommit)
    }

    @Test
    func pendingConfirmationCommitCannotBeOverwritten() {
        let firstID = UUID()
        var state = DismissalCommitState<SyntheticDestination>()

        let didScheduleFirst = state.schedule(.sheet(1), for: firstID)
        let didScheduleSecond = state.schedule(.sheet(2), for: UUID())
        let commit = state.take(afterDismissing: firstID)
        #expect(didScheduleFirst)
        #expect(!didScheduleSecond)
        #expect(commit == .sheet(1))
    }
}
