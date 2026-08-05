import Testing
@testable import eMeishi

struct OCRProcessingStateTests {
    @Test
    func activePhaseProgressDoesNotMoveBackward() {
        let phases: [OCRProcessingPhase] = [
            .imagePreparation,
            .textRecognition,
            .fieldAnalysis,
            .aiAssistance,
            .saving,
            .completed,
        ]
        let lowerBounds = phases.map { $0.progressRange.lowerBound }

        for pair in zip(lowerBounds, lowerBounds.dropFirst()) {
            #expect(pair.0 <= pair.1)
        }
    }

    @Test @MainActor
    func remainingTimeIsPresentedAsAnEstimate() {
        var state = OCRProcessingState.idle
        state.estimatedRemainingSeconds = 75

        #expect(state.remainingTimeText == "残り約2分")
    }
}
