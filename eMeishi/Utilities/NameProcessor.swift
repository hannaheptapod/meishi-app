import Foundation
import CoreGraphics

// 氏名の分割・スコアリング・フリガナ処理
enum NameProcessor {

    // MARK: - 氏名分割

    /// 姓と名に分割する
    /// 優先順位: スペース分割 → CFStringTokenizer（MeCab）→ 全体を姓とするフォールバック
    static func splitName(_ text: String) -> (lastName: String, firstName: String) {
        guard !text.isEmpty else { return ("", "") }

        let separators = CharacterSet(charactersIn: " \u{3000}")
        let parts = text.components(separatedBy: separators)
                        .map { $0.trimmingCharacters(in: .whitespaces) }
                        .filter { !$0.isEmpty }
        if parts.count >= 2 {
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
    static func cfTokenizerSplit(_ text: String) -> (String, String)? {
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
    static func personNameScore(for line: RecognizedLine, candidates: [RecognizedLine]) -> Double {
        let text = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isPlausiblePersonNameText(text) else { return 0 }

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

        // --- 否定的シグナル ---

        let hasDigit = text.unicodeScalars.contains { $0.value >= 0x30 && $0.value <= 0x39 }
        if hasDigit { score -= 0.3 }

        let lower = text.lowercased()
        if lower.contains(".co.") || lower.contains("www") || lower.contains("http") || lower.contains("@") {
            score -= 0.3
        }

        if FieldDetector.departmentSuffixes.contains(where: { text.contains($0) })
            || FieldDetector.jobTitleKeywords.contains(where: { text.contains($0) }) {
            score -= 0.3
        }

        if FieldDetector.buildingSuffixes.contains(where: { text.contains($0) }) {
            score -= 0.5
        }

        let katakanaCount = text.unicodeScalars.filter { (0x30A0...0x30FF).contains($0.value) }.count
        if hasKanji && katakanaCount >= 3 {
            score -= 0.2
        }

        // --- 肯定的シグナル ---

        let myMidY = line.boundingBox.midY
        let isVertical = isVerticalLine(line)
        let hasReadingLine = candidates.contains { other in
            guard other.boundingBox != line.boundingBox else { return false }
            let sameRow = abs(other.boundingBox.midY - myMidY) < 0.15
            let sameColumn = (isVertical || isVerticalLine(other))
                && abs(other.boundingBox.midX - line.boundingBox.midX) < max(line.boundingBox.width, other.boundingBox.width) * 1.4
            return (isFuriganaLine(other) || isRomajiNameLine(other))
                && (sameRow || sameColumn)
        }
        if hasReadingLine { score += 0.5 }

        if hasKanji && (2...8).contains(charCount) { score += 0.3 }

        let hasKatakana = text.unicodeScalars.contains { (0x30A0...0x30FF).contains($0.value) }
        if hasKanji && !hasKatakana && (2...5).contains(charCount) { score += 0.15 }

        if hasKanji && (3...8).contains(charCount),
           let (_, first) = cfTokenizerSplit(text), !first.isEmpty,
           !FieldDetector.companySuffixes.contains(where: { text.hasSuffix($0) }) {
            score += 0.25
        }

        if !hasJapanese && FieldDetector.nlTaggerDetectsPersonalName(in: text) { score += 0.2 }

        if line.boundingBox.minY > 0.4 && (0.2...0.8).contains(line.boundingBox.midX) {
            score += 0.1
        }

        if isVertical && line.boundingBox.height > 0.12 && (0.2...0.9).contains(line.boundingBox.midX) {
            score += 0.15
        }

        if line.boundingBox.height > 0.06 { score += 0.15 }

        if !hasJapanese && (2...20).contains(charCount) { score += 0.1 }

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

    /// 位置や文字サイズでは救済できない、氏名として明白に不正な文字列を除外する。
    /// 漢数字だけの管理番号やOCR記号断片を「短い漢字名」と誤認しないための前段ガード。
    static func isPlausiblePersonNameText(_ text: String) -> Bool {
        let compact = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "　", with: "")
        guard (2...12).contains(compact.count) else { return false }
        return containsPlausibleNameCharacters(compact)
    }

    /// 縦書きで1文字ずつ認識された氏名列の部品判定。
    static func isPlausiblePersonNameComponent(_ text: String) -> Bool {
        let compact = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "　", with: "")
        guard (1...4).contains(compact.count) else { return false }
        return containsPlausibleNameCharacters(compact)
    }

    private static func containsPlausibleNameCharacters(_ compact: String) -> Bool {
        guard ContactPatternExtractor.extractEmail(from: compact) == nil,
              ContactPatternExtractor.extractPhone(from: compact) == nil,
              ContactPatternExtractor.extractURL(from: compact) == nil,
              !FieldDetector.isAddress(compact),
              !FieldDetector.isCompany(compact),
              !FieldDetector.isDepartment(compact),
              !FieldDetector.isJobTitle(compact) else {
            return false
        }

        let japaneseNumerals = CharacterSet(charactersIn: "〇零一二三四五六七八九十百千万億兆壱弐参伍陸漆捌玖")
        let ignored = CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters).union(.symbols)
        var hasNameCharacter = false
        for scalar in compact.unicodeScalars {
            if ignored.contains(scalar) || CharacterSet.decimalDigits.contains(scalar) {
                continue
            }
            if japaneseNumerals.contains(scalar) {
                continue
            }
            if (0x3040...0x30FF).contains(scalar.value)
                || (0x3400...0x4DBF).contains(scalar.value)
                || (0x4E00...0x9FFF).contains(scalar.value)
                || (0x41...0x5A).contains(scalar.value)
                || (0x61...0x7A).contains(scalar.value) {
                hasNameCharacter = true
                continue
            }
            return false
        }
        return hasNameCharacter
    }

    /// 未分類行から氏名候補を選び、ParsedCard に反映する。残った未分類行を返す。
    static func resolveNameFromUnclassified(_ result: inout CardFieldClassifier.ParsedCard,
                                            unclassified: [RecognizedLine]) -> [RecognizedLine] {
        var remaining = unclassified
        let scores = remaining.map { personNameScore(for: $0, candidates: remaining) }

        let rawName: String
        if let nameIndex = scores.indices.max(by: { scores[$0] < scores[$1] }),
           scores[nameIndex] > 0.2 {

            let selectedLine = remaining[nameIndex]
            let nameMidY = selectedLine.boundingBox.midY

            let nameBox = selectedLine.boundingBox
            let nameMinX = nameBox.minX
            let nameMaxX = nameBox.maxX
            let isVerticalName = isVerticalLine(selectedLine)
            let fragmentIndices = remaining.indices.filter { i -> Bool in
                guard i != nameIndex else { return false }
                let line = remaining[i]
                let t = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
                let stripped = t
                    .replacingOccurrences(of: " ",  with: "")
                    .replacingOccurrences(of: "　", with: "")
                let hasKanji = t.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) }
                let box = line.boundingBox
                let sameRow = abs(box.midY - nameMidY) < max(nameBox.height, box.height) * 0.6
                let xGap = nameBox.width * 0.5
                let xNearby = box.minX < nameMaxX + xGap && box.maxX > nameMinX - xGap
                let sameColumn = abs(box.midX - nameBox.midX) < max(nameBox.width, box.width) * 0.9
                let sameLogicalLine = isVerticalName ? sameColumn : (sameRow && xNearby)
                return hasKanji
                    && stripped.count <= 3
                    && sameLogicalLine
            }

            var allParts = [selectedLine] + fragmentIndices.map { remaining[$0] }
            allParts.sort {
                isVerticalName
                    ? $0.boundingBox.midY > $1.boundingBox.midY
                    : $0.boundingBox.midX < $1.boundingBox.midX
            }
            rawName = allParts
                .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
                .joined()

            let indicesToRemove = Set([nameIndex] + fragmentIndices)
            remaining = remaining.indices
                .filter { !indicesToRemove.contains($0) }
                .map { remaining[$0] }

        } else {
            rawName = ""
        }

