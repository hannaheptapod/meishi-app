import Foundation

// Foundation Models が利用不可の場合に使う正規表現ベースのフィールド分類器
// 2パス方式：
//   パス1 - 構造化フィールド（メール・電話・URL・住所・会社・役職）をキーワードで抽出
//   パス2 - 未分類の残り行から氏名を推定
struct CardFieldClassifier {

    struct ParsedCard {
        var lastName: String = ""
        var firstName: String = ""
        var company: String = ""
        var title: String = ""
        var phones: [String] = []
        var email: String = ""
        var address: String = ""
        var website: String = ""
    }

    func classify(lines: [String]) -> ParsedCard {
        var result = ParsedCard()
        var unclassified: [String] = []

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }

            // --- パス1：パターン・キーワードで確実に判定できるフィールドを先に抽出 ---

            if result.email.isEmpty, let email = extractEmail(from: trimmed) {
                result.email = email
            } else if let phone = extractPhone(from: trimmed) {
                result.phones.append(phone)
            } else if result.website.isEmpty, let url = extractURL(from: trimmed) {
                result.website = url
            } else if result.address.isEmpty, isAddress(trimmed) {
                result.address = trimmed
            } else if result.company.isEmpty, isCompany(trimmed) {
                // 会社名キーワード（株式会社・Inc. 等）を含む行
                result.company = normalizeCompany(trimmed)
            } else if result.title.isEmpty, isJobTitle(trimmed) {
                // 役職キーワード（部長・Director 等）を含む行
                result.title = trimmed
            } else {
                unclassified.append(trimmed)
            }
        }

        // --- パス2：未分類の行から氏名を推定し、姓と名に分割 ---
        // 日本語名らしい行（漢字・仮名を含み短い）を優先、なければ先頭行
        let rawName: String
        if let nameIndex = unclassified.indices.first(where: { isLikelyPersonName(unclassified[$0]) }) {
            rawName = unclassified.remove(at: nameIndex)
        } else if let first = unclassified.first {
            rawName = first
            unclassified.removeFirst()
        } else {
            rawName = ""
        }
        let (last, first) = splitName(rawName)
        result.lastName  = last
        result.firstName = first

        // まだ会社名が未設定なら残り行から補完
        if result.company.isEmpty, let companyLine = unclassified.first {
            result.company = companyLine
            unclassified.removeFirst()
        }

        // 役職も未設定なら残り行から補完
        if result.title.isEmpty, let titleLine = unclassified.first {
            result.title = titleLine
        }

        return result
    }

    // MARK: - 会社名判定

    private func isCompany(_ text: String) -> Bool {
        let keywords = [
            "株式会社", "合同会社", "有限会社", "一般社団法人", "公益社団法人",
            "公益財団法人", "一般財団法人", "特定非営利活動法人",
            "Inc.", "Inc,", "LLC", "Ltd.", "Ltd,", "Corp.", "Corp,",
            "Co., Ltd", "Co.,Ltd", "GmbH", "S.A.", "Pty"
        ]
        return keywords.contains { text.contains($0) }
    }

    // 株式会社が後置の場合も先頭に統一（任意）
    private func normalizeCompany(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespaces)
    }

    // MARK: - 役職判定

    private func isJobTitle(_ text: String) -> Bool {
        let keywords = [
            // 日本語役職
            "代表取締役", "取締役", "執行役員", "社長", "副社長", "会長", "副会長",
            "本部長", "部長", "副部長", "課長", "係長", "主任", "リーダー",
            "マネージャー", "シニアマネージャー", "ゼネラルマネージャー",
            "ディレクター", "プロデューサー", "エンジニア", "デザイナー",
            "コンサルタント", "アナリスト", "スペシャリスト",
            // 英語役職
            "President", "CEO", "CTO", "CFO", "COO", "CMO", "CIO",
            "Director", "Manager", "Senior", "Lead", "Principal",
            "Engineer", "Designer", "Consultant", "Analyst", "Specialist",
            "Executive", "Officer", "Head of", "VP ", "Vice President"
        ]
        // 行が短すぎる場合は役職でなく氏名の可能性が高いため除外
        guard text.count >= 3 else { return false }
        return keywords.contains { text.contains($0) }
    }

    // MARK: - 氏名分割

    /// スペース（全角・半角）で姓と名に分割する
    /// スペースなしの場合は全体を姓として扱う
    private func splitName(_ text: String) -> (lastName: String, firstName: String) {
        guard !text.isEmpty else { return ("", "") }

        // 全角スペース・半角スペースどちらでも分割
        let separators = CharacterSet(charactersIn: " \u{3000}")
        let parts = text.components(separatedBy: separators)
                        .map { $0.trimmingCharacters(in: .whitespaces) }
                        .filter { !$0.isEmpty }

        switch parts.count {
        case 0:           return ("", "")
        case 1:           return (parts[0], "")          // スペースなし → 全部を姓
        default:          return (parts[0], parts[1...].joined(separator: " "))
        }
    }

    // MARK: - 氏名らしさ判定

    private func isLikelyPersonName(_ text: String) -> Bool {
        // 日本語（漢字・ひらがな・カタカナ）を含み、かつ適切な長さ
        let hasJapanese = text.unicodeScalars.contains {
            // ひらがな・カタカナ・CJK統合漢字
            (0x3040...0x30FF).contains($0.value) || (0x4E00...0x9FFF).contains($0.value)
        }
        // 2〜8文字（スペース含む）かつ日本語を含む行を氏名候補とする
        let charCount = text.replacingOccurrences(of: " ", with: "")
                            .replacingOccurrences(of: "　", with: "").count
        return hasJapanese && charCount >= 2 && charCount <= 10
    }

    // MARK: - 住所判定

    private func isAddress(_ text: String) -> Bool {
        // 郵便番号
        if matches(pattern: #"〒\s*\d{3}[-−]\d{4}"#, in: text) { return true }
        // 都道府県
        let prefPattern = #"(東京都|大阪府|京都府|北海道|沖縄県|[^\x00-\x7F]{2,3}[都道府県])"#
        if matches(pattern: prefPattern, in: text) { return true }
        // 市区町村＋丁目・番地
        if matches(pattern: #"[^\x00-\x7F]+[市区町村][^\x00-\x7F]*[丁目番地号]"#, in: text) { return true }
        return false
    }

    // MARK: - 正規表現抽出

    private func extractEmail(from text: String) -> String? {
        firstMatch(pattern: #"[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}"#, in: text)
    }

    private func extractPhone(from text: String) -> String? {
        // 国内・国際・携帯番号に対応
        firstMatch(pattern: #"(?:\+?81[-\s]?|0)\d{1,4}[-\s]?\d{1,4}[-\s]?\d{4}"#, in: text)
    }

    private func extractURL(from text: String) -> String? {
        if let url = firstMatch(pattern: #"https?://[^\s]+"#, in: text) { return url }
        return firstMatch(pattern: #"www\.[^\s]+"#, in: text)
    }

    private func firstMatch(pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              let swiftRange = Range(match.range, in: text) else { return nil }
        return String(text[swiftRange])
    }

    private func matches(pattern: String, in text: String) -> Bool {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return false }
        let range = NSRange(text.startIndex..., in: text)
        return regex.firstMatch(in: text, range: range) != nil
    }
}
