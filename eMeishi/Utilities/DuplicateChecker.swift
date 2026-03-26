import Foundation

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
        let companySim = similarity(a.company ?? "", b.company ?? "")

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

    /// スコアをパーセント文字列で返す
    var scoreText: String {
        "\(Int(score * 100))%"
    }
}
