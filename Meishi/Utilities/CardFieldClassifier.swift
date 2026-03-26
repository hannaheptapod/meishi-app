import Foundation
import CoreGraphics
import NaturalLanguage

// Foundation Models が利用不可の場合に使う正規表現ベースのフィールド分類器
// 2パス方式：
//   パス1 - 構造化フィールド（メール・電話・URL・住所・会社・役職）をキーワードで抽出
//   パス2 - 未分類の残り行から氏名を推定
struct CardFieldClassifier {

    struct ParsedCard {
        var lastName: String = ""
        var firstName: String = ""
        var company: String = ""
        var department: String = ""
        var title: String = ""
        var phones: [String] = []
        var email: String = ""
        var address: String = ""
        var website: String = ""
    }

    // MARK: - キーワード定数

    private static let companyKeywords = [
        "株式会社", "合同会社", "有限会社", "一般社団法人", "公益社団法人",
        "公益財団法人", "一般財団法人", "特定非営利活動法人",
        "Inc.", "Inc,", "LLC", "Ltd.", "Ltd,", "Corp.", "Corp,",
        "Co., Ltd", "Co.,Ltd", "GmbH", "S.A.", "Pty"
    ]

    private static let departmentSuffixes = [
        // 日本語部署サフィックス
        "部", "課", "室", "係", "局", "本部", "センター", "グループ", "チーム",
        "ユニット", "ディビジョン", "セクション", "事業部", "事業所",
        // 英語部署サフィックス
        "Department", "Division", "Section", "Group", "Team",
        "Office", "Bureau", "Unit", "Center", "Centre"
    ]

    private static let jobTitleKeywords = [
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

    // MARK: - ルールベース前段処理（ハイブリッド方式用）

    /// Pass1のみ実行: 正規表現で確実に分類できるフィールド（email, phone, URL, 住所, 会社, 部署, 役職）を抽出し、
    /// 未分類行のテキスト配列とともに返す。LLMは未分類行から名前等を判定する。
    struct StructuredFieldsResult {
        var parsed: ParsedCard
        var unclassifiedLines: [String]
    }

    func classifyStructuredFields(lines: [String]) -> StructuredFieldsResult {
        var result = ParsedCard()
        var unclassified: [String] = []

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }

            if result.email.isEmpty, let email = extractEmail(from: trimmed) {
                result.email = email
            } else if let phone = extractPhone(from: trimmed) {
                result.phones.append(phone)
            } else if result.website.isEmpty, let url = extractURL(from: trimmed) {
                result.website = url
            } else if result.address.isEmpty, isAddress(trimmed) {
                result.address = trimmed
            } else if result.company.isEmpty, isCompany(trimmed) {
                result.company = trimmed.trimmingCharacters(in: .whitespaces)
            } else if isDepartment(trimmed) {
                result.department = result.department.isEmpty
                    ? trimmed
                    : result.department + " " + trimmed
            } else if result.title.isEmpty, isJobTitle(trimmed) {
                result.title = trimmed
            } else {
                unclassified.append(trimmed)
            }
        }

