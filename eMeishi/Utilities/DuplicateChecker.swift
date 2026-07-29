import Foundation
import CoreData
#if canImport(FoundationModels)
import FoundationModels
#endif

/// CoreData 管理オブジェクトを並行処理へ渡さず、重複比較に必要な値だけを保持する。
nonisolated struct DuplicateCardSnapshot: Equatable, Sendable {
    let objectURI: String
    let fullName: String
    let company: String
    let normalizedCompany: String
    let title: String
    let department: String
}

nonisolated struct BorderlineDuplicateCandidate: Sendable {
    let pair: DuplicatePair
    let cardA: DuplicateCardSnapshot
    let cardB: DuplicateCardSnapshot
}

nonisolated struct DuplicateScanResult: Sendable {
    let confirmed: [DuplicatePair]
    let borderline: [BorderlineDuplicateCandidate]
}

/// O(n²) の全ペア比較を MainActor から分離する純粋計算ワーカー。
nonisolated private struct DuplicateScanWorker: Sendable {
    let threshold: Double

    func scan(
        _ cards: [DuplicateCardSnapshot],
        includeBorderline: Bool
    ) -> DuplicateScanResult? {
        var confirmed: [DuplicatePair] = []
        var borderline: [BorderlineDuplicateCandidate] = []
        let lowerBound = max(0.3, threshold - 0.25)

        for i in 0 ..< cards.count {
            guard !Task.isCancelled else { return nil }
            for j in (i + 1) ..< cards.count {
                guard !Task.isCancelled else { return nil }
                let a = cards[i]
                let b = cards[j]
                let nameSimilarity = similarity(a.fullName, b.fullName)
                let companySimilarity = similarity(a.normalizedCompany, b.normalizedCompany)
                let weightedScore = nameSimilarity * 0.7 + companySimilarity * 0.3
                let score = nameSimilarity == 1.0 ? 1.0 : weightedScore

                guard !a.fullName.isEmpty || !b.fullName.isEmpty else { continue }
                let pair = DuplicatePair(
                    cardAIDURI: a.objectURI,
                    cardBIDURI: b.objectURI,
                    cardASummary: DuplicateCardSummary(
                        fullName: a.fullName,
                        company: a.company
                    ),
                    cardBSummary: DuplicateCardSummary(
                        fullName: b.fullName,
                        company: b.company
                    ),
                    score: score
                )
                if score >= threshold {
                    confirmed.append(pair)
                } else if includeBorderline, weightedScore >= lowerBound {
                    borderline.append(
                        BorderlineDuplicateCandidate(pair: pair, cardA: a, cardB: b)
                    )
                }
            }
        }

        return DuplicateScanResult(
            confirmed: confirmed.sorted { $0.score > $1.score },
            borderline: borderline
        )
    }

    func similarity(_ s1: String, _ s2: String) -> Double {
        let a = s1.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let b = s2.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        if a == b { return 1.0 }
        if a.isEmpty || b.isEmpty { return 0.0 }

        let distance = levenshtein(a, b)
        return 1.0 - Double(distance) / Double(max(a.count, b.count))
    }

    private func levenshtein(_ s1: String, _ s2: String) -> Int {
        let a = Array(s1)
        let b = Array(s2)
        var previous = Array(0 ... b.count)

        for (i, lhs) in a.enumerated() {
            var current = Array(repeating: 0, count: b.count + 1)
            current[0] = i + 1
            for (j, rhs) in b.enumerated() {
                current[j + 1] = lhs == rhs
                    ? previous[j]
                    : 1 + min(previous[j + 1], current[j], previous[j])
            }
            previous = current
        }
        return previous[b.count]
    }
}

// 名前・会社名の類似度判定により重複候補を検出するユーティリティ
struct DuplicateChecker {

    /// 重複検出の閾値（0.0〜1.0、高いほど厳しい）
    private let threshold: Double

    init(threshold: Double = 0.75) {
        self.threshold = threshold
    }

    // MARK: - 重複検出（ルールベース）

    /// cards の中から重複候補ペアをすべて返す
    func findDuplicates(in cards: [BusinessCard]) -> [DuplicatePair] {
        DuplicateScanWorker(threshold: threshold)
            .scan(makeSnapshots(from: cards), includeBorderline: false)?
            .confirmed ?? []
    }