        let (last, first) = splitName(rawName)
        result.lastName  = last
        result.firstName = first
        return remaining
    }

    // MARK: - フリガナ判定

    /// カタカナをひらがなに正規化する（長音符 ー を保存する）
    static func normalizeToHiragana(_ text: String) -> String {
        let placeholder: Character = "\u{FFFC}"
        let preserved = String(text.map { $0 == "ー" ? placeholder : $0 })
        let mutable = NSMutableString(string: preserved)
        CFStringTransform(mutable, nil, kCFStringTransformHiraganaKatakana, true)
        return String((mutable as String).map { $0 == placeholder ? "ー" : $0 })
    }

    /// フリガナ行の判定：ひらがな・カタカナ（全角/半角）のみで構成される短い行
    static func isFuriganaLine(_ line: RecognizedLine) -> Bool {
        let text = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let stripped = text
            .replacingOccurrences(of: " ",  with: "")
            .replacingOccurrences(of: "　", with: "")
        guard (3...15).contains(stripped.count) else { return false }

        let hasKanji = text.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) }
        guard !hasKanji else { return false }

        return text.unicodeScalars.allSatisfy { s in
            (0x3040...0x30FF).contains(s.value)
                || (0xFF65...0xFF9F).contains(s.value)
                || s.value == 0x20
                || s.value == 0x3000
        }
    }

    /// ローマ字の氏名行かどうかを判定
    static func isRomajiNameLine(_ line: RecognizedLine) -> Bool {
        let text = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let stripped = text.replacingOccurrences(of: " ", with: "")
        guard (2...30).contains(stripped.count) else { return false }

        guard text.unicodeScalars.allSatisfy({ s in
            (0x41...0x5A).contains(s.value)
                || (0x61...0x7A).contains(s.value)
                || s.value == 0x20
                || s.value == 0x2E
        }) else { return false }

        let parts = text.split(separator: " ").filter { !$0.isEmpty }
        guard (2...3).contains(parts.count) else { return false }
        return parts.allSatisfy { $0.first?.isLetter == true }
    }

    private static func isVerticalLine(_ line: RecognizedLine) -> Bool {
        line.textDirection == .topToBottom
            || line.boundingBox.height > line.boundingBox.width * 1.4
    }

    // MARK: - ローマ字→ひらがな変換

    /// ローマ字行から読み仮名を推定し、漢字名との照合で語順を判定する
    static func resolveRomajiReading(
        romajiLine: RecognizedLine,
        lastName: String,
        firstName: String
    ) -> (lastNameReading: String, firstNameReading: String)? {
        let text = romajiLine.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = text.split(separator: " ").map { String($0) }
        guard parts.count >= 2 else { return nil }

        let substantialParts = parts.filter { $0.count > 2 || !$0.hasSuffix(".") }
        let readings = parts.map { romajiToHiragana($0.replacingOccurrences(of: ".", with: "")) }

        let refLast = generateReading(from: lastName)
        let refFirst = generateReading(from: firstName)

        if readings.count >= 2 {
            if readingsMatch(readings[0], refLast) && readingsMatch(readings[1], refFirst) {
                return (lastNameReading: preferReading(romaji: readings[0], reference: refLast),
                        firstNameReading: preferReading(romaji: readings[1], reference: refFirst))
            }
            if readingsMatch(readings[0], refFirst) && readingsMatch(readings[1], refLast) {
                return (lastNameReading: preferReading(romaji: readings[1], reference: refLast),
                        firstNameReading: preferReading(romaji: readings[0], reference: refFirst))
            }
            if substantialParts.count == 1 {
                let subReading = romajiToHiragana(substantialParts[0].replacingOccurrences(of: ".", with: ""))
                if readingsMatch(subReading, refLast) {
                    return (lastNameReading: preferReading(romaji: subReading, reference: refLast),
                            firstNameReading: refFirst)
                }
                if readingsMatch(subReading, refFirst) {
                    return (lastNameReading: refLast,
                            firstNameReading: preferReading(romaji: subReading, reference: refFirst))
                }
            }
            if readingsMatch(readings[0], refLast) {
                return (lastNameReading: preferReading(romaji: readings[0], reference: refLast),
                        firstNameReading: preferReading(romaji: readings[1], reference: refFirst))
            }
            if readingsMatch(readings[1], refLast) {
                return (lastNameReading: preferReading(romaji: readings[1], reference: refLast),
                        firstNameReading: preferReading(romaji: readings[0], reference: refFirst))
            }
        }

        return nil
    }

    /// ローマ字をひらがなに変換する（Kunrei式→Hepburn式正規化付き）
    static func romajiToHiragana(_ romaji: String) -> String {
        RomajiReadingNormalizer.hiragana(from: romaji)
    }

    /// Kunrei式 → Hepburn式の前処理 + 長音正規化
    static func normalizeRomaji(_ romaji: String) -> String {
        RomajiReadingNormalizer.normalize(romaji)
    }

    /// CFStringTokenizer のラテン転写属性からひらがな読みを生成する
    static func generateReading(from text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        if trimmed.unicodeScalars.allSatisfy({ $0.isASCII }) { return trimmed }

        // ひらがな・カタカナのみなら直接変換（ー 保存付き）
        if trimmed.unicodeScalars.allSatisfy({ (0x3040...0x30FF).contains($0.value) || $0.value == 0x20 || $0.value == 0x3000 }) {
            return normalizeToHiragana(trimmed)
        }

        let cfText   = trimmed as CFString
        let cfLocale = Locale(identifier: "ja_JP") as CFLocale
        guard let tokenizer = CFStringTokenizerCreate(
            kCFAllocatorDefault, cfText,
            CFRangeMake(0, CFStringGetLength(cfText)),
            kCFStringTokenizerUnitWord, cfLocale
        ) else { return trimmed }

        var result = ""
        while CFStringTokenizerAdvanceToNextToken(tokenizer).rawValue != 0 {
            let cfRange = CFStringTokenizerGetCurrentTokenRange(tokenizer)
            let nsRange = NSRange(location: cfRange.location, length: cfRange.length)
            guard let swiftRange = Range(nsRange, in: trimmed) else { continue }
            let token = String(trimmed[swiftRange])

            // カタカナトークンは直接変換（Latin転写だと ー が母音重複になるため）
            if token.unicodeScalars.allSatisfy({ (0x30A0...0x30FF).contains($0.value) }) {
                result += normalizeToHiragana(token)
            } else if let latin = CFStringTokenizerCopyCurrentTokenAttribute(
                tokenizer, kCFStringTokenizerAttributeLatinTranscription
            ) as? String {
                let mutable = NSMutableString(string: latin)
                CFStringTransform(mutable, nil, kCFStringTransformLatinHiragana, false)
                result += mutable as String
            } else {
                result += token
            }
        }
        return result
    }

    /// ひらがな読みの一致判定（長音の有無を許容）
    static func readingsMatch(_ a: String, _ b: String) -> Bool {
        guard !a.isEmpty, !b.isEmpty else { return false }
        if a == b { return true }
        let prefixLen = min(2, a.count, b.count)
        if String(a.prefix(prefixLen)) == String(b.prefix(prefixLen))
            && abs(a.count - b.count) <= 1 { return true }
        // 長音許容: 長音拡張を除去して再比較
        let na = removeLongVowelExtensions(a)
        let nb = removeLongVowelExtensions(b)
        if na == nb { return true }
        let nPrefixLen = min(2, na.count, nb.count)
        return String(na.prefix(nPrefixLen)) == String(nb.prefix(nPrefixLen))
            && abs(na.count - nb.count) <= 1
    }

    /// ローマ字読みと参照読みを比較し、長音の違いだけなら参照読みを優先する
    static func preferReading(romaji: String, reference: String) -> String {
        guard !reference.isEmpty else { return romaji }
        if romaji == reference { return reference }
        if removeLongVowelExtensions(romaji) == removeLongVowelExtensions(reference) {
            return reference
        }
        return romaji
    }

    /// 長音拡張文字を除去して比較用に正規化する
    private static func removeLongVowelExtensions(_ reading: String) -> String {
        let oColumnKana: Set<Character> = [
            "お","こ","そ","と","の","ほ","も","よ","ろ","を",
            "ご","ぞ","ど","ぼ","ぽ","ょ","ぉ"
        ]
        let eColumnKana: Set<Character> = [
            "え","け","せ","て","ね","へ","め","れ",
            "げ","ぜ","で","べ","ぺ","ぇ"
        ]
        let vowels: Set<Character> = ["あ","い","う","え","お"]
        let chars = Array(reading)
        var result: [Character] = []
        for (i, ch) in chars.enumerated() {
            if i > 0 {
                if ch == "う" && oColumnKana.contains(chars[i - 1]) { continue }
                if ch == "い" && eColumnKana.contains(chars[i - 1]) { continue }
                // 二重母音の縮約（おお→お 等）: ローマ字由来 おう と トークナイザー由来 おお の一致判定用
                if vowels.contains(ch) && ch == chars[i - 1] { continue }
            }
            result.append(ch)
        }
        return String(result)
    }
}