        return StructuredFieldsResult(parsed: result, unclassifiedLines: unclassified)
    }

    // MARK: - 分類エントリポイント（従来API: 全フィールド分類）

    func classify(lines: [RecognizedLine]) -> ParsedCard {
        var result = ParsedCard()
        var unclassified: [RecognizedLine] = []

        for line in lines {
            let trimmed = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
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
                result.company = trimmed.trimmingCharacters(in: .whitespaces)
            } else if isDepartment(trimmed) {
                result.department = result.department.isEmpty
                    ? trimmed
                    : result.department + " " + trimmed
            } else if result.title.isEmpty, isJobTitle(trimmed) {
                result.title = trimmed
            } else {
                unclassified.append(line)
            }
        }

        // --- パス2：未分類の行から氏名を推定し、姓と名に分割 ---
        unclassified = resolveNameFromUnclassified(&result, unclassified: unclassified)

        // フリガナ行（ひらがな/カタカナのみの短い行）を除去
        unclassified.removeAll { isFuriganaLine($0) }

        // まだ会社名が未設定なら残り行から補完
        if result.company.isEmpty, let companyLine = unclassified.first {
            result.company = companyLine.text.trimmingCharacters(in: .whitespacesAndNewlines)
            unclassified.removeFirst()
        }

        // 役職も未設定なら残り行から補完
        if result.title.isEmpty, let titleLine = unclassified.first {
            result.title = titleLine.text.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return result
    }

    // MARK: - パス2: 氏名解決

    /// 未分類行から氏名候補を選び、ParsedCard に反映する。残った未分類行を返す。
    private func resolveNameFromUnclassified(_ result: inout ParsedCard,
                                             unclassified: [RecognizedLine]) -> [RecognizedLine] {
        var remaining = unclassified
        let scores = remaining.map { personNameScore(for: $0, candidates: remaining) }

        let rawName: String
        if let nameIndex = scores.indices.max(by: { scores[$0] < scores[$1] }),
           scores[nameIndex] > 0.2 {

            let selectedLine = remaining[nameIndex]
            let nameMidY = selectedLine.boundingBox.midY

            // 等間隔文字でOCRが行を分断した場合の補正：
            // Y座標が近い（同一行とみなせる）短い漢字行を断片として収集する
            let fragmentIndices = remaining.indices.filter { i -> Bool in
                guard i != nameIndex else { return false }
                let line = remaining[i]
                let t = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
                let stripped = t
                    .replacingOccurrences(of: " ",  with: "")
                    .replacingOccurrences(of: "　", with: "")
                let hasKanji = t.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) }
                return hasKanji
                    && stripped.count <= 3
                    && abs(line.boundingBox.midY - nameMidY) < 0.08
            }

            // 選択行＋断片を X 座標順（左→右）に並べて結合
            var allParts = [selectedLine] + fragmentIndices.map { remaining[$0] }
            allParts.sort { $0.boundingBox.midX < $1.boundingBox.midX }
            rawName = allParts
                .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
                .joined()

            let indicesToRemove = Set([nameIndex] + fragmentIndices)
            remaining = remaining.indices
                .filter { !indicesToRemove.contains($0) }
                .map { remaining[$0] }

        } else if let first = remaining.first {
            rawName = first.text.trimmingCharacters(in: .whitespacesAndNewlines)
            remaining.removeFirst()
        } else {
            rawName = ""
        }

        let (last, first) = splitName(rawName)
        result.lastName  = last
        result.firstName = first
        return remaining
    }

    // MARK: - フィールド判定

    private func isCompany(_ text: String) -> Bool {
        Self.companyKeywords.contains { text.contains($0) }
    }

    private func isDepartment(_ text: String) -> Bool {
        guard !isCompany(text), !isJobTitle(text) else { return false }
        return Self.departmentSuffixes.contains { text.hasSuffix($0) || text.contains($0) }
    }

    private func isJobTitle(_ text: String) -> Bool {
        guard text.count >= 3 else { return false }
        return Self.jobTitleKeywords.contains { text.contains($0) }
    }

    private func isAddress(_ text: String) -> Bool {
        if matches(pattern: #"〒\s*\d{3}[-−]\d{4}"#, in: text) { return true }
        let prefPattern = #"(東京都|大阪府|京都府|北海道|沖縄県|[^\x00-\x7F]{2,3}[都道府県])"#
        if matches(pattern: prefPattern, in: text) { return true }
        if matches(pattern: #"[^\x00-\x7F]+[市区町村][^\x00-\x7F]*[丁目番地号]"#, in: text) { return true }
        return false
    }

    // MARK: - 正規表現抽出

    private func extractEmail(from text: String) -> String? {
        firstMatch(pattern: #"[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}"#, in: text)
    }

    private func extractPhone(from text: String) -> String? {
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

    // MARK: - 氏名分割

    /// 姓と名に分割する
    /// 優先順位: スペース分割 → CFStringTokenizer（MeCab）→ 全体を姓とするフォールバック
    private func splitName(_ text: String) -> (lastName: String, firstName: String) {
        guard !text.isEmpty else { return ("", "") }

        let separators = CharacterSet(charactersIn: " \u{3000}")
        let parts = text.components(separatedBy: separators)
                        .map { $0.trimmingCharacters(in: .whitespaces) }
                        .filter { !$0.isEmpty }
        if parts.count >= 2 {
            // 全パーツが1〜2文字の場合は等間隔文字レイアウトの可能性があるため
            // 一度結合して CFStringTokenizer で正しい姓名境界を検出する
            if parts.allSatisfy({ $0.count <= 2 }) {
                if let (last, first) = cfTokenizerSplit(parts.joined()), !first.isEmpty {
                    return (last, first)
                }
            }
            return (parts[0], parts[1...].joined())
        }

        if let (last, first) = cfTokenizerSplit(text), !first.isEmpty {
            return (last, first)
        }

        return (text, "")
    }

    /// CFStringTokenizer（MeCab ベース）で日本語テキストを形態素分割し、
    /// 最初のトークンを姓、残りを名として返す。2トークン未満の場合は nil。
    private func cfTokenizerSplit(_ text: String) -> (String, String)? {
        let locale = Locale(identifier: "ja_JP") as CFLocale
        guard let tokenizer = CFStringTokenizerCreate(
            kCFAllocatorDefault,
            text as CFString,
            CFRangeMake(0, (text as NSString).length),
            kCFStringTokenizerUnitWord,
            locale
        ) else { return nil }

        var tokens: [String] = []
        while CFStringTokenizerAdvanceToNextToken(tokenizer).rawValue != 0 {
            let cfRange = CFStringTokenizerGetCurrentTokenRange(tokenizer)
            let nsRange = NSRange(location: cfRange.location, length: cfRange.length)
            guard let swiftRange = Range(nsRange, in: text) else { continue }
            tokens.append(String(text[swiftRange]))
        }

        guard tokens.count >= 2 else { return nil }
        return (tokens[0], tokens[1...].joined())
    }

    // MARK: - 人名スコアリング

    /// 行が人名である可能性を 0.0〜1.0 で返す
    private func personNameScore(for line: RecognizedLine, candidates: [RecognizedLine]) -> Double {
        let text = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return 0 }

        if isFuriganaLine(line) { return 0 }

        let stripped = text
            .replacingOccurrences(of: " ",  with: "")
            .replacingOccurrences(of: "　", with: "")
        let charCount = stripped.count

        let hasKanji    = text.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) }
        let hasJapanese = hasKanji || text.unicodeScalars.contains {
            (0x3040...0x30FF).contains($0.value)
        }

        var score = 0.0

        // 条件1: 近くにフリガナ行がある（最強シグナル +0.5）
        let myMidY = line.boundingBox.midY
        let hasFurigana = candidates.contains { other in
            guard other.boundingBox != line.boundingBox else { return false }
            return isFuriganaLine(other)
                && abs(other.boundingBox.midY - myMidY) < 0.15
        }
        if hasFurigana { score += 0.5 }

        // 条件2: 漢字を含む適切な長さの行（+0.3）
        if hasKanji && (2...8).contains(charCount) { score += 0.3 }

        // 条件3a: CFStringTokenizer が姓名の2トークンに分割する（+0.25）
        if hasKanji && (3...8).contains(charCount),
           let (_, first) = cfTokenizerSplit(text), !first.isEmpty {
            score += 0.25
        }

        // 条件3b: NLTagger による PersonalName 判定（+0.2）— 日本語非対応のため日本語以外に適用
        if !hasJapanese && nlTaggerDetectsPersonalName(in: text) { score += 0.2 }

        // 条件4: 名刺の上半分かつ中央寄りに位置する（+0.1）
        if line.boundingBox.minY > 0.4 && (0.2...0.8).contains(line.boundingBox.midX) {
            score += 0.1
        }

        // 条件5: フォントサイズの代理指標（+0.15）
        if line.boundingBox.height > 0.06 { score += 0.15 }

        // 日本語を含まない短い行（英語名など）を対象に含める
        if !hasJapanese && (2...20).contains(charCount) { score += 0.1 }

        return min(score, 1.0)
    }

    // MARK: - フリガナ判定

    /// フリガナ行の判定：ひらがな・カタカナのみで構成される短い行
    private func isFuriganaLine(_ line: RecognizedLine) -> Bool {
        let text = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let stripped = text
            .replacingOccurrences(of: " ",  with: "")
            .replacingOccurrences(of: "　", with: "")
        guard (3...15).contains(stripped.count) else { return false }

        let hasKanji = text.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) }
        guard !hasKanji else { return false }

        return text.unicodeScalars.allSatisfy { s in
            (0x3040...0x30FF).contains(s.value)
                || s.value == 0x20
                || s.value == 0x3000
        }
    }

    // MARK: - NLTagger ヘルパー

    /// NLTagger を用いた PersonalName 判定（英語など8言語のみ対応）
    private func nlTaggerDetectsPersonalName(in text: String) -> Bool {
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
