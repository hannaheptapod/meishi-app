import Foundation
import CoreML

// 名前・会社名の類似度判定により重複候補を検出するユーティリティ
struct DuplicateChecker {

    /// 重複検出の閾値（0.0〜1.0、高いほど厳しい）
    private let threshold: Double

    init(threshold: Double = 0.75) {
        self.threshold = threshold
    }

    // MARK: - 重複検出

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

        // スコアの高い順に返す
        return pairs.sorted { $0.score > $1.score }
    }

    // MARK: - スコア計算

    /// 2枚の名刺を比較し、重複候補なら DuplicatePair を返す
    private func evaluate(_ a: BusinessCard, _ b: BusinessCard) -> DuplicatePair? {
        // フルネームと会社名の類似度を組み合わせてスコアを算出
        let nameSim    = similarity(a.fullName, b.fullName)
        let companyA = LegalEntityTerms.stripKanji(from: a.company ?? "")
        let companyB = LegalEntityTerms.stripKanji(from: b.company ?? "")
        let companySim = similarity(companyA, companyB)

        // 氏名が完全一致 or 氏名と会社名の加重平均が閾値以上
        let score: Double
        if nameSim == 1.0 {
            score = 1.0
        } else {
            // 氏名 70% ・会社名 30% の加重平均
            score = nameSim * 0.7 + companySim * 0.3
        }

        guard score >= threshold else { return nil }

        // 両方とも名前が空の場合は無視
        guard !a.fullName.isEmpty || !b.fullName.isEmpty else { return nil }

        return DuplicatePair(cardA: a, cardB: b, score: score)
    }

    // MARK: - AI重複検証

    /// ボーダーライン候補（閾値未満だがスコア0.5以上）をAIで二次判定する
    /// 会社名形式差異（「株式会社ABC」vs「ABC」）や転職ケースを捕捉
    func findDuplicatesWithAI(in cards: [BusinessCard]) async -> [DuplicatePair] {
        var pairs = findDuplicates(in: cards)

        // ボーダーライン候補を収集（閾値の-0.25〜閾値未満）
        let lowerBound = max(0.3, threshold - 0.25)
        var borderlinePairs: [DuplicatePair] = []
        for i in 0 ..< cards.count {
            for j in (i + 1) ..< cards.count {
                let a = cards[i]
                let b = cards[j]
                let nameSim = similarity(a.fullName, b.fullName)
                let companyA = LegalEntityTerms.stripKanji(from: a.company ?? "")
                let companyB = LegalEntityTerms.stripKanji(from: b.company ?? "")
                let companySim = similarity(companyA, companyB)
                let score = nameSim * 0.7 + companySim * 0.3
                // 閾値未満だがボーダーライン
                if score >= lowerBound && score < threshold {
                    borderlinePairs.append(DuplicatePair(cardA: a, cardB: b, score: score))
                }
            }
        }

        guard !borderlinePairs.isEmpty else { return pairs }

        let llm = LocalLLMService.shared
        guard let models = llm.ensureModelLoaded() else { return pairs }

        // 最大10ペアまでAI検証（レイテンシ対策）
        for pair in borderlinePairs.prefix(10) {
            let isMatch = await verifyDuplicateWithAI(
                card1: pair.cardA,
                card2: pair.cardB,
                prefill: models.prefill,
                tokenizer: models.tokenizer
            )
            if isMatch {
                var aiPair = pair
                aiPair.isAIDetected = true
                pairs.append(aiPair)
            }
        }

        return pairs.sorted { $0.score > $1.score }
    }

    /// 1ペアをAIで同一人物判定
    private func verifyDuplicateWithAI(card1: BusinessCard, card2: BusinessCard,
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

        // dp[i][j] = a[0..<i] と b[0..<j] の編集距離
        var dp = Array(repeating: Array(repeating: 0, count: n + 1), count: m + 1)

        for i in 0...m { dp[i][0] = i }
        for j in 0...n { dp[0][j] = j }

        for i in 1...m {
            for j in 1...n {
                if a[i - 1] == b[j - 1] {
                    dp[i][j] = dp[i - 1][j - 1]
                } else {
                    dp[i][j] = 1 + min(dp[i - 1][j],      // 削除
                                       dp[i][j - 1],       // 挿入
                                       dp[i - 1][j - 1])   // 置換
                }
            }
        }
        return dp[m][n]
    }
}

// MARK: - 重複ペアモデル

struct DuplicatePair: Identifiable {
    let id = UUID()
    let cardA: BusinessCard
    let cardB: BusinessCard
    /// 類似スコア（0.0〜1.0）
    let score: Double
    /// AI検証で検出されたペアかどうか
    var isAIDetected: Bool = false

    /// スコアをパーセント文字列で返す
    var scoreText: String {
        "\(Int(score * 100))%"
    }
}
