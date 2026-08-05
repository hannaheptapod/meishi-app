import Foundation
import Testing
@testable import eMeishi

@MainActor
struct PersistentStoreLoadStateTests {
    @Test func waitsForEveryStoreBeforeBecomingLoaded() {
        let monitor = PersistentStoreLoadMonitor(expectedStoreCount: 2)

        #expect(!monitor.recordCompletion(failure: nil))
        #expect(monitor.state == .loading)
        #expect(monitor.recordCompletion(failure: nil))
        #expect(monitor.state == .loaded)
    }

    @Test func preservesTheFirstFailureUntilEveryStoreFinishes() {
        let monitor = PersistentStoreLoadMonitor(expectedStoreCount: 2)
        let failure = PersistentStoreLoadFailure(
            error: NSError(domain: "SyntheticStore", code: 42)
        )

        #expect(!monitor.recordCompletion(failure: failure))
        #expect(monitor.state == .loading)
        #expect(!monitor.recordCompletion(failure: nil))
        #expect(monitor.state == .failed(failure))
    }

    @Test func inMemoryControllerPublishesItsFinalLoadState() async {
        let controller = PersistenceController(inMemory: true)

        let state = await controller.storeLoadMonitor.waitUntilFinished()

        #expect(state == .loaded)
    }
}
