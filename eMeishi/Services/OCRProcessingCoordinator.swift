import Foundation

nonisolated enum OCRAIWorkloadBackend: String, Sendable {
    case none
    case foundationModels
    case localLLM
}

/// 実際に処理する画像・OCR結果・AI入力の規模。
nonisolated struct OCRProcessingWorkload: Equatable, Sendable {
    var imageMegapixels: Double
    var imageMegabytes: Double
    var recognizedLineCount: Int
    var recognizedCharacterCount: Int
    var ambiguousSpanCount: Int
    var aiInputTokenEstimate: Int
    var aiOutputTokenEstimate: Int
    var aiBackend: OCRAIWorkloadBackend
    var aiRequired: Bool?

    static let unknown = OCRProcessingWorkload(
        imageMegapixels: 0,
        imageMegabytes: 0,
        recognizedLineCount: 0,
        recognizedCharacterCount: 0,
        ambiguousSpanCount: 0,
        aiInputTokenEstimate: 0,
        aiOutputTokenEstimate: 0,
        aiBackend: .none,
        aiRequired: false
    )
}

/// OCR の進捗、実測ベース ETA、未処理画像の復元情報を管理する。
actor OCRProcessingCoordinator {
    static let shared = OCRProcessingCoordinator()

#if DEBUG
    static let debugDelayDefaultsKey = "ocrDebugPhaseDelaySeconds"
#endif

    private let defaults = UserDefaults.standard
    private let calibrationKey = "ocrPhaseWorkloadCalibration.v1"
    nonisolated static let terminalSessionRetentionLimit = 128
    private var sessions: [OCRJobID: OCRJobSession] = [:]
    private var phaseStartedAt: [OCRJobID: ContinuousClock.Instant] = [:]
    private var workloads: [OCRJobID: OCRProcessingWorkload] = [:]
    private var terminalJobIDs: [OCRJobID] = []
    private var calibrations: [String: Double]

    private init() {
        calibrations = UserDefaults.standard.dictionary(forKey: calibrationKey) as? [String: Double] ?? [:]
    }

    func start(
        jobID: OCRJobID,
        totalItems: Int,
        workload: OCRProcessingWorkload = .unknown
    ) -> OCRProcessingState {
        // デコード開始前など、セッション生成より先に届いたキャンセルを上書きしない。
        if let existing = sessions[jobID], existing.isTerminal {
            return existing.state
        }
        workloads[jobID] = workload
        let state = OCRProcessingState(
            phase: .imagePreparation,
            completedItems: 0,
            totalItems: max(1, totalItems),
            progress: OCRProcessingPhase.imagePreparation.progressRange.lowerBound,
            estimatedRemainingSeconds: estimateRemaining(jobID: jobID, from: .imagePreparation),
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
        // 新しい段階の ETA から、直前段階の経過時間を誤って差し引かない。
        phaseStartedAt[jobID] = .now
        session.state.phase = phase
        session.state.progress = max(session.state.progress, phase.progressRange.lowerBound)
        session.state.estimatedRemainingSeconds = estimateRemaining(jobID: jobID, from: phase)
        session.state.errorMessage = nil
        sessions[jobID] = session
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
        session.state.estimatedRemainingSeconds = estimateRemaining(jobID: jobID, from: session.state.phase)
        sessions[jobID] = session
        return session.state
    }

    func updateImageMetrics(
        jobID: OCRJobID,
        megapixels: Double,
        megabytes: Double
    ) -> OCRProcessingState? {
        guard var workload = workloads[jobID], var session = sessions[jobID], !session.isTerminal else {
            return nil
        }
        workload.imageMegapixels = max(0, megapixels)
        workload.imageMegabytes = max(0, megabytes)
        workloads[jobID] = workload
        session.state.estimatedRemainingSeconds = estimateRemaining(jobID: jobID, from: session.state.phase)
        sessions[jobID] = session
        return session.state
    }

    func updateRecognitionMetrics(
        jobID: OCRJobID,
        lineCount: Int,
        characterCount: Int
    ) -> OCRProcessingState? {
        guard var workload = workloads[jobID], var session = sessions[jobID], !session.isTerminal else {
            return nil
        }
        workload.recognizedLineCount = max(0, lineCount)
        workload.recognizedCharacterCount = max(0, characterCount)
        workloads[jobID] = workload
        session.state.estimatedRemainingSeconds = estimateRemaining(jobID: jobID, from: session.state.phase)
        sessions[jobID] = session
        return session.state
    }

    func updateAIPlan(
        jobID: OCRJobID,
        backend: OCRAIWorkloadBackend,
        required: Bool,
        ambiguousSpanCount: Int,
        inputTokenEstimate: Int,
        outputTokenEstimate: Int
    ) -> OCRProcessingState? {
        guard var workload = workloads[jobID], var session = sessions[jobID], !session.isTerminal else {
            return nil
        }
        workload.aiBackend = backend
        workload.aiRequired = required && backend != .none
        workload.ambiguousSpanCount = max(0, ambiguousSpanCount)
        workload.aiInputTokenEstimate = max(0, inputTokenEstimate)
        workload.aiOutputTokenEstimate = max(0, outputTokenEstimate)
        workloads[jobID] = workload
        session.state.estimatedRemainingSeconds = estimateRemaining(jobID: jobID, from: session.state.phase)
        sessions[jobID] = session
        return session.state
    }

    /// 現在段階の経過時間を差し引き、画面とLive ActivityのETAを更新する。
    func refreshEstimate(jobID: OCRJobID) -> OCRProcessingState? {
        guard var session = sessions[jobID], !session.isTerminal else { return nil }
        session.state.estimatedRemainingSeconds = estimateRemaining(jobID: jobID, from: session.state.phase)
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
        workloads[jobID] = nil
        retainTerminalSession(jobID: jobID)
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
        workloads[jobID] = nil
        retainTerminalSession(jobID: jobID)
        return session.state
    }

    func cancel(jobID: OCRJobID) -> OCRProcessingState? {
        guard var session = sessions[jobID] else {
            let state = OCRProcessingState(
                phase: .cancelled,
                completedItems: 0,
                totalItems: 1,
                progress: 0,
                estimatedRemainingSeconds: nil,
                errorMessage: nil
            )
            sessions[jobID] = OCRJobSession(
                id: jobID,
                state: state,
                startedAt: Date(),
                finishedAt: Date()
            )
            retainTerminalSession(jobID: jobID)
            return state
        }
        guard !session.isTerminal else {
            return session.state
        }
        session.state.phase = .cancelled
        session.state.estimatedRemainingSeconds = nil
        session.finishedAt = Date()
        sessions[jobID] = session
        phaseStartedAt[jobID] = nil
        workloads[jobID] = nil
        retainTerminalSession(jobID: jobID)
        return session.state
    }

    func currentState(jobID: OCRJobID) -> OCRProcessingState? {
        sessions[jobID]?.state
    }

    func session(jobID: OCRJobID) -> OCRJobSession? {
        sessions[jobID]
    }

    func retainedTerminalSessionCount() -> Int {
        terminalJobIDs.count
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
        guard let workload = workloads[jobID] else { return }
        let baseline = Self.baselineDuration(for: state.phase, workload: workload)
        guard baseline > 0 else { return }
        let observedCalibration = min(max(measuredElapsed / baseline, 0.25), 4)
        let key = calibrationKey(for: state.phase, workload: workload)
        let previous = calibrations[key]
        calibrations[key] = previous.map { $0 * 0.7 + observedCalibration * 0.3 }
            ?? observedCalibration
        defaults.set(calibrations, forKey: calibrationKey)
    }

    private func estimateRemaining(jobID: OCRJobID, from phase: OCRProcessingPhase) -> TimeInterval {
        guard let workload = workloads[jobID] else { return 0 }
        let activePhases: [OCRProcessingPhase] = [
            .imagePreparation, .textRecognition, .fieldAnalysis, .aiAssistance, .saving,
        ]
        guard let startIndex = activePhases.firstIndex(of: phase) else { return 0 }
        let plannedPhases = activePhases[startIndex...].filter { item in
            item != .aiAssistance || workload.aiRequired != false
        }
        let elapsed = phaseElapsed(jobID: jobID)
        return plannedPhases.reduce(0) { total, item in
            let predicted = calibratedDuration(for: item, workload: workload) + configuredTestDelay
            return total + (item == phase ? max(0, predicted - elapsed) : predicted)
        }
    }

    /// 入力内容だけから算出する端末補正前の所要時間。
    nonisolated static func baselineDuration(
        for phase: OCRProcessingPhase,
        workload: OCRProcessingWorkload
    ) -> TimeInterval {
        switch phase {
        case .imagePreparation:
            return 0.35 + workload.imageMegapixels * 0.07 + workload.imageMegabytes * 0.015
        case .textRecognition:
            return 0.8 + workload.imageMegapixels * 0.27
        case .fieldAnalysis:
            return 0.4
                + Double(workload.recognizedLineCount) * 0.04
                + Double(workload.recognizedCharacterCount) * 0.002
        case .aiAssistance:
            guard workload.aiRequired != false else { return 0 }
            let input = Double(max(32, workload.aiInputTokenEstimate))
            let output = Double(max(1, workload.aiOutputTokenEstimate))
            let ambiguous = Double(max(1, workload.ambiguousSpanCount))
            switch workload.aiBackend {
            case .foundationModels:
                return 0.8 + input * 0.008 + output * 0.025
            case .localLLM:
                // Qwenは曖昧spanごとに文脈付き推論を行うため、入力処理も件数分掛かる。
                return 1.5 + ambiguous * (0.65 + input * 0.01) + output * 0.02
            case .none:
                return 0
            }
        case .saving:
            return 0.15 + workload.imageMegabytes * 0.08
        case .idle, .completed, .cancelled, .failed:
            return 0
        }
    }

    private func calibratedDuration(
        for phase: OCRProcessingPhase,
        workload: OCRProcessingWorkload
    ) -> TimeInterval {
        let baseline = Self.baselineDuration(for: phase, workload: workload)
        return baseline * (calibrations[calibrationKey(for: phase, workload: workload)] ?? 1)
    }

    private func calibrationKey(
        for phase: OCRProcessingPhase,
        workload: OCRProcessingWorkload
    ) -> String {
        phase == .aiAssistance
            ? "\(phase.rawValue).\(workload.aiBackend.rawValue)"
            : phase.rawValue
    }

    private func phaseElapsed(jobID: OCRJobID) -> TimeInterval {
        guard let started = phaseStartedAt[jobID] else { return 0 }
        let components = started.duration(to: .now).components
        return max(0, Double(components.seconds) + Double(components.attoseconds) / 1e18)
    }

    private var configuredTestDelay: TimeInterval {
#if DEBUG
        max(0, defaults.double(forKey: Self.debugDelayDefaultsKey))
#else
        0
#endif
    }

    /// 遅延完了から終端状態を守るため一定数は保持しつつ、長時間利用時の無制限増加を防ぐ。
    private func retainTerminalSession(jobID: OCRJobID) {
        if let existingIndex = terminalJobIDs.firstIndex(of: jobID) {
            terminalJobIDs.remove(at: existingIndex)
        }
        terminalJobIDs.append(jobID)

        let overflow = terminalJobIDs.count - Self.terminalSessionRetentionLimit
        guard overflow > 0 else { return }
        let expiredIDs = Array(terminalJobIDs.prefix(overflow))
        terminalJobIDs.removeFirst(overflow)
        for expiredID in expiredIDs where sessions[expiredID]?.isTerminal == true {
            sessions[expiredID] = nil
            phaseStartedAt[expiredID] = nil
            workloads[expiredID] = nil
        }
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
