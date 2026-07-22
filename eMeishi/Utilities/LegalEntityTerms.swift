import Foundation

// 法人格（会社格）の一元管理。検出・除去・正規化で共通利用する。
// CardFieldClassifier（検出）・BusinessCard（ソートキー・読み除去）・DuplicateChecker（正規化比較）で参照。
nonisolated enum LegalEntityTerms {

    // MARK: - 日本語法人格（漢字）

    static let kanjiTerms: [String] = [
        "株式会社", "合同会社", "有限会社", "合名会社", "合資会社",
        "一般社団法人", "公益社団法人", "一般財団法人", "公益財団法人",
        "医療法人", "学校法人", "社会福祉法人", "弁護士法人", "税理士法人",
        "独立行政法人", "特定非営利活動法人",
    ]

    // MARK: - 日本語法人格（ひらがな読み）

    static let readingTerms: [String] = [
        // 連濁あり（正式な読み）と連濁なし（CFStringTokenizer 出力）の両方を含む
        "かぶしきがいしゃ", "かぶしきかいしゃ",
        "ごうどうがいしゃ", "ごうどうかいしゃ",
        "ゆうげんがいしゃ", "ゆうげんかいしゃ",
        "ごうめいがいしゃ", "ごうめいかいしゃ",
        "ごうしがいしゃ", "ごうしかいしゃ",
        "いっぱんしゃだんほうじん", "こうえきしゃだんほうじん",
        "いっぱんざいだんほうじん", "こうえきざいだんほうじん",
        "いりょうほうじん", "がっこうほうじん", "しゃかいふくしほうじん",
        "べんごしほうじん", "ぜいりしほうじん", "どくりつぎょうせいほうじん",
        "とくていひえいりかつどうほうじん",
    ]

    // MARK: - 英語法人格

    static let englishTerms: [String] = [
        "Co., Ltd.", "Co., Ltd", "Co.,Ltd.", "Co.,Ltd",
        "Inc.", "Inc,", "LLC", "Ltd.", "Ltd,",
        "Corp.", "Corp,", "GmbH", "S.A.", "Pty",
    ]

    // MARK: - 略称形（括弧付き）

    static let abbreviatedTerms: [String] = [
        "(株)", "（株）", "(有)", "（有）", "(同)", "（同）",
        "(合)", "（合）", "(医)", "（医）", "(学)", "（学）",
        "(社)", "（社）", "(財)", "（財）",
    ]

    // MARK: - 検出用（全種統合）

    /// CardFieldClassifier の会社名検出で使用
    static let allDetectionTerms: [String] = kanjiTerms + englishTerms + abbreviatedTerms

    // MARK: - 除去

    /// 漢字・英語・略称の法人格を前方・後方から除去する（ソート・重複比較用）
    static func stripKanji(from text: String) -> String {
        let allTerms = kanjiTerms + englishTerms + abbreviatedTerms
        var s = text
        for t in allTerms {
            if s.hasPrefix(t) { s = String(s.dropFirst(t.count)); break }
            if s.hasSuffix(t) { s = String(s.dropLast(t.count)); break }
        }
        return s.trimmingCharacters(in: .whitespaces)
    }

    /// ひらがな読みの法人格を前方・後方から除去する（companyReading 生成用）
    static func stripReading(from text: String) -> String {
        var s = text
        for t in readingTerms {
            if s.hasPrefix(t) { s = String(s.dropFirst(t.count)); break }
            if s.hasSuffix(t) { s = String(s.dropLast(t.count)); break }
        }
        return s.trimmingCharacters(in: .whitespaces)
    }
}
