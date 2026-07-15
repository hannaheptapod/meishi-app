import Foundation

// CFStringTransform に渡す前のローマ字正規化を一元管理する。
enum RomajiReadingNormalizer {

    /// Kunrei式 → Hepburn式の前処理 + 長音正規化 + 撥音境界補正
    static func normalize(_ romaji: String) -> String {
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
        // Hepburn長音: oh + 子音 → ouh（例: ohta → ouhta → おうた）
        s = s.replacingOccurrences(
            of: #"oh(?=[bcdfghjklmnpqrstvwxyz])"#,
            with: "ouh",
            options: .regularExpression
        )
        // 語末の oh → ou（例: itoh → itou → いとう）
        s = s.replacingOccurrences(
            of: #"oh$"#,
            with: "ou",
            options: .regularExpression
        )
        // 日本語名の撥音境界: shinya → shin'ya → しんや
        s = s.replacingOccurrences(
            of: #"n(?=y)"#,
            with: "n'",
            options: .regularExpression
        )
        return s
    }

    static func hiragana(from romaji: String) -> String {
        let mutable = NSMutableString(string: normalize(romaji))
        CFStringTransform(mutable, nil, kCFStringTransformLatinHiragana, false)
        return mutable as String
    }
}

// 読み仮名の自動生成・メールアドレスからの読み推定
enum NameReadingGenerator {

    private static let latinLetterReadings: [Character: String] = [
        "a": "えー", "b": "びー", "c": "しー", "d": "でぃー", "e": "いー",
        "f": "えふ", "g": "じー", "h": "えいち", "i": "あい", "j": "じぇー",
        "k": "けー", "l": "える", "m": "えむ", "n": "えぬ", "o": "おー",
        "p": "ぴー", "q": "きゅー", "r": "あーる", "s": "えす", "t": "てぃー",
        "u": "ゆー", "v": "ぶい", "w": "だぶりゅー", "x": "えっくす",
        "y": "わい", "z": "ぜっと",
    ]