    // MARK: - スコア計算

    /// 2枚の名刺を比較し、重複候補なら DuplicatePair を返す
    /// MainActor 上では値の採取だけを行い、全ペア比較は detached task へ渡す。
    func scanRuleBased(
        snapshots: [DuplicateCardSnapshot],
        includeBorderline: Bool
    ) async -> DuplicateScanResult? {
        let worker = DuplicateScanWorker(threshold: threshold)
        let task = Task.detached(priority: .userInitiated) {
            worker.scan(snapshots, includeBorderline: includeBorderline)
        }
        return await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    func makeSnapshots(from cards: [BusinessCard]) -> [DuplicateCardSnapshot] {
        cards.map {
            DuplicateCardSnapshot(
                objectURI: $0.objectID.uriRepresentation().absoluteString,
                fullName: $0.fullName,
                company: $0.company ?? "",
                normalizedCompany: LegalEntityTerms.stripKanji(from: $0.company ?? ""),
                title: $0.title ?? "",
                department: $0.department ?? ""
            )
        }
    }

    // MARK: - AI重複検証（readingMethod に従いエンジンを選択）

    /// ルールベースの結果にAI二次判定を加えた重複候補を返す
    /// ボーダーライン候補（閾値未満だがスコア0.5以上）を捕捉し、転職・会社名表記揺れを検出
    @MainActor
    func findDuplicatesWithAI(in cards: [BusinessCard]) async -> [DuplicatePair] {
        guard let scan = await scanRuleBased(
            snapshots: makeSnapshots(from: cards),
            includeBorderline: true
        ) else { return [] }
        return await enhanceWithAI(scan)
    }

    @MainActor
    func enhanceWithAI(_ scan: DuplicateScanResult) async -> [DuplicatePair] {
        var pairs = scan.confirmed
        let candidates = scan.borderline
        guard !Task.isCancelled, !candidates.isEmpty else { return pairs }

        let readingMethod = SettingsStore.shared.readingMethod
        switch readingMethod {
        case .appleIntelligence:
            #if canImport(FoundationModels)
            if #available(iOS 26.0, *) {
                pairs = await verifyBorderlinePairsWithFoundationModels(
                    candidates: candidates, confirmed: pairs)
            }
            #endif

        case .localLLM:
            pairs = await verifyBorderlinePairsWithQwen(
                candidates: candidates, confirmed: pairs)

        case .automatic:
            #if canImport(FoundationModels)
            if #available(iOS 26.0, *) {
                if case .available = SystemLanguageModel.default.availability {
                    pairs = await verifyBorderlinePairsWithFoundationModels(
                        candidates: candidates, confirmed: pairs)
                    return pairs.sorted { $0.score > $1.score }
                }
            }
            #endif
            pairs = await verifyBorderlinePairsWithQwen(
                candidates: candidates, confirmed: pairs)
        }

