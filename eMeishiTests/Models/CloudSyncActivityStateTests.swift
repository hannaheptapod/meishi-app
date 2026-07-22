import Foundation
import Testing
@testable import eMeishi

struct CloudSyncActivityStateTests {
    @Test func oneCompletionDoesNotHideAnotherActiveEvent() {
        let first = UUID()
        let second = UUID()
        let completedAt = Date(timeIntervalSinceReferenceDate: 100)
        var state = CloudSyncActivityState()

        state.apply(identifier: first, endDate: nil, failed: false)
        state.apply(identifier: second, endDate: nil, failed: false)
        state.apply(identifier: first, endDate: completedAt, failed: false)

        #expect(state.isSyncing)
        #expect(state.activeEventIDs == Set([second]))
        #expect(state.lastSuccessDate == completedAt)
        #expect(!state.lastEventFailed)
    }

    @Test func finalCompletionClearsSyncingAndRecordsFailure() {
        let identifier = UUID()
        let completedAt = Date(timeIntervalSinceReferenceDate: 200)
        var state = CloudSyncActivityState()

        state.apply(identifier: identifier, endDate: nil, failed: false)
        state.apply(identifier: identifier, endDate: completedAt, failed: true)

        #expect(!state.isSyncing)
        #expect(state.activeEventIDs.isEmpty)
        #expect(state.lastSuccessDate == nil)
        #expect(state.lastEventFailed)
    }
}