    /// CFStringTokenizer のラテン転写属性からひらがな読みを生成する
    static func generateReading(from text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        // ひらがな・カタカナのみなら変換不要でそのまま返す（カタカナはひらがなへ）
        if trimmed.unicodeScalars.allSatisfy({ (0x3040...0x30FF).contains($0.value) || $0.value == 0x20 || $0.value == 0x3000 }) {
            return katakanaToHiragana(trimmed)
        }

        // ASCII のみ（英語名など）はそのまま返す
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
            let cfRange = CFStringTokenizerGetCurrentTokenRange(tokenizer)
            let nsRange = NSRange(location: cfRange.location, length: cfRange.length)
            guard let swiftRange = Range(nsRange, in: trimmed) else { continue }
            let token = String(trimmed[swiftRange])

            // かなトークンは直接変換（Latin転写だと「てぃー」が「てぃい」になるため）
            if token.unicodeScalars.allSatisfy({ (0x3040...0x30FF).contains($0.value) }) {
                result += katakanaToHiragana(token)
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

    /// 会社名用の読みを生成する。単独英字と全大文字略称はアルファベット名称として読む。
    /// 読みを確定できない英単語が含まれる場合は空文字を返し、手入力を優先する。
    static func generateCompanyReading(from text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        var result = ""
        var latinRun = ""
        var nonLatinRun = ""
        var containsUnresolvedLatinWord = false

        func convertedLatin(_ run: String) -> String {
            guard !run.isEmpty else { return "" }
            guard isLatinInitialism(run) else { return "" }
            return spellInitialism(run)
        }

        for character in text {
            if isASCIILetter(character) {
                if !nonLatinRun.isEmpty {
                    result += generateReading(from: nonLatinRun)
                    nonLatinRun.removeAll(keepingCapacity: true)
                }
                latinRun.append(character)
            } else {
                if !latinRun.isEmpty {
                    let converted = convertedLatin(latinRun)
                    if converted.isEmpty { containsUnresolvedLatinWord = true }
                    result += converted
                    latinRun.removeAll(keepingCapacity: true)
                }
                nonLatinRun.append(character)
            }
        }
        if !latinRun.isEmpty {
            let converted = convertedLatin(latinRun)
            if converted.isEmpty { containsUnresolvedLatinWord = true }
            result += converted
        }
        if !nonLatinRun.isEmpty {
            result += generateReading(from: nonLatinRun)
        }

        guard !containsUnresolvedLatinWord else { return "" }
        return normalizeCompanyReading(result)
    }

    private static func normalizeCompanyReading(_ reading: String) -> String {
        let removable = CharacterSet.whitespacesAndNewlines.union(
            CharacterSet(charactersIn: "・･-‐‑‒–—―_/.,，．&＆")
        )
        return String(reading.unicodeScalars.filter { !removable.contains($0) })
    }

    private static func isLatinInitialism(_ text: String) -> Bool {
        guard !text.isEmpty, text.allSatisfy(isASCIILetter) else { return false }
        return text.count == 1 || text == text.uppercased()
    }

    private static func spellInitialism(_ text: String) -> String {
        text.lowercased().compactMap { latinLetterReadings[$0] }.joined()
    }

    private static func isASCIILetter(_ character: Character) -> Bool {
        guard character.unicodeScalars.count == 1, let scalar = character.unicodeScalars.first else {
            return false
        }
        return (0x41...0x5A).contains(scalar.value) || (0x61...0x7A).contains(scalar.value)
    }

    /// カタカナをひらがなに変換する（長音符 ー を保存する）
    private static func katakanaToHiragana(_ text: String) -> String {
        let placeholder: Character = "\u{FFFC}"
        let preserved = String(text.map { $0 == "ー" ? placeholder : $0 })
        let mutable = NSMutableString(string: preserved)
        CFStringTransform(mutable, nil, kCFStringTransformHiraganaKatakana, true)
        return String((mutable as String).map { $0 == placeholder ? "ー" : $0 })
    }

    /// メールアドレスのローカルパートから氏名の読み（ひらがな）を推定する
    static func inferReadingFromEmail(
        email: String,
        lastName: String,
        firstName: String
    ) -> (lastNameReading: String, firstNameReading: String)? {
        guard !email.isEmpty, !lastName.isEmpty else { return nil }
        guard let atIndex = email.firstIndex(of: "@") else { return nil }

        let localPart = String(email[email.startIndex..<atIndex]).lowercased()
        let cleaned = localPart.replacingOccurrences(
            of: #"\d+$"#, with: "", options: .regularExpression
        )
        guard !cleaned.isEmpty else { return nil }

        let segments = cleaned.components(separatedBy: CharacterSet(charactersIn: "._-"))
            .filter { !$0.isEmpty }
        guard !segments.isEmpty, segments.count <= 3 else { return nil }

        let readings = segments.map { romajiToHiragana($0) }

        let refLast = generateReading(from: lastName)
        let refFirst = generateReading(from: firstName)

        if readings.count >= 2 {
            // 両方マッチ（姓-名 順）
            if readingsMatch(readings[0], refLast) && readingsMatch(readings[1], refFirst) {
                return (lastNameReading: preferReading(romaji: readings[0], reference: refLast),
                        firstNameReading: preferReading(romaji: readings[1], reference: refFirst))
            }
            // 両方マッチ（名-姓 順）
            if readingsMatch(readings[0], refFirst) && readingsMatch(readings[1], refLast) {
                return (lastNameReading: preferReading(romaji: readings[1], reference: refLast),
                        firstNameReading: preferReading(romaji: readings[0], reference: refFirst))
            }
            // イニシャル + 姓
            if readings[0].count == 1 && readingsMatch(readings[1], refLast) {
                return (lastNameReading: preferReading(romaji: readings[1], reference: refLast),
                        firstNameReading: refFirst)
            }
            if readings[1].count == 1 && readingsMatch(readings[0], refLast) {
                return (lastNameReading: preferReading(romaji: readings[0], reference: refLast),
                        firstNameReading: refFirst)
            }
            // 片方のみ姓マッチ → もう一方をメール由来の名読みとして採用
            if readingsMatch(readings[0], refLast) {
                return (lastNameReading: preferReading(romaji: readings[0], reference: refLast),
                        firstNameReading: readings[1])
            }
            if readingsMatch(readings[1], refLast) {
                return (lastNameReading: preferReading(romaji: readings[1], reference: refLast),
                        firstNameReading: readings[0])
            }
        } else if readings.count == 1 {
            let single = readings[0]
            if !refLast.isEmpty && single.hasPrefix(refLast) {
                let remainder = String(single.dropFirst(refLast.count))
                if !remainder.isEmpty && readingsMatch(remainder, refFirst) {
                    return (lastNameReading: refLast,
                            firstNameReading: preferReading(romaji: remainder, reference: refFirst))
                }
            }
            if !refFirst.isEmpty && single.hasPrefix(refFirst) {
                let remainder = String(single.dropFirst(refFirst.count))
                if !remainder.isEmpty && readingsMatch(remainder, refLast) {
                    return (lastNameReading: preferReading(romaji: remainder, reference: refLast),
                            firstNameReading: refFirst)
                }
            }
            // 1セグメントで姓にマッチ → 姓読みのみ返す（名はCFStringTokenizerにフォールバック）
            if readingsMatch(single, refLast) {
                return (lastNameReading: preferReading(romaji: single, reference: refLast),
                        firstNameReading: refFirst)
            }
        }

        return nil
    }

    /// Kunrei式ローマ字をHepburn式に正規化してからひらがなに変換する
    static func romajiToHiragana(_ romaji: String) -> String {
        RomajiReadingNormalizer.hiragana(from: romaji)
    }

    /// Kunrei式 → Hepburn式の前処理 + 長音正規化
    static func normalizeRomaji(_ romaji: String) -> String {
        RomajiReadingNormalizer.normalize(romaji)
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
