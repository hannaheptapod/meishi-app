import Testing
@testable import eMeishi

struct PresentationDismissalObserverTests {
    private nonisolated enum SyntheticLayer: Hashable, Sendable {
        case parentSheet
        case targetAlert
        case nestedSystemUI
        case replacementAlert
    }

    @Test func parentPresentationAtActivationIsBaselineNotTarget() {
        var tracker = PresentationPathTracker<SyntheticLayer>()

        tracker.begin(scopePrefix: [.parentSheet], currentPath: [.parentSheet])

        #expect(tracker.observe([.parentSheet]) == nil)
        #expect(tracker.trackedLayer == nil)
        #expect(tracker.isDismissalComplete(in: [.parentSheet]))
    }

    @Test func onlyPresentationAddedAboveBaselineIsTracked() {
        var tracker = PresentationPathTracker<SyntheticLayer>()
        tracker.begin(scopePrefix: [.parentSheet], currentPath: [.parentSheet])

        let target = tracker.observe([.parentSheet, .targetAlert])

        #expect(target == .targetAlert)
        #expect(tracker.trackedLayer == .targetAlert)
        #expect(!tracker.isDismissalComplete(in: [.parentSheet, .targetAlert]))
    }

    @Test func nestedPresentationDoesNotReplaceTrackedTarget() {
        var tracker = PresentationPathTracker<SyntheticLayer>()
        tracker.begin(scopePrefix: [.parentSheet], currentPath: [.parentSheet])
        _ = tracker.observe([.parentSheet, .targetAlert])

        let target = tracker.observe([.parentSheet, .targetAlert, .nestedSystemUI])

        #expect(target == .targetAlert)
        #expect(!tracker.isDismissalComplete(in: [.parentSheet, .targetAlert]))
    }

    @Test func dismissalCompletesWhenTargetLeavesWhileParentRemains() {
        var tracker = PresentationPathTracker<SyntheticLayer>()
        tracker.begin(scopePrefix: [.parentSheet], currentPath: [.parentSheet])
        _ = tracker.observe([.parentSheet, .targetAlert])

        #expect(tracker.isDismissalComplete(in: [.parentSheet]))
        #expect(tracker.isDismissalComplete(in: [.parentSheet, .replacementAlert]))
    }

    @Test func presentationAlreadyVisibleAtActivationIsNotAddedToBaseline() {
        var tracker = PresentationPathTracker<SyntheticLayer>()

        tracker.begin(
            scopePrefix: [.parentSheet],
            currentPath: [.parentSheet, .targetAlert]
        )

        #expect(tracker.baseline == [.parentSheet])
        #expect(tracker.trackedLayer == .targetAlert)
        #expect(!tracker.isDismissalComplete(in: [.parentSheet, .targetAlert]))
        #expect(tracker.isDismissalComplete(in: [.parentSheet]))
    }

    @Test func lateActivationDoesNotPromoteNestedSystemUIToTarget() {
        var tracker = PresentationPathTracker<SyntheticLayer>()

        tracker.begin(
            scopePrefix: [.parentSheet],
            currentPath: [.parentSheet, .targetAlert, .nestedSystemUI]
        )

        #expect(tracker.trackedLayer == .targetAlert)
        #expect(!tracker.isDismissalComplete(
            in: [.parentSheet, .targetAlert, .replacementAlert]
        ))
    }
}
