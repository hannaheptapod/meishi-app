import Testing
@testable import eMeishi

struct AppLaunchAlertQueueTests {
    @Test func alertsAreConsumedInInsertionOrder() {
        var queue = AppLaunchAlertQueue()

        queue.enqueue(.qwenDownloadPrompt)
        queue.enqueue(.grandfatheredAnnouncement)

        #expect(queue.pending == [.qwenDownloadPrompt, .grandfatheredAnnouncement])
        #expect(queue.dequeue() == .qwenDownloadPrompt)
        #expect(queue.dequeue() == .grandfatheredAnnouncement)
        #expect(queue.dequeue() == nil)
    }

    @Test func duplicateAlertsAreNotQueuedTwice() {
        var queue = AppLaunchAlertQueue()

        queue.enqueue(.qwenDownloadPrompt)
        queue.enqueue(.qwenDownloadPrompt)
        queue.enqueue(.grandfatheredAnnouncement)
        queue.enqueue(.grandfatheredAnnouncement)

        #expect(queue.pending == [.qwenDownloadPrompt, .grandfatheredAnnouncement])
    }
}
