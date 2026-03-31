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
        var lastNameReading: String = ""
        var firstName: String = ""
        var firstNameReading: String = ""
        var company: String = ""
        var companyReading: String = ""
        var department: String = ""
        var title: String = ""
        var phones: [String] = []
        var email: String = ""
        var address: String = ""
        var website: String = ""
    }

    // MARK: - キーワード定数

    private static let companyKeywords = LegalEntityTerms.allDetectionTerms

    /// 会社名に使われる接尾辞（名前スコアリングの誤判定防止用）
    private static let companySuffixes = [
        "商事", "商会", "物産", "工業", "建設", "製作所", "製薬",
        "電気", "電子", "通信", "不動産", "保険", "証券", "銀行",
        "産業", "興業", "機械", "食品", "化学", "出版", "運輸", "印刷"
    ]

    /// 建物名に使われるサフィックス（住所の続きとして検出・名前スコアリングの誤判定防止用）
    private static let buildingSuffixes = [
        "タワー", "ビル", "ビルディング", "プラザ", "ハイツ", "マンション",
        "パレス", "コート", "レジデンス", "ガーデン", "パーク", "ヒルズ",
        "スクエア", "アーク", "フォレスト", "テラス", "ゲート", "アネックス",
        "センター", "モール", "アリーナ", "ドーム", "ホール",
        "Tower", "Building", "Plaza", "Heights", "Hills", "Square", "Park",
        "Garden", "Terrace", "Gate", "Court", "Palace", "Residence"
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

    /// ルールベースで可能な限り分類し、残った未分類行のテキストを返す。
    /// Pass1（正規表現）+ Pass2（空間情報を使った名前スコアリング）まで実行するため、
    /// LLMが担当するのは名前スコアが低く確信が持てなかったケースのみになる。
    struct StructuredFieldsResult {
        var parsed: ParsedCard
        var unclassifiedLines: [String]
    }

    func classifyStructuredFields(lines: [RecognizedLine]) -> StructuredFieldsResult {
        var result = ParsedCard()
        var unclassified: [RecognizedLine] = []

        print("[Classifier] === Pass1 開始 (\(lines.count)行) ===")

        // --- Pass1: パターン・キーワードで確実に判定できるフィールドを抽出 ---
        for line in lines {
            let trimmed = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }

            if result.email.isEmpty, let email = extractEmail(from: trimmed) {
                result.email = email
                print("[Classifier] email: '\(trimmed)'")
            } else if let phone = extractPhone(from: trimmed) {
                result.phones.append(phone)
                print("[Classifier] phone: '\(trimmed)'")
            } else if result.website.isEmpty, let url = extractURL(from: trimmed) {
                result.website = url
                print("[Classifier] website: '\(trimmed)'")
            } else if result.address.isEmpty, isAddress(trimmed) {
                result.address = trimmed
                print("[Classifier] address: '\(trimmed)'")
            } else if isAddress(trimmed) {
                // 2つ目以降の住所行は既に address が埋まっているので連結
                result.address += " " + trimmed
                print("[Classifier] address(追加): '\(trimmed)'")
            } else if result.company.isEmpty, isCompany(trimmed) {
                result.company = trimmed.trimmingCharacters(in: .whitespaces)
                print("[Classifier] company: '\(trimmed)'")
            } else if isDepartment(trimmed) {
                result.department = result.department.isEmpty
                    ? trimmed
                    : result.department + " " + trimmed
                print("[Classifier] department: '\(trimmed)'")
            } else if result.title.isEmpty, isJobTitle(trimmed) {
                result.title = trimmed
                print("[Classifier] title: '\(trimmed)'")
            } else {
                unclassified.append(line)
                print("[Classifier] 未分類: '\(trimmed)'")
            }
        }

        print("[Classifier] Pass1結果: email=\(result.email.isEmpty ? "×" : "○") phone=\(result.phones.count)件 web=\(result.website.isEmpty ? "×" : "○") addr=\(result.address.isEmpty ? "×" : "○") co=\(result.company.isEmpty ? "×" : "○") dept=\(result.department.isEmpty ? "×" : "○") title=\(result.title.isEmpty ? "×" : "○")")

        // --- Pass1.5: 建物名を住所に追加 ---
        if !result.address.isEmpty {
            unclassified.removeAll { line in
                let t = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if isBuildingName(t) {
                    result.address += " " + t
                    print("[Classifier] address(建物名): '\(t)'")
                    return true
                }
                return false
            }
        }

        // --- Pass2: 空間情報を使った名前スコアリング ---
        // スコアが十分高い場合はここで名前を確定し、LLMに委ねない
        if !unclassified.isEmpty {
            let scores = unclassified.map { personNameScore(for: $0, candidates: unclassified) }
            for (idx, line) in unclassified.enumerated() {
                let t = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
                print("[Classifier] Pass2スコア: '\(t)' = \(String(format: "%.3f", scores[idx]))")
            }
            if let bestIdx = scores.indices.max(by: { scores[$0] < scores[$1] }),
               scores[bestIdx] > 0.35 {
                let bestText = unclassified[bestIdx].text.trimmingCharacters(in: .whitespacesAndNewlines)
                print("[Classifier] 名前確定(>0.35): '\(bestText)' (score=\(String(format: "%.3f", scores[bestIdx])))")
                // 高確信度（0.4超）: ルールベースで名前を確定
                unclassified = resolveNameFromUnclassified(&result, unclassified: unclassified)
                print("[Classifier] 名前解決後: lastName='\(result.lastName)' firstName='\(result.firstName)'")
                // フリガナ行を氏名読み仮名として取得してから除去
                if let furiganaLine = unclassified.first(where: { isFuriganaLine($0) }) {
                    let rawReading = furiganaLine.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    let (lastR, firstR) = splitName(rawReading)
                    result.lastNameReading = normalizeToHiragana(lastR)
                    result.firstNameReading = normalizeToHiragana(firstR)
                    print("[Classifier] フリガナ: lastR='\(result.lastNameReading)' firstR='\(result.firstNameReading)'")
                } else if let romajiLine = unclassified.first(where: { isRomajiNameLine($0) }),
                          let romajiReading = resolveRomajiReading(
                              romajiLine: romajiLine,
                              lastName: result.lastName,
                              firstName: result.firstName
                          ) {
                    // フリガナ行がない場合、ローマ字行から読み仮名を推定
                    result.lastNameReading = romajiReading.lastNameReading
                    result.firstNameReading = romajiReading.firstNameReading
                    print("[Classifier] ローマ字読み: lastR='\(result.lastNameReading)' firstR='\(result.firstNameReading)'")
                }
                unclassified.removeAll { isFuriganaLine($0) }
                unclassified.removeAll { isRomajiNameLine($0) }
            } else {
                print("[Classifier] 名前スコア不足 → LLMに委譲")
            }
        }

        // 未分類行からテキストのみ抽出して返す
        let unclassifiedTexts = unclassified.map {
            $0.text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        print("[Classifier] 最終未分類: \(unclassifiedTexts)")
        return StructuredFieldsResult(parsed: result, unclassifiedLines: unclassifiedTexts)
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

        // --- パス1.5：建物名を住所に追加 ---
        if !result.address.isEmpty {
            unclassified.removeAll { line in
                let t = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if isBuildingName(t) {
                    result.address += " " + t
                    return true
                }
                return false
            }
        }

        // --- パス2：未分類の行から氏名を推定し、姓と名に分割 ---
        unclassified = resolveNameFromUnclassified(&result, unclassified: unclassified)

        // フリガナ行（ひらがな/カタカナのみの短い行）を氏名読み仮名として取得してから除去
        if let furiganaLine = unclassified.first(where: { isFuriganaLine($0) }) {
            let rawReading = furiganaLine.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let (lastR, firstR) = splitName(rawReading)
            result.lastNameReading  = normalizeToHiragana(lastR)
            result.firstNameReading = normalizeToHiragana(firstR)
        } else if let romajiLine = unclassified.first(where: { isRomajiNameLine($0) }),
                  let romajiReading = resolveRomajiReading(
                      romajiLine: romajiLine,
                      lastName: result.lastName,
                      firstName: result.firstName
                  ) {
            result.lastNameReading = romajiReading.lastNameReading
            result.firstNameReading = romajiReading.firstNameReading
        }
        unclassified.removeAll { isFuriganaLine($0) }
        unclassified.removeAll { isRomajiNameLine($0) }

        // まだ会社名が未設定なら残り行から補完（条件付き：漢字を含む妥当な長さの行のみ）
        if result.company.isEmpty, let companyLine = unclassified.first {
            let candidate = companyLine.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let candidateStripped = candidate
                .replacingOccurrences(of: " ", with: "")
                .replacingOccurrences(of: "　", with: "")
            let hasCJK = candidate.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) }
            let hasDigit = candidate.unicodeScalars.contains { $0.value >= 0x30 && $0.value <= 0x39 }
            let hasURLFragment = candidate.lowercased().contains("www") || candidate.lowercased().contains("http") || candidate.contains("@")
            let isDistinctFromName = candidate != result.lastName && candidate != (result.lastName + result.firstName)
            if hasCJK && (2...20).contains(candidateStripped.count) && !hasDigit && !hasURLFragment && isDistinctFromName {
                result.company = candidate
                unclassified.removeFirst()
            }
        }

        // 役職フォールバックは削除（誤入力より空フィールドの方がマシ）

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
            // Y座標がほぼ同一（同一行とみなせる）かつX座標が近接する短い漢字行を断片として収集する
            let nameBox = selectedLine.boundingBox
            let nameMinX = nameBox.minX
            let nameMaxX = nameBox.maxX
            let fragmentIndices = remaining.indices.filter { i -> Bool in
                guard i != nameIndex else { return false }
                let line = remaining[i]
                let t = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
                let stripped = t
                    .replacingOccurrences(of: " ",  with: "")
                    .replacingOccurrences(of: "　", with: "")
                let hasKanji = t.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) }
                let box = line.boundingBox
                // Y座標がほぼ同一行（高さの半分以内）
                let sameRow = abs(box.midY - nameMidY) < max(nameBox.height, box.height) * 0.6
                // X座標が名前行の近傍にある（名前行の幅の50%以内の間隔）
                let xGap = nameBox.width * 0.5
                let xNearby = box.minX < nameMaxX + xGap && box.maxX > nameMinX - xGap
                return hasKanji
                    && stripped.count <= 3
                    && sameRow
                    && xNearby
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

    /// 建物名の判定：建物サフィックスを含み、短すぎず長すぎない行
    private func isBuildingName(_ text: String) -> Bool {
        let stripped = text
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "　", with: "")
        guard (3...30).contains(stripped.count) else { return false }
        return Self.buildingSuffixes.contains { text.contains($0) }
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

        if isFuriganaLine(line) || isRomajiNameLine(line) { return 0 }

        let stripped = text
            .replacingOccurrences(of: " ",  with: "")
            .replacingOccurrences(of: "　", with: "")
        let charCount = stripped.count

        let hasKanji    = text.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) }
        let hasJapanese = hasKanji || text.unicodeScalars.contains {
            (0x3040...0x30FF).contains($0.value)
        }

        var score = 0.0

        // --- 否定的シグナル: 名前らしくない行を早期減点 ---

        // 数字を含む行は電話番号・郵便番号の断片（-0.3）
        let hasDigit = text.unicodeScalars.contains { $0.value >= 0x30 && $0.value <= 0x39 }
        if hasDigit { score -= 0.3 }

        // URL・メール断片（-0.3）
        let lower = text.lowercased()
        if lower.contains(".co.") || lower.contains("www") || lower.contains("http") || lower.contains("@") {
            score -= 0.3
        }

        // Pass1 で漏れた部署・役職キーワード（-0.3）
        if Self.departmentSuffixes.contains(where: { text.contains($0) })
            || Self.jobTitleKeywords.contains(where: { text.contains($0) }) {
            score -= 0.3
        }

        // 建物名サフィックスを含む行（-0.5 — 最強の否定シグナル）
        if Self.buildingSuffixes.contains(where: { text.contains($0) }) {
            score -= 0.5
        }

        // カタカナが3文字以上含まれる漢字混合行は地名・建物名の可能性が高い（-0.2）
        let katakanaCount = text.unicodeScalars.filter { (0x30A0...0x30FF).contains($0.value) }.count
        if hasKanji && katakanaCount >= 3 {
            score -= 0.2
        }

        // 条件1: 近くにフリガナ行またはローマ字行がある（最強シグナル +0.5）
        let myMidY = line.boundingBox.midY
        let hasReadingLine = candidates.contains { other in
            guard other.boundingBox != line.boundingBox else { return false }
            return (isFuriganaLine(other) || isRomajiNameLine(other))
                && abs(other.boundingBox.midY - myMidY) < 0.15
        }
        if hasReadingLine { score += 0.5 }

        // 条件2: 漢字を含む適切な長さの行（+0.3）
        if hasKanji && (2...8).contains(charCount) { score += 0.3 }

        // 条件2b: 純粋漢字のみの短い行（カタカナなし）は人名として典型的（+0.15）
        let hasKatakana = text.unicodeScalars.contains { (0x30A0...0x30FF).contains($0.value) }
        if hasKanji && !hasKatakana && (2...5).contains(charCount) { score += 0.15 }

        // 条件3a: CFStringTokenizer が姓名の2トークンに分割する（+0.25）
        // ただし会社名接尾辞を含む場合は除外（例: "ABC商事" → 名前ではない）
        if hasKanji && (3...8).contains(charCount),
           let (_, first) = cfTokenizerSplit(text), !first.isEmpty,
           !Self.companySuffixes.contains(where: { text.hasSuffix($0) }) {
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

        // スペース1つで2セグメントに分かれる典型的な名前パターン（+0.15）
        let spaceParts = text.split(separator: " ", maxSplits: 2).count == 2
            ? text.split(separator: " ", maxSplits: 2)
            : text.split(separator: "\u{3000}", maxSplits: 2)
        if spaceParts.count == 2,
           (1...4).contains(spaceParts[0].count),
           (1...4).contains(spaceParts[1].count) {
            score += 0.15
        }

        return min(max(score, 0.0), 1.0)
    }

    // MARK: - フリガナ判定

    /// カタカナをひらがなに正規化する（ひらがなはそのまま返す）
    private func normalizeToHiragana(_ text: String) -> String {
        let mutable = NSMutableString(string: text)
        CFStringTransform(mutable, nil, kCFStringTransformHiraganaKatakana, true)
        return mutable as String
    }

    /// フリガナ行の判定：ひらがな・カタカナ（全角/半角）のみで構成される短い行
    private func isFuriganaLine(_ line: RecognizedLine) -> Bool {
        let text = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let stripped = text
            .replacingOccurrences(of: " ",  with: "")
            .replacingOccurrences(of: "　", with: "")
        guard (3...15).contains(stripped.count) else { return false }

        let hasKanji = text.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) }
        guard !hasKanji else { return false }

        return text.unicodeScalars.allSatisfy { s in
            (0x3040...0x30FF).contains(s.value)   // ひらがな・全角カタカナ
                || (0xFF65...0xFF9F).contains(s.value) // 半角カタカナ
                || s.value == 0x20
                || s.value == 0x3000
        }
    }

    /// ローマ字の氏名行かどうかを判定（ASCII英字+スペース+ピリオドのみ、2〜30文字）
    private func isRomajiNameLine(_ line: RecognizedLine) -> Bool {
        let text = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let stripped = text.replacingOccurrences(of: " ", with: "")
        guard (2...30).contains(stripped.count) else { return false }

        // ASCII英字・スペース・ピリオドのみ許可
        guard text.unicodeScalars.allSatisfy({ s in
            (0x41...0x5A).contains(s.value)  // A-Z
                || (0x61...0x7A).contains(s.value) // a-z
                || s.value == 0x20  // space
                || s.value == 0x2E  // period (for initials like "T.")
        }) else { return false }

        // 数字・@・URLフラグメントを含まないことは上記で保証済み
        // スペースで2〜3セグメントに分かれる典型的な名前パターンを要求
        let parts = text.split(separator: " ").filter { !$0.isEmpty }
        guard (2...3).contains(parts.count) else { return false }
        // 各パーツが英字で始まる（イニシャル "T." も許容）
        return parts.allSatisfy { $0.first?.isLetter == true }
    }

    /// ローマ字行から読み仮名（ひらがな）を推定し、漢字名との照合で語順を判定する
    private func resolveRomajiReading(
        romajiLine: RecognizedLine,
        lastName: String,
        firstName: String
    ) -> (lastNameReading: String, firstNameReading: String)? {
        let text = romajiLine.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = text.split(separator: " ").map { String($0) }
        guard parts.count >= 2 else { return nil }

        // イニシャル（"T."等）を除いた実質パーツのみ取得
        let substantialParts = parts.filter { $0.count > 2 || !$0.hasSuffix(".") }

        // 各パーツをひらがなに変換
        let readings = parts.map { romajiToHiragana($0.replacingOccurrences(of: ".", with: "")) }

        // CFStringTokenizer による参照読みを生成
        let refLast = generateReading(from: lastName)
        let refFirst = generateReading(from: firstName)

        if readings.count >= 2 {
            // パターン1: [姓, 名]（Yamada Taro）
            if readingsMatch(readings[0], refLast) && readingsMatch(readings[1], refFirst) {
                return (lastNameReading: readings[0], firstNameReading: readings[1])
            }
            // パターン2: [名, 姓]（Taro Yamada）
            if readingsMatch(readings[0], refFirst) && readingsMatch(readings[1], refLast) {
                return (lastNameReading: readings[1], firstNameReading: readings[0])
            }
            // パターン3: イニシャル+姓（T. Yamada / Yamada T.）
            if substantialParts.count == 1 {
                let subReading = romajiToHiragana(substantialParts[0].replacingOccurrences(of: ".", with: ""))
                if readingsMatch(subReading, refLast) {
                    return (lastNameReading: subReading, firstNameReading: refFirst)
                }
                if readingsMatch(subReading, refFirst) {
                    return (lastNameReading: refLast, firstNameReading: subReading)
                }
            }
            // パターン4: 片方だけ一致（語順不明だが姓が一致すれば採用）
            if readingsMatch(readings[0], refLast) {
                return (lastNameReading: readings[0], firstNameReading: readings[1])
            }
            if readingsMatch(readings[1], refLast) {
                return (lastNameReading: readings[1], firstNameReading: readings[0])
            }
        }

        return nil
    }

    /// ローマ字をひらがなに変換する（Kunrei式→Hepburn式正規化付き）
    private func romajiToHiragana(_ romaji: String) -> String {
        let normalized = normalizeRomaji(romaji)
        let mutable = NSMutableString(string: normalized)
        CFStringTransform(mutable, nil, kCFStringTransformLatinHiragana, false)
        return mutable as String
    }

    /// Kunrei式 → Hepburn式の前処理
    private func normalizeRomaji(_ romaji: String) -> String {
        var s = romaji.lowercased()
        let replacements: [(String, String)] = [
            ("sha", "sha"), ("shi", "shi"), ("shu", "shu"), ("sho", "sho"),
            ("chi", "chi"), ("tchi", "cchi"), ("tsu", "tsu"),
            ("sya", "sha"), ("syi", "shi"), ("syu", "shu"), ("syo", "sho"),
            ("tya", "cha"), ("tyi", "chi"), ("tyu", "chu"), ("tyo", "cho"),
            ("zya", "ja"),  ("zyi", "ji"),  ("zyu", "ju"),  ("zyo", "jo"),
            ("si", "shi"), ("ti", "chi"), ("tu", "tsu"), ("hu", "fu"),
            ("zi", "ji"),  ("di", "ji"),  ("du", "zu"),
        ]
        for (from, to) in replacements {
            s = s.replacingOccurrences(of: from, with: to)
        }
        return s
    }

    /// CFStringTokenizer のラテン転写属性からひらがな読みを生成する
    private func generateReading(from text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        if trimmed.unicodeScalars.allSatisfy({ $0.isASCII }) { return trimmed }

        let cfText   = trimmed as CFString
        let cfLocale = Locale(identifier: "ja_JP") as CFLocale
        guard let tokenizer = CFStringTokenizerCreate(
            kCFAllocatorDefault, cfText,
            CFRangeMake(0, CFStringGetLength(cfText)),
            kCFStringTokenizerUnitWord, cfLocale
        ) else { return trimmed }

        var result = ""
        while CFStringTokenizerAdvanceToNextToken(tokenizer).rawValue != 0 {
            if let latin = CFStringTokenizerCopyCurrentTokenAttribute(
                tokenizer, kCFStringTokenizerAttributeLatinTranscription
            ) as? String {
                let mutable = NSMutableString(string: latin)
                CFStringTransform(mutable, nil, kCFStringTransformLatinHiragana, false)
                result += mutable as String
            } else {
                let cfRange = CFStringTokenizerGetCurrentTokenRange(tokenizer)
                let nsRange = NSRange(location: cfRange.location, length: cfRange.length)
                if let swiftRange = Range(nsRange, in: trimmed) {
                    result += String(trimmed[swiftRange])
                }
            }
        }
        return result
    }

    /// ひらがな読みの一致判定（先頭2文字以上一致 + 長さ差1以内）
    private func readingsMatch(_ a: String, _ b: String) -> Bool {
        guard !a.isEmpty, !b.isEmpty else { return false }
        if a == b { return true }
        let prefixLen = min(2, a.count, b.count)
        return String(a.prefix(prefixLen)) == String(b.prefix(prefixLen))
            && abs(a.count - b.count) <= 1
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
