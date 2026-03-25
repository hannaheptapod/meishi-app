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
                // 会社名キーワード（株式会社・Inc. 等）を含む行
                result.company = normalizeCompany(trimmed)
            } else if isDepartment(trimmed) {
                // 部署名（営業部・zzz課 等）— 複数行を連結して保持する
                result.department = result.department.isEmpty
                    ? trimmed
                    : result.department + " " + trimmed
            } else if result.title.isEmpty, isJobTitle(trimmed) {
                // 役職キーワード（部長・Director 等）を含む行
                result.title = trimmed
            } else {
                unclassified.append(line)
            }
        }

        // --- パス2：未分類の行から氏名を推定し、姓と名に分割 ---

        // スコアを事前計算（1行につき1回のみ）して最大スコアの行を氏名候補とする
        let scores = unclassified.map { personNameScore(for: $0, candidates: unclassified) }
        let rawName: String
        if let nameIndex = scores.indices.max(by: { scores[$0] < scores[$1] }),
           scores[nameIndex] > 0.2 {

            let selectedLine = unclassified[nameIndex]
            let nameMidY = selectedLine.boundingBox.midY

            // 等間隔文字でOCRが行を分断した場合の補正：
            // 氏名行と Y 座標が近い（同一行とみなせる）短い漢字行を断片として収集する
            // Vision 座標系（原点左下）の midY が 0.08 以内 = 同一水平行の目安
            let fragmentIndices = unclassified.indices.filter { i -> Bool in
                guard i != nameIndex else { return false }
                let line = unclassified[i]
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
            var allParts = [selectedLine] + fragmentIndices.map { unclassified[$0] }
            allParts.sort { $0.boundingBox.midX < $1.boundingBox.midX }
            rawName = allParts
                .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
                .joined()

            // 使用した行（名前行＋断片）をすべて削除
            let indicesToRemove = Set([nameIndex] + fragmentIndices)
            unclassified = unclassified.indices
                .filter { !indicesToRemove.contains($0) }
                .map { unclassified[$0] }

        } else if let first = unclassified.first {
            rawName = first.text.trimmingCharacters(in: .whitespacesAndNewlines)
            unclassified.removeFirst()
        } else {
            rawName = ""
        }
        let (last, first) = splitName(rawName)
        result.lastName  = last
        result.firstName = first

        // フリガナ行（ひらがな/カタカナのみの短い行）を除去
        // → 会社名・役職の補完に誤って使われないようにする
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

    // MARK: - 部署判定

    private func isDepartment(_ text: String) -> Bool {
        // 行が会社名キーワードを含む場合は部署ではなく会社名として優先
        guard !isCompany(text) else { return false }
        // 行が役職キーワードを含む場合は役職として優先
        guard !isJobTitle(text) else { return false }

        let suffixes = [
            // 日本語部署サフィックス
            "部", "課", "室", "係", "局", "本部", "センター", "グループ", "チーム",
            "ユニット", "ディビジョン", "セクション", "事業部", "事業所",
            // 英語部署サフィックス
            "Department", "Division", "Section", "Group", "Team",
            "Office", "Bureau", "Unit", "Center", "Centre"
        ]
        // サフィックスで終わる、またはサフィックスを含む行を部署と判定
        return suffixes.contains { text.hasSuffix($0) || text.contains($0) }
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

    /// 姓と名に分割する
    /// 優先順位: スペース分割 → CFStringTokenizer（MeCab）→ 全体を姓とするフォールバック
    private func splitName(_ text: String) -> (lastName: String, firstName: String) {
        guard !text.isEmpty else { return ("", "") }

        // 1. 全角スペース・半角スペースで分割できる場合はそれを使う
        let separators = CharacterSet(charactersIn: " \u{3000}")
        let parts = text.components(separatedBy: separators)
                        .map { $0.trimmingCharacters(in: .whitespaces) }
                        .filter { !$0.isEmpty }
        if parts.count >= 2 {
            // 全パーツが1〜2文字の場合は「等間隔文字レイアウト」の可能性がある
            // （名刺の「田　中　太　郎」をOCRが「田 中 太 郎」と読んだケース）
            // → 一度結合して CFStringTokenizer で正しい姓名境界を検出する
            if parts.allSatisfy({ $0.count <= 2 }) {
                let joined = parts.joined()
                if let (last, first) = cfTokenizerSplit(joined), !first.isEmpty {
                    return (last, first)
                }
            }
            return (parts[0], parts[1...].joined())
        }

        // 2. スペースなし → CFStringTokenizer（内部で MeCab を使用）で形態素分割を試みる
        //    MeCab の辞書に登録された苗字・名前は正しい境界で分割される
        if let (last, first) = cfTokenizerSplit(text), !first.isEmpty {
            return (last, first)
        }

        // 3. フォールバック：全体を姓として扱う
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
    /// candidates: パス2で未分類として残っている全行（フリガナ検出に使用）
    private func personNameScore(for line: RecognizedLine, candidates: [RecognizedLine]) -> Double {
        let text = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return 0 }

        // フリガナ行（ひらがな/カタカナのみ）は氏名として選ばない
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

        // --- 条件1: 近くにフリガナ行がある（最強シグナル +0.5）---
        // ひらがな/カタカナのみの短い行が Y 座標で近い = 氏名のフリガナである可能性が高い
        // boundingBox は Vision 座標系（原点左下）。midY で縦方向の近さを判定する。
        let myMidY = line.boundingBox.midY
        let hasFurigana = candidates.contains { other in
            guard other.boundingBox != line.boundingBox else { return false }
            return isFuriganaLine(other)
                && abs(other.boundingBox.midY - myMidY) < 0.15
        }
        if hasFurigana { score += 0.5 }

        // --- 条件2: 漢字を含む適切な長さの行（+0.3）---
        // 日本語の氏名は通常 2〜8 文字（スペース除く）
        if hasKanji && (2...8).contains(charCount) { score += 0.3 }

        // --- 条件3a: CFStringTokenizer が姓名の2トークンに分割する（+0.25）---
        // MeCab の辞書に登録されている苗字・名前ならここで確実に分割される
        // 短い行に限定することで住所などの長いテキストの誤検知を防ぐ
        if hasKanji && (3...8).contains(charCount),
           let (_, first) = cfTokenizerSplit(text), !first.isEmpty {
            score += 0.25
        }

        // --- 条件3b: NLTagger による PersonalName 判定（+0.2）---
        // NLTagger の .nameType は日本語未対応（英語など8言語のみ）のため、
        // 日本語を含まないテキスト（外国人名など）にのみ適用する
        if !hasJapanese && nlTaggerDetectsPersonalName(in: text) { score += 0.2 }

        // --- 条件4: 名刺の上半分かつ中央寄りに位置する（+0.1）---
        // boundingBox は Vision 座標系（原点左下）。
        // minY が視覚的な「行の下端」にあたるため、minY > 0.4 が名刺の上半分を示す。
        // midX が 0.2〜0.8 の範囲を「中央寄り」と判定する。
        if line.boundingBox.minY > 0.4 && (0.2...0.8).contains(line.boundingBox.midX) {
            score += 0.1
        }

        // --- 条件5: フォントサイズの代理指標（+0.15）---
        // 氏名は通常最大フォントで印刷される。boundingBox の高さが大きい行を優先する。
        // Vision 座標系では高さも 0.0〜1.0 の正規化値。0.06 以上を「大きいテキスト」と判定。
        if line.boundingBox.height > 0.06 { score += 0.15 }

        // 日本語を含まない短い行（英語名など）も対象に含める
        if !hasJapanese && (2...20).contains(charCount) { score += 0.1 }

        return min(score, 1.0)
    }

    /// フリガナ行の判定：ひらがな・カタカナのみで構成される短い行
    private func isFuriganaLine(_ line: RecognizedLine) -> Bool {
        let text = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let stripped = text
            .replacingOccurrences(of: " ",  with: "")
            .replacingOccurrences(of: "　", with: "")
        guard (3...15).contains(stripped.count) else { return false }

        // 漢字を含む場合はフリガナではない
        let hasKanji = text.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) }
        guard !hasKanji else { return false }

        // 全文字がひらがな・カタカナ・スペースで構成されているか
        return text.unicodeScalars.allSatisfy { s in
            (0x3040...0x30FF).contains(s.value)  // ひらがな + カタカナ
                || s.value == 0x20               // 半角スペース
                || s.value == 0x3000             // 全角スペース
        }
    }

    /// NLTagger を用いた PersonalName 判定
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
            return !found  // found になったら列挙を打ち切る
        }
        return found
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
