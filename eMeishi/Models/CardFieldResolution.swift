import CoreGraphics
import Foundation

nonisolated enum CardFieldKind: String, CaseIterable, Hashable, Sendable {
    case personName
    case personNameReading
    case company
    case companyReading
    case department
    case title
    case address
    case phone
    case email
    case website
    case other
}

nonisolated enum FieldConfidence: Int, Comparable, Sendable {
    case low = 0
    case medium = 1
    case high = 2

    static func < (lhs: FieldConfidence, rhs: FieldConfidence) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

nonisolated enum FieldEvidence: String, Hashable, Sendable {
    case contactPattern
    case legalEntity
    case organizationKeyword
    case titleKeyword
    case nameShape
    case nearbyReading
    case relativeTypography
    case spatialContext
    case domainStem
    case aiAgreement
}

/// OCR 行またはその部分文字列。複合行を分割しても元 OCR 行との対応を失わない。
nonisolated struct CardTextSpan: Identifiable, Hashable, Sendable {
    let id: String
    let sourceLineIndex: Int
    let fragmentIndex: Int
    let text: String
    let boundingBox: CGRect
    let ocrConfidence: Float
    let textDirection: RecognizedTextDirection
    let readingOrder: Int

    init(
        id: String? = nil,
        sourceLineIndex: Int,
        fragmentIndex: Int = 0,
        text: String,
        boundingBox: CGRect,
        ocrConfidence: Float,
        textDirection: RecognizedTextDirection,
        readingOrder: Int
    ) {
        self.id = id ?? "\(sourceLineIndex):\(fragmentIndex)"
        self.sourceLineIndex = sourceLineIndex
        self.fragmentIndex = fragmentIndex
        self.text = text
        self.boundingBox = boundingBox
        self.ocrConfidence = ocrConfidence
        self.textDirection = textDirection
        self.readingOrder = readingOrder
    }
}

nonisolated struct FieldCandidate: Identifiable, Hashable, Sendable {
    let id: String
    let spanIDs: [String]
    let field: CardFieldKind
    let value: String
    let score: Double
    let evidence: Set<FieldEvidence>

    init(
        spanIDs: [String],
        field: CardFieldKind,
        value: String,
        score: Double,
        evidence: Set<FieldEvidence>
    ) {
        self.id = "\(field.rawValue):\(spanIDs.joined(separator: ","))"
        self.spanIDs = spanIDs
        self.field = field
        self.value = value
        self.score = min(max(score, 0), 1)
        self.evidence = evidence
    }
}

nonisolated struct FieldAssignment: Hashable, Sendable {
    enum Source: String, Hashable, Sendable {
        case deterministic
        case resolver
        case aiAssisted
    }

    let spanIDs: [String]
    let field: CardFieldKind
    let value: String
    let confidence: FieldConfidence
    let source: Source
}

nonisolated struct CardFieldResolutionRequest: Sendable {
    let spans: [CardTextSpan]
    let candidates: [FieldCandidate]
    let assignments: [FieldAssignment]
    let ambiguousSpanIDs: [String]
}

nonisolated struct CardFieldDecision: Hashable, Sendable {
    let spanID: String
    let field: CardFieldKind
}

nonisolated enum ReadingTarget: String, Hashable, Sendable {
    case lastName
    case firstName
    case company
}

nonisolated enum ReadingSource: String, Hashable, Sendable {
    case printedKana
    case printedRomaji
    case email
    case tokenizer
    case latinInitialism

    var displayName: String {
        switch self {
        case .printedKana: "名刺記載"
        case .printedRomaji: "ローマ字"
        case .email: "メール"
        case .tokenizer: "自動変換"
        case .latinInitialism: "英字略称"
        }
    }
}

nonisolated struct ReadingCandidate: Identifiable, Hashable, Sendable {
    let target: ReadingTarget
    let reading: String
    let source: ReadingSource
    let confidence: FieldConfidence
    let sourceSpanIDs: [String]

    var id: String { "\(target.rawValue):\(reading)" }
}

nonisolated struct ReadingResolution: Sendable {
    var automaticValues: [ReadingTarget: String] = [:]
    var candidates: [ReadingCandidate] = []

    func candidates(for target: ReadingTarget) -> [ReadingCandidate] {
        candidates.filter { $0.target == target }
    }
}
