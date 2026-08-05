import Foundation
import Testing
import UIKit
@testable import eMeishi

@MainActor
struct ContextMenuInteractionGateTests {
    private nonisolated enum SyntheticAction: Equatable, Sendable {
        case edit(Int)
        case delete(Int)
    }

    @Test func dismissalKeepsShieldUntilUIKitCompletion() throws {
        let gate = ContextMenuInteractionGate<SyntheticAction>()

        let sessionID = gate.previewDidAppear()
        #expect(gate.blocksCardInteraction)
        #expect(gate.activeSessionID == sessionID)

        gate.previewDidDisappear(sessionID: sessionID)
        #expect(gate.blocksCardInteraction)
        #expect(gate.dismissingSessionID == sessionID)

        #expect(gate.blocksCardInteraction)

        _ = gate.dismissalDidComplete(sessionID: sessionID)
        #expect(!gate.blocksCardInteraction)
    }

    @Test func staleDismissalCompletionCannotReleaseCurrentShield() throws {
        let gate = ContextMenuInteractionGate<SyntheticAction>()

        let sessionID = gate.previewDidAppear()
        gate.previewDidDisappear(sessionID: sessionID)

        _ = gate.dismissalDidComplete(sessionID: UUID())
        #expect(gate.blocksCardInteraction)
        #expect(gate.dismissingSessionID == sessionID)
    }

    @Test func deferredActionIsReturnedOnlyAfterMatchingDismissal() throws {
        let gate = ContextMenuInteractionGate<SyntheticAction>()
        let sessionID = gate.previewDidAppear()

        let immediateAction = gate.deferUntilDismissal(.edit(1))
        #expect(immediateAction == nil)
        gate.previewDidDisappear(sessionID: sessionID)

        let staleAction = gate.dismissalDidComplete(sessionID: UUID())
        #expect(staleAction == nil)
        let completedAction = gate.dismissalDidComplete(sessionID: sessionID)
        #expect(completedAction == .edit(1))
        #expect(!gate.blocksCardInteraction)
    }

    @Test func actionOutsideContextMenuCanRunImmediately() {
        let gate = ContextMenuInteractionGate<SyntheticAction>()

        let action = gate.deferUntilDismissal(.delete(2))

        #expect(action == .delete(2))
    }

    @Test func staleDismissalStartCannotMoveCurrentSession() {
        let gate = ContextMenuInteractionGate<SyntheticAction>()
        let sessionID = gate.previewDidAppear()

        gate.previewDidDisappear(sessionID: UUID())

        #expect(gate.activeSessionID == sessionID)
        #expect(gate.dismissingSessionID == nil)
        #expect(gate.blocksCardInteraction)
    }

    @Test func cancelledDismissalRestoresOnlyMatchingSession() {
        let gate = ContextMenuInteractionGate<SyntheticAction>()
        let sessionID = gate.previewDidAppear()
        gate.previewDidDisappear(sessionID: sessionID)

        gate.dismissalWasCancelled(sessionID: UUID())
        #expect(gate.activeSessionID == nil)
        #expect(gate.dismissingSessionID == sessionID)

        gate.dismissalWasCancelled(sessionID: sessionID)
        #expect(gate.activeSessionID == sessionID)
        #expect(gate.dismissingSessionID == nil)
        #expect(gate.blocksCardInteraction)
    }

    @Test func resetClearsEveryTransientSessionAndDeferredAction() {
        let gate = ContextMenuInteractionGate<SyntheticAction>()
        _ = gate.previewDidAppear()
        _ = gate.deferUntilDismissal(.edit(3))

        gate.reset()

        #expect(!gate.blocksCardInteraction)
        #expect(gate.activeSessionID == nil)
        #expect(gate.dismissingSessionID == nil)
        #expect(gate.deferUntilDismissal(.delete(4)) == .delete(4))
    }

    @Test func dismantledPreviewCompletesAnUnscheduledDismissal() {
        let controller = ContextMenuPreviewLifecycleViewController()
        let expectedSessionID = UUID()
        var beganSessionID: UUID?
        var completedSessionID: UUID?
        controller.onPreviewPresented = { expectedSessionID }
        controller.onDismissalBegan = { beganSessionID = $0 }
        controller.onDismissalCompleted = { completedSessionID = $0 }

        controller.loadViewIfNeeded()
        controller.viewDidAppear(false)
        controller.representableWasDismantled()

        #expect(beganSessionID == expectedSessionID)
        #expect(completedSessionID == expectedSessionID)
    }

}
