import Foundation
import Testing
@testable import eMeishi

@Suite(.serialized)
struct OCRProcessingCoordinatorTests {
    @Test
    func cancellationBeforeStartRemainsTerminal() async {
        let coordinator = OCRProcessingCoordinator.shared
        let jobID = OCRJobID()

        let cancelled = await coordinator.cancel(jobID: jobID)
        let attemptedStart = await coordinator.start(jobID: jobID, totalItems: 4)

        #expect(cancelled?.phase == .cancelled)
        #expect(attemptedStart.phase == .cancelled)
        #expect(await coordinator.transition(jobID: jobID, to: .textRecognition) == nil)
        #expect(await coordinator.currentState(jobID: jobID)?.phase == .cancelled)
    }

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

    @Test
    func imageAndOCRBaselineScaleWithPixelCount() {
        var small = OCRProcessingWorkload.unknown
        small.imageMegapixels = 2
        small.imageMegabytes = 1
        var large = small
        large.imageMegapixels = 48
        large.imageMegabytes = 12

        #expect(
            OCRProcessingCoordinator.baselineDuration(for: .imagePreparation, workload: large)
                > OCRProcessingCoordinator.baselineDuration(for: .imagePreparation, workload: small)
        )
        #expect(
            OCRProcessingCoordinator.baselineDuration(for: .textRecognition, workload: large)
                > OCRProcessingCoordinator.baselineDuration(for: .textRecognition, workload: small)
        )
    }

    @Test
    func analysisBaselineScalesWithRecognizedContent() {
        var short = OCRProcessingWorkload.unknown
        short.recognizedLineCount = 5
        short.recognizedCharacterCount = 80
        var long = short
        long.recognizedLineCount = 30
        long.recognizedCharacterCount = 700

        #expect(
            OCRProcessingCoordinator.baselineDuration(for: .fieldAnalysis, workload: long)
                > OCRProcessingCoordinator.baselineDuration(for: .fieldAnalysis, workload: short)
        )
    }

    @Test
    func localAIBaselineScalesWithAmbiguityAndTokens() {
        var light = OCRProcessingWorkload.unknown
        light.aiRequired = true
        light.aiBackend = .localLLM
        light.ambiguousSpanCount = 1
        light.aiInputTokenEstimate = 80
        light.aiOutputTokenEstimate = 8
        var heavy = light
        heavy.ambiguousSpanCount = 4
        heavy.aiInputTokenEstimate = 240
        heavy.aiOutputTokenEstimate = 32

        #expect(
            OCRProcessingCoordinator.baselineDuration(for: .aiAssistance, workload: heavy)
                > OCRProcessingCoordinator.baselineDuration(for: .aiAssistance, workload: light)
        )
    }

    @Test
    func resolvedFieldsRemoveUnusedAIFromEstimate() async {
        let coordinator = OCRProcessingCoordinator.shared
        let jobID = OCRJobID()
        var workload = OCRProcessingWorkload.unknown
        workload.imageMegapixels = 12
        workload.imageMegabytes = 3
        workload.aiBackend = .localLLM
        workload.aiRequired = nil

        let before = await coordinator.start(jobID: jobID, totalItems: 1, workload: workload)
        let after = await coordinator.updateAIPlan(
            jobID: jobID,
            backend: .localLLM,
            required: false,
            ambiguousSpanCount: 0,
            inputTokenEstimate: 0,
            outputTokenEstimate: 0
        )

        #expect((after?.estimatedRemainingSeconds ?? .infinity) < (before.estimatedRemainingSeconds ?? 0))
        _ = await coordinator.cancel(jobID: jobID)
    }

    @Test
    func terminalSessionRetentionIsBoundedAndKeepsNewestCancellation() async throws {
        let coordinator = OCRProcessingCoordinator.shared
        let jobIDs = (0..<(OCRProcessingCoordinator.terminalSessionRetentionLimit + 16)).map { _ in
            OCRJobID()
        }
        let firstJobID = try #require(jobIDs.first)
        let lastJobID = try #require(jobIDs.last)

        for jobID in jobIDs {
            _ = await coordinator.cancel(jobID: jobID)
        }

        #expect(
            await coordinator.retainedTerminalSessionCount()
                <= OCRProcessingCoordinator.terminalSessionRetentionLimit
        )
        #expect(await coordinator.currentState(jobID: firstJobID) == nil)
        #expect(await coordinator.currentState(jobID: lastJobID)?.phase == .cancelled)
    }
}
