import Foundation
import Testing
@testable import eMeishi

@Suite(.serialized)
struct OCRProcessingCoordinatorTests {
    @Test
    func terminalStateRejectsLaterTransitionsAndCompletion() async {
        let coordinator = OCRProcessingCoordinator.shared
        let jobID = OCRJobID()

        _ = await coordinator.start(jobID: jobID, totalItems: 1)
        _ = await coordinator.transition(jobID: jobID, to: .textRecognition)
        let cancelled = await coordinator.cancel(jobID: jobID)

        #expect(cancelled?.phase == .cancelled)
        #expect(await coordinator.transition(jobID: jobID, to: .saving) == nil)
        #expect(await coordinator.updateFraction(jobID: jobID, 1) == nil)
        #expect(await coordinator.complete(jobID: jobID) == nil)
        #expect(await coordinator.currentState(jobID: jobID)?.phase == .cancelled)
    }

    @Test
    func jobsCannotOverwriteEachOther() async {
        let coordinator = OCRProcessingCoordinator.shared
        let first = OCRJobID()
        let second = OCRJobID()

        _ = await coordinator.start(jobID: first, totalItems: 1)
        _ = await coordinator.start(jobID: second, totalItems: 10)
        _ = await coordinator.cancel(jobID: first)
        _ = await coordinator.transition(jobID: second, to: .fieldAnalysis)

        #expect(await coordinator.currentState(jobID: first)?.phase == .cancelled)
        #expect(await coordinator.currentState(jobID: second)?.phase == .fieldAnalysis)
        #expect(await coordinator.currentState(jobID: second)?.totalItems == 10)
    }

    @Test
    func progressIsMonotonicWithinAJob() async {
        let coordinator = OCRProcessingCoordinator.shared
        let jobID = OCRJobID()
        let started = await coordinator.start(jobID: jobID, totalItems: 1)
        let advanced = await coordinator.updateFraction(jobID: jobID, 0.8)
        let regressed = await coordinator.updateFraction(jobID: jobID, 0.2)

        #expect((advanced?.progress ?? 0) >= started.progress)
        #expect(regressed?.progress == advanced?.progress)
    }
}
