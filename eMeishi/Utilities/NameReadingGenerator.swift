import Foundation

// 読み仮名の自動生成・メールアドレスからの読み推定
enum NameReadingGenerator {

    /// CFStringTokenizer のラテン転写属性からひらがな読みを生成する
    static func generateReading(from text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        // ひらがな・カタカナのみなら変換不要でそのまま返す（カタカナはひらがなへ）
        if trimmed.unicodeScalars.allSatisfy({ (0x3040...0x30FF).contains($0.value) || $0.value == 0x20 || $0.value == 0x3000 }) {
            let mutable = NSMutableString(string: trimmed)
            CFStringTransform(mutable, nil, kCFStringTransformHiraganaKatakana, true)
            return mutable as String
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
            if readingsMatch(readings[0], refLast) && readingsMatch(readings[1], refFirst) {
                return (lastNameReading: readings[0], firstNameReading: readings[1])
            }
            if readingsMatch(readings[0], refFirst) && readingsMatch(readings[1], refLast) {
                return (lastNameReading: readings[1], firstNameReading: readings[0])
            }
            if readings[0].count == 1 && readingsMatch(readings[1], refLast) {
                return (lastNameReading: readings[1], firstNameReading: refFirst)
            }
            if readings[1].count == 1 && readingsMatch(readings[0], refLast) {
                return (lastNameReading: readings[0], firstNameReading: refFirst)
            }
        } else if readings.count == 1 {
            let single = readings[0]
            if !refLast.isEmpty && single.hasPrefix(refLast) {
                let remainder = String(single.dropFirst(refLast.count))
                if !remainder.isEmpty && readingsMatch(remainder, refFirst) {
                    return (lastNameReading: refLast, firstNameReading: remainder)
                }
            }
            if !refFirst.isEmpty && single.hasPrefix(refFirst) {
                let remainder = String(single.dropFirst(refFirst.count))
                if !remainder.isEmpty && readingsMatch(remainder, refLast) {
                    return (lastNameReading: remainder, firstNameReading: refFirst)
                }
            }
        }

        return nil
    }

    /// Kunrei式ローマ字をHepburn式に正規化してからひらがなに変換する
    static func romajiToHiragana(_ romaji: String) -> String {
        let normalized = normalizeRomaji(romaji)
        let mutable = NSMutableString(string: normalized)
        CFStringTransform(mutable, nil, kCFStringTransformLatinHiragana, false)
        return mutable as String
    }

    /// Kunrei式 → Hepburn式の前処理
    static func normalizeRomaji(_ romaji: String) -> String {
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

    /// ひらがな読みの一致判定
    static func readingsMatch(_ a: String, _ b: String) -> Bool {
        guard !a.isEmpty, !b.isEmpty else { return false }
        if a == b { return true }
        let prefixLen = min(2, a.count, b.count)
        return String(a.prefix(prefixLen)) == String(b.prefix(prefixLen))
            && abs(a.count - b.count) <= 1
    }
}
