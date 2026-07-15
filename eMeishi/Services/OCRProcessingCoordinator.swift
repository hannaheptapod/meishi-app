import Foundation

/// OCR の進捗、実測ベース ETA、未処理画像の復元情報を管理する。
actor OCRProcessingCoordinator {
    static let shared = OCRProcessingCoordinator()

#if DEBUG
    static let debugDelayDefaultsKey = "ocrDebugPhaseDelaySeconds"
#endif

    private let defaults = UserDefaults.standard
    private let durationKey = "ocrPhaseAverageDurations"
    private var sessions: [OCRJobID: OCRJobSession] = [:]
    private var phaseStartedAt: [OCRJobID: ContinuousClock.Instant] = [:]
    private var averages: [String: Double]

    private init() {
        averages = UserDefaults.standard.dictionary(forKey: durationKey) as? [String: Double] ?? [:]
    }

    func start(jobID: OCRJobID, totalItems: Int) -> OCRProcessingState {
        let state = OCRProcessingState(
            phase: .imagePreparation,
            completedItems: 0,
            totalItems: max(1, totalItems),
            progress: OCRProcessingPhase.imagePreparation.progressRange.lowerBound,
            estimatedRemainingSeconds: estimateRemaining(from: .imagePreparation),
            errorMessage: nil
        )
        sessions[jobID] = OCRJobSession(
            id: jobID,
            state: state,
            startedAt: Date(),
            finishedAt: nil
        )
        phaseStartedAt[jobID] = .now
        return state
    }

    func transition(jobID: OCRJobID, to phase: OCRProcessingPhase) -> OCRProcessingState? {
        guard var session = sessions[jobID], !session.isTerminal,
              !Self.terminalPhases.contains(phase),
              Self.phaseOrder(phase) >= Self.phaseOrder(session.state.phase) else {
            return nil
        }
        recordCurrentPhaseDuration(jobID: jobID, state: session.state)
        session.state.phase = phase
        session.state.progress = max(session.state.progress, phase.progressRange.lowerBound)
        session.state.estimatedRemainingSeconds = estimateRemaining(from: phase)
        session.state.errorMessage = nil
        sessions[jobID] = session
        phaseStartedAt[jobID] = .now
        return session.state
    }

    func updateFraction(jobID: OCRJobID, _ fraction: Double) -> OCRProcessingState? {
        guard var session = sessions[jobID], !session.isTerminal else { return nil }
        let bounded = min(max(fraction, 0), 1)
        let range = session.state.phase.progressRange
        session.state.progress = max(
            session.state.progress,
            range.lowerBound + (range.upperBound - range.lowerBound) * bounded
        )
        sessions[jobID] = session
        return session.state
    }

    func complete(jobID: OCRJobID) -> OCRProcessingState? {
        guard var session = sessions[jobID], !session.isTerminal else { return nil }
        recordCurrentPhaseDuration(jobID: jobID, state: session.state)
        session.state.completedItems = session.state.totalItems
        session.state.progress = 1
        session.state.phase = .completed
        session.state.estimatedRemainingSeconds = nil
        session.finishedAt = Date()
        sessions[jobID] = session
        phaseStartedAt[jobID] = nil
        return session.state
    }

    func fail(jobID: OCRJobID, message: String) -> OCRProcessingState? {
        guard var session = sessions[jobID], !session.isTerminal else { return nil }
        session.state.phase = .failed
        session.state.errorMessage = message
        session.state.estimatedRemainingSeconds = nil
        session.finishedAt = Date()
        sessions[jobID] = session
        phaseStartedAt[jobID] = nil
        return session.state
    }

    func cancel(jobID: OCRJobID) -> OCRProcessingState? {
        guard var session = sessions[jobID], !session.isTerminal else {
            return sessions[jobID]?.state
        }
        session.state.phase = .cancelled
        session.state.estimatedRemainingSeconds = nil
        session.finishedAt = Date()
        sessions[jobID] = session
        phaseStartedAt[jobID] = nil
        return session.state
    }

    func currentState(jobID: OCRJobID) -> OCRProcessingState? {
        sessions[jobID]?.state
    }

    func session(jobID: OCRJobID) -> OCRJobSession? {
        sessions[jobID]
    }

#if DEBUG
    /// 高性能端末でも進捗表示・バックグラウンド継続を検証できるよう、
    /// Debugビルドだけ各処理段階を指定秒数維持する。
    func waitForConfiguredTestDelay(jobID: OCRJobID) async throws {
        let seconds = configuredTestDelay
        guard sessions[jobID]?.isTerminal == false else { throw CancellationError() }
        guard seconds > 0 else {
            try Task.checkCancellation()
            return
        }
        try await Task.sleep(for: .seconds(seconds))
        try Task.checkCancellation()
        guard sessions[jobID]?.isTerminal == false else { throw CancellationError() }
    }
#endif

    private func recordCurrentPhaseDuration(jobID: OCRJobID, state: OCRProcessingState) {
        guard let started = phaseStartedAt[jobID],
              !Self.terminalPhases.contains(state.phase), state.phase != .idle else { return }
        let components = started.duration(to: .now).components
        let elapsed = Double(components.seconds) + Double(components.attoseconds) / 1e18
        // 人工遅延は端末性能の実測値ではないため、学習用平均には含めない。
        let measuredElapsed = max(0, elapsed - configuredTestDelay)
        guard measuredElapsed > 0 else { return }
        let key = state.phase.rawValue
        let previous = averages[key]
        averages[key] = previous.map { $0 * 0.7 + measuredElapsed * 0.3 } ?? measuredElapsed
        defaults.set(averages, forKey: durationKey)
    }

    private func estimateRemaining(from phase: OCRProcessingPhase) -> TimeInterval {
        let defaultsByPhase: [OCRProcessingPhase: Double] = [
            .imagePreparation: 1.5,
            .textRecognition: 4,
            .fieldAnalysis: 1.5,
            .aiAssistance: 12,
            .saving: 0.5,
        ]
        let activePhases: [OCRProcessingPhase] = [
            .imagePreparation, .textRecognition, .fieldAnalysis, .aiAssistance, .saving,
        ]
        guard let startIndex = activePhases.firstIndex(of: phase) else { return 0 }
        return activePhases[startIndex...].reduce(0) { total, item in
            total
                + (averages[item.rawValue] ?? defaultsByPhase[item] ?? 0)
                + configuredTestDelay
        }
    }

    private var configuredTestDelay: TimeInterval {
#if DEBUG
        max(0, defaults.double(forKey: Self.debugDelayDefaultsKey))
#else
        0
#endif
    }

    private static let terminalPhases: Set<OCRProcessingPhase> = [.completed, .cancelled, .failed]

    private static func phaseOrder(_ phase: OCRProcessingPhase) -> Int {
        switch phase {
        case .idle: 0
        case .imagePreparation: 1
        case .textRecognition: 2
        case .fieldAnalysis: 3
        case .aiAssistance: 4
        case .saving: 5
        case .completed, .cancelled, .failed: 6
        }
    }
}
