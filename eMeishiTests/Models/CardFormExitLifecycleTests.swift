import Foundation
import Testing
@testable import eMeishi

struct CardFormExitLifecycleTests {
    @Test
    func repeatedExitRequestIsRejectedUntilCurrentRequestCompletes() {
        var lifecycle = CardFormExitLifecycle()

        let first = lifecycle.begin(.skip)
        let duplicate = lifecycle.begin(.close)

        #expect(first?.action == .skip)
        #expect(duplicate == nil)
        #expect(lifecycle.isSkipping)
        #expect(!lifecycle.isClosing)
    }

    @Test
    func completionIsAcceptedExactlyOnceForMatchingRequest() {
        var lifecycle = CardFormExitLifecycle()
        let request = lifecycle.begin(.close)!

        let staleCompletion = lifecycle.complete(requestID: UUID())
        let firstCompletion = lifecycle.complete(requestID: request.id)
        let duplicateCompletion = lifecycle.complete(requestID: request.id)

        #expect(staleCompletion == nil)
        #expect(firstCompletion == .close)
        #expect(duplicateCompletion == nil)
        #expect(lifecycle.isClosing)
    }

    @Test
    func invalidationRejectsLateAsyncCompletion() {
        var lifecycle = CardFormExitLifecycle()
        let request = lifecycle.begin(.skip)!

        lifecycle.invalidate()

        #expect(lifecycle.complete(requestID: request.id) == nil)
        #expect(!lifecycle.isExiting)
    }
}
