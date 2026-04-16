import Foundation
import CoreData
import CoreML
#if canImport(FoundationModels)
import FoundationModels
#endif

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
        var pairs: [DuplicatePair] = []

        for i in 0 ..< cards.count {
            for j in (i + 1) ..< cards.count {
                let a = cards[i]
                let b = cards[j]
                if let pair = evaluate(a, b) {
                    pairs.append(pair)
                }
            }
        }

        return pairs.sorted { $0.score > $1.score }
    }

    // MARK: - スコア計算

    /// 2枚の名刺を比較し、重複候補なら DuplicatePair を返す
    private func evaluate(_ a: BusinessCard, _ b: BusinessCard) -> DuplicatePair? {
        let nameSim    = similarity(a.fullName, b.fullName)
        let companyA = LegalEntityTerms.stripKanji(from: a.company ?? "")
        let companyB = LegalEntityTerms.stripKanji(from: b.company ?? "")
        let companySim = similarity(companyA, companyB)

        let score: Double
        if nameSim == 1.0 {
            score = 1.0
        } else {
            // 氏名 70% ・会社名 30% の加重平均
            score = nameSim * 0.7 + companySim * 0.3
        }

        guard score >= threshold else { return nil }
        guard !a.fullName.isEmpty || !b.fullName.isEmpty else { return nil }

        return DuplicatePair(cardA: a, cardB: b, score: score)
    }

    // MARK: - AI 二次判定の中間表現

    /// AI 二次判定中、ID 化された DuplicatePair と元の BusinessCard 参照を一時的に紐付ける。
    /// Sendable 化された DuplicatePair から CoreData オブジェクトを再解決するコストを避けるため。
    private struct BorderlineCandidate {
        let pair: DuplicatePair
        let cardA: BusinessCard
        let cardB: BusinessCard
    }

    // MARK: - AI重複検証（readingMethod に従いエンジンを選択）

    /// ルールベースの結果にAI二次判定を加えた重複候補を返す
    /// ボーダーライン候補（閾値未満だがスコア0.5以上）を捕捉し、転職・会社名表記揺れを検出
    func findDuplicatesWithAI(in cards: [BusinessCard]) async -> [DuplicatePair] {
        var pairs = findDuplicates(in: cards)

        // ボーダーライン候補を収集（閾値の-0.25〜閾値未満）
        let lowerBound = max(0.3, threshold - 0.25)
        var candidates: [BorderlineCandidate] = []
        for i in 0 ..< cards.count {
            for j in (i + 1) ..< cards.count {
                let a = cards[i]
                let b = cards[j]
                let nameSim = similarity(a.fullName, b.fullName)
                let companyA = LegalEntityTerms.stripKanji(from: a.company ?? "")
                let companyB = LegalEntityTerms.stripKanji(from: b.company ?? "")
                let companySim = similarity(companyA, companyB)
                let score = nameSim * 0.7 + companySim * 0.3
                if score >= lowerBound && score < threshold {
                    let pair = DuplicatePair(cardA: a, cardB: b, score: score)
                    candidates.append(BorderlineCandidate(pair: pair, cardA: a, cardB: b))
                }
            }
        }

        guard !candidates.isEmpty else { return pairs }

        let readingMethod = await MainActor.run { SettingsStore.shared.readingMethod }
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
        candidates: [BorderlineCandidate],
        confirmed: [DuplicatePair]
    ) async -> [DuplicatePair] {
        var pairs = confirmed
        let instructions = "2枚の名刺が同一人物か判定せよ。yes か no のみ回答。転職で会社名が変わっていても同一人物なら yes。"

        for candidate in candidates.prefix(10) {
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
        candidates: [BorderlineCandidate],
        confirmed: [DuplicatePair]
    ) async -> [DuplicatePair] {
        var pairs = confirmed
        let llm = LocalLLMService.shared
        guard let models = llm.ensureModelLoaded() else { return pairs }

        for candidate in candidates.prefix(10) {
            let isMatch = await verifyDuplicateWithQwen(
                card1: candidate.cardA,
                card2: candidate.cardB,
                prefill: models.prefill,
                tokenizer: models.tokenizer
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
    private func verifyDuplicateWithQwen(card1: BusinessCard, card2: BusinessCard,
                                         prefill: MLModel, tokenizer: Qwen25Tokenizer) async -> Bool {
        let summary1 = cardSummary(card1)
        let summary2 = cardSummary(card2)
        let prompt = "<|im_start|>system\nAre these two business cards the same person? Reply yes or no.<|im_end|>\n<|im_start|>user\nCard1: \(summary1)\nCard2: \(summary2)\nSame person?<|im_end|>\n<|im_start|>assistant\n/no_think\n"

        let ids = tokenizer.encode(prompt)
        do {
            let logits = try await LocalLLMService.shared.forwardPrefill(model: prefill, ids: ids, seqLen: ids.count)
            guard let tokenId = LocalLLMService.shared.argmaxLastToken(logits: logits) else { return false }
            let decoded = tokenizer.decode([tokenId]).lowercased()
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return decoded.hasPrefix("y") || decoded.hasPrefix("はい") || decoded.hasPrefix("yes")
        } catch {
            return false
        }
    }

    private func cardSummary(_ card: BusinessCard) -> String {
        [card.fullName, card.company ?? "", card.title ?? "", card.department ?? ""]
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    // MARK: - 文字列類似度（正規化 Levenshtein）

    /// 0.0（完全不一致）〜 1.0（完全一致）を返す
    func similarity(_ s1: String, _ s2: String) -> Double {
        let a = s1.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let b = s2.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        if a == b { return 1.0 }
        if a.isEmpty || b.isEmpty { return 0.0 }

        let dist = levenshtein(a, b)
        let maxLen = Double(max(a.count, b.count))
        return 1.0 - Double(dist) / maxLen
    }

    // MARK: - Levenshtein 距離

    private func levenshtein(_ s1: String, _ s2: String) -> Int {
        let a = Array(s1)
        let b = Array(s2)
        let m = a.count
        let n = b.count

        var dp = Array(repeating: Array(repeating: 0, count: n + 1), count: m + 1)

        for i in 0...m { dp[i][0] = i }
        for j in 0...n { dp[0][j] = j }

        for i in 1...m {
            for j in 1...n {
                if a[i - 1] == b[j - 1] {
                    dp[i][j] = dp[i - 1][j - 1]
                } else {
                    dp[i][j] = 1 + min(dp[i - 1][j],
                                       dp[i][j - 1],
                                       dp[i - 1][j - 1])
                }
            }
        }
        return dp[m][n]
    }
}

// MARK: - 重複ペアモデル

/// 重複候補の値型表現。NSManagedObject 参照を持たず Sendable に適合する。
/// View 層で復元する場合は `NSManagedObjectContext.businessCard(forURIString:)` を使う。
struct DuplicatePair: Identifiable, Sendable {
    var id: String { "\(cardAIDURI)-\(cardBIDURI)" }
    /// `cardA.objectID.uriRepresentation().absoluteString`
    let cardAIDURI: String
    /// `cardB.objectID.uriRepresentation().absoluteString`
    let cardBIDURI: String
    /// 類似スコア（0.0〜1.0）
    let score: Double
    /// AI検証で検出されたペアかどうか
    var isAIDetected: Bool = false

    /// スコアをパーセント文字列で返す
    var scoreText: String {
        "\(Int(score * 100))%"
    }

    /// BusinessCard ペアから ID 化された DuplicatePair を構築する。
    /// NSManagedObjectID は thread-safe なため呼び出し isolation は要求しない。
    init(cardA: BusinessCard, cardB: BusinessCard, score: Double, isAIDetected: Bool = false) {
        self.cardAIDURI = cardA.objectID.uriRepresentation().absoluteString
        self.cardBIDURI = cardB.objectID.uriRepresentation().absoluteString
        self.score = score
        self.isAIDetected = isAIDetected
    }
}