        return pairs.sorted { $0.score > $1.score }
    }

    // MARK: - Foundation Models 二次判定

    #if canImport(FoundationModels)
    @available(iOS 26.0, *)
    private func verifyBorderlinePairsWithFoundationModels(
        candidates: [BorderlineDuplicateCandidate],
        confirmed: [DuplicatePair]
    ) async -> [DuplicatePair] {
        var pairs = confirmed
        let instructions = "2枚の名刺が同一人物か判定せよ。yes か no のみ回答。転職で会社名が変わっていても同一人物なら yes。"

        for candidate in candidates.prefix(10) {
            guard !Task.isCancelled else { return pairs }
            let summary1 = cardSummary(candidate.cardA)
            let summary2 = cardSummary(candidate.cardB)
            let session = LanguageModelSession(instructions: instructions)
            let options = GenerationOptions(temperature: 0)
            let prompt = "Card1: \(summary1)\nCard2: \(summary2)\n同一人物?"

            do {
                let response = try await session.respond(to: prompt, options: options)
                let text = String(describing: response.content)
                    .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                if text.hasPrefix("y") || text.hasPrefix("はい") {
                    var aiPair = candidate.pair
                    aiPair.isAIDetected = true
                    pairs.append(aiPair)
                }
            } catch {
                // エラー時はスキップ
            }
        }
        return pairs
    }
    #endif

    // MARK: - Qwen 二次判定（非対応端末フォールバック）

    private func verifyBorderlinePairsWithQwen(
        candidates: [BorderlineDuplicateCandidate],
        confirmed: [DuplicatePair]
    ) async -> [DuplicatePair] {
        var pairs = confirmed
        let llm = LocalLLMService.shared
        guard llm.isModelAvailable else { return pairs }

        for candidate in candidates.prefix(10) {
            guard !Task.isCancelled else { return pairs }
            let isMatch = await verifyDuplicateWithQwen(
                card1: candidate.cardA,
                card2: candidate.cardB
            )
            if isMatch {
                var aiPair = candidate.pair
                aiPair.isAIDetected = true
                pairs.append(aiPair)
            }
        }
        return pairs
    }

    /// 1ペアをQwenで同一人物判定
    private func verifyDuplicateWithQwen(
        card1: DuplicateCardSnapshot,
        card2: DuplicateCardSnapshot
    ) async -> Bool {
        let summary1 = cardSummary(card1)
        let summary2 = cardSummary(card2)
        let prompt = "<|im_start|>system\nAre these two business cards the same person? Reply yes or no.<|im_end|>\n<|im_start|>user\nCard1: \(summary1)\nCard2: \(summary2)\nSame person?<|im_end|>\n<|im_start|>assistant\n/no_think\n"

        return await LocalLLMService.shared.yesNo(prompt: prompt)
    }

    private func cardSummary(_ card: DuplicateCardSnapshot) -> String {
        [card.fullName, card.company, card.title, card.department]
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    // MARK: - 文字列類似度（正規化 Levenshtein）

    /// 0.0（完全不一致）〜 1.0（完全一致）を返す
    func similarity(_ s1: String, _ s2: String) -> Double {
        DuplicateScanWorker(threshold: threshold).similarity(s1, s2)
    }
}

// MARK: - 重複ペアモデル

/// 重複一覧の描画に必要な値だけを保持し、ViewのbodyからCore Data解決を除く。
nonisolated struct DuplicateCardSummary: Equatable, Sendable {
    let fullName: String
    let company: String
}

/// 重複候補の値型表現。NSManagedObject 参照を持たず Sendable に適合する。
/// View 層で復元する場合は `NSManagedObjectContext.businessCard(forURIString:)` を使う。
nonisolated struct DuplicatePair: Identifiable, Sendable {
    var id: String { "\(cardAIDURI)-\(cardBIDURI)" }
    /// `cardA.objectID.uriRepresentation().absoluteString`
    let cardAIDURI: String
    /// `cardB.objectID.uriRepresentation().absoluteString`
    let cardBIDURI: String
    let cardASummary: DuplicateCardSummary
    let cardBSummary: DuplicateCardSummary
    /// 類似スコア（0.0〜1.0）
    let score: Double
    /// AI検証で検出されたペアかどうか
    var isAIDetected: Bool = false

    /// スコアをパーセント文字列で返す
    var scoreText: String {
        "\(Int(score * 100))%"
    }

    /// MainActorのview context上にあるBusinessCardから、描画用の値を一度だけ抽出する。
    @MainActor
    init(cardA: BusinessCard, cardB: BusinessCard, score: Double, isAIDetected: Bool = false) {
        self.init(
            cardAIDURI: cardA.objectID.uriRepresentation().absoluteString,
            cardBIDURI: cardB.objectID.uriRepresentation().absoluteString,
            cardASummary: DuplicateCardSummary(
                fullName: cardA.fullName,
                company: cardA.company ?? ""
            ),
            cardBSummary: DuplicateCardSummary(
                fullName: cardB.fullName,
                company: cardB.company ?? ""
            ),
            score: score,
            isAIDetected: isAIDetected
        )
    }

    init(
        cardAIDURI: String,
        cardBIDURI: String,
        cardASummary: DuplicateCardSummary,
        cardBSummary: DuplicateCardSummary,
        score: Double,
        isAIDetected: Bool = false
    ) {
        self.cardAIDURI = cardAIDURI
        self.cardBIDURI = cardBIDURI
        self.cardASummary = cardASummary
        self.cardBSummary = cardBSummary
        self.score = score
        self.isAIDetected = isAIDetected
    }
}
