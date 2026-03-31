import Foundation
import NaturalLanguage

// フィールド種別の判定（会社名・部署・役職・住所・建物名）
enum FieldDetector {

    // MARK: - キーワード定数

    static let companyKeywords = LegalEntityTerms.allDetectionTerms

    /// 会社名に使われる接尾辞（名前スコアリングの誤判定防止用）
    static let companySuffixes = [
        "商事", "商会", "物産", "工業", "建設", "製作所", "製薬",
        "電気", "電子", "通信", "不動産", "保険", "証券", "銀行",
        "産業", "興業", "機械", "食品", "化学", "出版", "運輸", "印刷"
    ]

    /// 建物名に使われるサフィックス
    static let buildingSuffixes = [
        "タワー", "ビル", "ビルディング", "プラザ", "ハイツ", "マンション",
        "パレス", "コート", "レジデンス", "ガーデン", "パーク", "ヒルズ",
        "スクエア", "アーク", "フォレスト", "テラス", "ゲート", "アネックス",
        "センター", "モール", "アリーナ", "ドーム", "ホール",
        "Tower", "Building", "Plaza", "Heights", "Hills", "Square", "Park",
        "Garden", "Terrace", "Gate", "Court", "Palace", "Residence"
    ]

    static let departmentSuffixes = [
        "部", "課", "室", "係", "局", "本部", "センター", "グループ", "チーム",
        "ユニット", "ディビジョン", "セクション", "事業部", "事業所",
        "Department", "Division", "Section", "Group", "Team",
        "Office", "Bureau", "Unit", "Center", "Centre"
    ]

    static let jobTitleKeywords = [
        "代表取締役", "取締役", "執行役員", "社長", "副社長", "会長", "副会長",
        "本部長", "部長", "副部長", "課長", "係長", "主任", "リーダー",
        "マネージャー", "シニアマネージャー", "ゼネラルマネージャー",
        "ディレクター", "プロデューサー", "エンジニア", "デザイナー",
        "コンサルタント", "アナリスト", "スペシャリスト",
        "President", "CEO", "CTO", "CFO", "COO", "CMO", "CIO",
        "Director", "Manager", "Senior", "Lead", "Principal",
        "Engineer", "Designer", "Consultant", "Analyst", "Specialist",
        "Executive", "Officer", "Head of", "VP ", "Vice President"
    ]

    // MARK: - 判定メソッド

    static func isCompany(_ text: String) -> Bool {
        companyKeywords.contains { text.contains($0) }
    }

    static func isDepartment(_ text: String) -> Bool {
        guard !isCompany(text), !isJobTitle(text) else { return false }
        return departmentSuffixes.contains { text.hasSuffix($0) || text.contains($0) }
    }

    static func isJobTitle(_ text: String) -> Bool {
        guard text.count >= 3 else { return false }
        return jobTitleKeywords.contains { text.contains($0) }
    }

    /// 建物名の判定：建物サフィックスを含み、短すぎず長すぎない行
    static func isBuildingName(_ text: String) -> Bool {
        let stripped = text
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "　", with: "")
        guard (3...30).contains(stripped.count) else { return false }
        return buildingSuffixes.contains { text.contains($0) }
    }

    static func isAddress(_ text: String) -> Bool {
        if ContactPatternExtractor.matches(pattern: #"〒\s*\d{3}[-−]\d{4}"#, in: text) { return true }
        let prefPattern = #"(東京都|大阪府|京都府|北海道|沖縄県|[^\x00-\x7F]{2,3}[都道府県])"#
        if ContactPatternExtractor.matches(pattern: prefPattern, in: text) { return true }
        if ContactPatternExtractor.matches(pattern: #"[^\x00-\x7F]+[市区町村][^\x00-\x7F]*[丁目番地号]"#, in: text) { return true }
        return false
    }

    // MARK: - NLTagger ヘルパー

    /// NLTagger を用いた PersonalName 判定（英語など8言語のみ対応）
    static func nlTaggerDetectsPersonalName(in text: String) -> Bool {
        guard text.count >= 2 else { return false }

        let tagger = NLTagger(tagSchemes: [.nameType])
        tagger.string = text
        var found = false
        tagger.enumerateTags(
            in: text.startIndex ..< text.endIndex,
            unit: .word,
            scheme: .nameType,
            options: [.omitWhitespace, .omitPunctuation]
        ) { tag, _ in
            if tag == .personalName { found = true }
            return !found
        }
        return found
    }
}
