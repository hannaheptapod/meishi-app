import Foundation

nonisolated struct OCRJobID: Hashable, Codable, Sendable {
    let rawValue: UUID

    init(rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }
}

nonisolated enum OCRProcessingPhase: String, Codable, CaseIterable, Sendable {
    case idle
    case imagePreparation
    case textRecognition
    case fieldAnalysis
    case aiAssistance
    case saving
    case completed
    case cancelled
    case failed

    nonisolated var title: String {
        switch self {
        case .idle: "待機中"
        case .imagePreparation: "画像を準備中"
        case .textRecognition: "文字を認識中"
        case .fieldAnalysis: "項目を解析中"
        case .aiAssistance: "AIで補完中"
        case .saving: "結果を準備中"
        case .completed: "完了"
        case .cancelled: "キャンセルしました"
        case .failed: "処理に失敗しました"
        }
    }

    nonisolated var progressRange: ClosedRange<Double> {
        switch self {
        case .idle: 0...0
        case .imagePreparation: 0.02...0.12
        case .textRecognition: 0.12...0.48
        case .fieldAnalysis: 0.48...0.68
        case .aiAssistance: 0.68...0.94
        case .saving: 0.94...0.99
        case .completed: 1...1
        case .cancelled, .failed: 0...1
        }
    }
}

nonisolated struct OCRProcessingState: Codable, Equatable, Sendable {
    var phase: OCRProcessingPhase
    var completedItems: Int
    var totalItems: Int
    var progress: Double
    var estimatedRemainingSeconds: TimeInterval?
    var errorMessage: String?

    nonisolated static let idle = OCRProcessingState(
        phase: .idle,
        completedItems: 0,
        totalItems: 0,
        progress: 0,
        estimatedRemainingSeconds: nil,
        errorMessage: nil
    )

    var remainingTimeText: String? {
        guard let seconds = estimatedRemainingSeconds, seconds > 0 else { return nil }
        if seconds < 60 { return "残り約\(max(1, Int(seconds.rounded())))秒" }
        return "残り約\(Int(ceil(seconds / 60)))分"
    }
}

nonisolated struct OCRJobSession: Codable, Equatable, Sendable {
    let id: OCRJobID
    var state: OCRProcessingState
    let startedAt: Date
    var finishedAt: Date?

    var isTerminal: Bool {
        state.phase == .completed || state.phase == .cancelled || state.phase == .failed
    }
}
