import Foundation
import CoreGraphics

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
        // SONY のような発音語を文字読みしない。連続略称として扱うのは最大3文字まで。
        return text.count == 1 || (text.count <= 3 && text == text.uppercased())
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

    /// フィールド解決後の氏名・会社 span から、根拠付きの読み候補を生成する。
    static func resolveReadings(
        parsed: CardFieldClassifier.ParsedCard,
        spans: [CardTextSpan],
        assignments: [FieldAssignment]
    ) -> ReadingResolution {
        var resolution = ReadingResolution()
        let assignedIDs = Set(assignments.flatMap(\.spanIDs))
        let available = spans.filter { !assignedIDs.contains($0.id) }

        if let nameAssignment = assignments.first(where: { $0.field == .personName }),
           let nameSpan = spans.first(where: { nameAssignment.spanIDs.contains($0.id) }) {
            appendPrintedNameCandidates(
                parsed: parsed,
                nameSpan: nameSpan,
                available: available,
                resolution: &resolution
            )
        }

        appendEmailAndTokenizerNameCandidates(parsed: parsed, resolution: &resolution)

        if let companyAssignment = assignments.first(where: { $0.field == .company }),
           let companySpan = spans.first(where: { companyAssignment.spanIDs.contains($0.id) }) {
            appendCompanyCandidates(
                company: parsed.company,
                companySpan: companySpan,
                available: available,
                resolution: &resolution
            )
        }

        resolution.candidates = deduplicated(resolution.candidates)
        return resolution
    }

    /// OCRで誤った位置に入った氏名境界を、メールのローマ字氏名と漢字の読みが
    /// 両側とも一致する場合に限って補正する。
    static func correctedNameSplitUsingEmail(
        lastName: String,
        firstName: String,
        email: String
    ) -> (lastName: String, firstName: String)? {
        guard let atIndex = email.firstIndex(of: "@") else { return nil }
        let localPart = String(email[..<atIndex]).lowercased()
            .replacingOccurrences(of: #"\d+$"#, with: "", options: .regularExpression)
        let segments = localPart.components(separatedBy: CharacterSet(charactersIn: "._-"))
            .filter { !$0.isEmpty }
        guard segments.count == 2,
              segments.allSatisfy(isPlausibleEmailNameSegment) else { return nil }

        let emailReadings = segments.map(romajiToHiragana)
        let fullName = (lastName + firstName)
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "　", with: "")
        let characters = Array(fullName)
        guard (2...8).contains(characters.count) else { return nil }

        for boundary in 1..<characters.count {
            let candidateLast = String(characters[..<boundary])
            let candidateFirst = String(characters[boundary...])
            let generatedLast = generateReading(from: candidateLast)
            let generatedFirst = generateReading(from: candidateFirst)

            if readingsMatch(generatedLast, emailReadings[0]),
               readingsMatch(generatedFirst, emailReadings[1]) {
                return (candidateLast, candidateFirst)
            }
            if readingsMatch(generatedLast, emailReadings[1]),
               readingsMatch(generatedFirst, emailReadings[0]) {
                return (candidateLast, candidateFirst)
            }
        }

        return nil
    }

    private static func appendPrintedNameCandidates(
        parsed: CardFieldClassifier.ParsedCard,
        nameSpan: CardTextSpan,
        available: [CardTextSpan],
        resolution: inout ReadingResolution
    ) {
        let nearby = available
            .filter { isLikelyReadingAnnotation($0, for: nameSpan) }
            .sorted { distance($0.boundingBox, nameSpan.boundingBox) < distance($1.boundingBox, nameSpan.boundingBox) }

        if let kana = nearby.first(where: {
            isKanaReading($0.text)
                && !isSemanticNonNameLine($0.text)
                && plausiblePrintedReading($0.text, for: parsed) != nil
        }), let split = plausiblePrintedReading(kana.text, for: parsed) {
            if !split.lastName.isEmpty {
                appendAutomatic(.lastName, reading: split.lastName, source: .printedKana, spanID: kana.id, resolution: &resolution)
            }
            if !split.firstName.isEmpty {
                appendAutomatic(.firstName, reading: split.firstName, source: .printedKana, spanID: kana.id, resolution: &resolution)
            }
            return
        }

        if let romaji = nearby.first(where: { isRomajiName($0.text) }),
           let readings = NameProcessor.resolveRomajiReading(
                romajiLine: RecognizedLine(
                    text: romaji.text,
                    boundingBox: romaji.boundingBox,
                    confidence: romaji.ocrConfidence,
                    textDirection: romaji.textDirection
                ),
                lastName: parsed.lastName,
                firstName: parsed.firstName
           ) {
            appendAutomatic(.lastName, reading: readings.lastNameReading, source: .printedRomaji, spanID: romaji.id, resolution: &resolution)
            appendAutomatic(.firstName, reading: readings.firstNameReading, source: .printedRomaji, spanID: romaji.id, resolution: &resolution)
        }
    }

    private static func appendEmailAndTokenizerNameCandidates(
        parsed: CardFieldClassifier.ParsedCard,
        resolution: inout ReadingResolution
    ) {
        let generatedLast = generateReading(from: parsed.lastName)
        let generatedFirst = generateReading(from: parsed.firstName)

        if let email = inferReadingFromEmail(email: parsed.email, lastName: parsed.lastName, firstName: parsed.firstName) {
            let validatesLastName = readingsMatch(email.lastNameReading, generatedLast)
            let validatesFirstName = readingsMatch(email.firstNameReading, generatedFirst)
            let validatesBothNames = validatesLastName && validatesFirstName
            let validatesNamePair = validatesLastName || validatesFirstName
            let confidence: FieldConfidence = validatesBothNames ? .high : .medium

            // メールの姓名2要素の片方が漢字読みと一致すれば、対応関係を確定できる。
            // もう片方は難読名でトークナイザーと一致しない場合があるため、候補止まりにしない。
            if validatesNamePair {
                if resolution.automaticValues[.lastName] == nil {
                    resolution.automaticValues[.lastName] = sanitizedCandidate(email.lastNameReading)
                }
                if resolution.automaticValues[.firstName] == nil {
                    resolution.automaticValues[.firstName] = sanitizedCandidate(email.firstNameReading)
                }
            }
            appendCandidate(.lastName, reading: email.lastNameReading, source: .email, confidence: confidence, spanIDs: [], resolution: &resolution)
            appendCandidate(.firstName, reading: email.firstNameReading, source: .email, confidence: confidence, spanIDs: [], resolution: &resolution)
        }

        // 印字・メールで確定できない場合も、漢字から生成できた妥当なかな読みは初期値にする。
        if resolution.automaticValues[.lastName] == nil,
           isPlausibleGeneratedNameReading(generatedLast, for: parsed.lastName) {
            resolution.automaticValues[.lastName] = sanitizedCandidate(generatedLast)
        }
        if resolution.automaticValues[.firstName] == nil,
           isPlausibleGeneratedNameReading(generatedFirst, for: parsed.firstName) {
            resolution.automaticValues[.firstName] = sanitizedCandidate(generatedFirst)
        }

        appendCandidate(.lastName, reading: generatedLast, source: .tokenizer, confidence: .low, spanIDs: [], resolution: &resolution)
        appendCandidate(.firstName, reading: generatedFirst, source: .tokenizer, confidence: .low, spanIDs: [], resolution: &resolution)
    }

    private static func appendCompanyCandidates(
        company: String,
        companySpan: CardTextSpan,
        available: [CardTextSpan],
        resolution: inout ReadingResolution
    ) {
        let strippedCompany = LegalEntityTerms.stripKanji(from: company)
        if isKanaReading(strippedCompany) {
            appendAutomatic(.company, reading: katakanaToHiragana(strippedCompany), source: .printedKana, spanID: companySpan.id, resolution: &resolution)
            return
        }
        if let printed = available
            .filter({ isKanaReading($0.text) && isLikelyReadingAnnotation($0, for: companySpan) })
            .min(by: { distance($0.boundingBox, companySpan.boundingBox) < distance($1.boundingBox, companySpan.boundingBox) }) {
            appendAutomatic(.company, reading: katakanaToHiragana(printed.text), source: .printedKana, spanID: printed.id, resolution: &resolution)
        }
        let generated = generateCompanyReading(from: company)
        guard !generated.isEmpty else { return }
        let source: ReadingSource = containsLatinInitialism(company) ? .latinInitialism : .tokenizer
        appendCandidate(.company, reading: BusinessCard.stripLegalEntityReading(from: generated), source: source, confidence: source == .latinInitialism ? .medium : .low, spanIDs: [companySpan.id], resolution: &resolution)
    }

    private static func appendAutomatic(
        _ target: ReadingTarget,
        reading: String,
        source: ReadingSource,
        spanID: String,
        resolution: inout ReadingResolution
    ) {
        let normalized = sanitizedCandidate(reading)
        guard !normalized.isEmpty else { return }
        resolution.automaticValues[target] = normalized
        appendCandidate(target, reading: normalized, source: source, confidence: .high, spanIDs: [spanID], resolution: &resolution)
    }

    private static func appendCandidate(
        _ target: ReadingTarget,
        reading: String,
        source: ReadingSource,
        confidence: FieldConfidence,
        spanIDs: [String],
        resolution: inout ReadingResolution
    ) {
        let normalized = sanitizedCandidate(reading)
        guard !normalized.isEmpty else { return }
        resolution.candidates.append(ReadingCandidate(
            target: target,
            reading: normalized,
            source: source,
            confidence: confidence,
            sourceSpanIDs: spanIDs
        ))
    }

    private static func deduplicated(_ candidates: [ReadingCandidate]) -> [ReadingCandidate] {
        Dictionary(grouping: candidates, by: { "\($0.target.rawValue):\($0.reading)" })
            .compactMap { _, values in values.max { lhs, rhs in lhs.confidence < rhs.confidence } }
            .sorted {
                if $0.target != $1.target { return $0.target.rawValue < $1.target.rawValue }
                if $0.confidence != $1.confidence { return $0.confidence > $1.confidence }
                return $0.reading < $1.reading
            }
    }

    private static func isKanaReading(_ text: String) -> Bool {
        let stripped = text.replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "　", with: "")
        guard (2...24).contains(stripped.count) else { return false }
        return stripped.unicodeScalars.allSatisfy {
            (0x3040...0x30FF).contains($0.value) || (0xFF65...0xFF9F).contains($0.value)
        }
    }

    /// 近くにあるだけの部署名・役職名・会社名を、氏名の読みとして扱わない。
    private static func isSemanticNonNameLine(_ text: String) -> Bool {
        FieldDetector.isJobTitle(text)
            || FieldDetector.isDepartment(text)
            || FieldDetector.isCompany(text)
    }

    /// 印字された読みを姓名に分けた結果が、各漢字名に対して最低限妥当な長さか確認する。
    /// 読みそのものの一致を必須にすると難読名を捨てるため、ここでは明白な誤対応だけを除外する。
    private static func plausiblePrintedReading(
        _ text: String,
        for parsed: CardFieldClassifier.ParsedCard
    ) -> (lastName: String, firstName: String)? {
        let normalized = katakanaToHiragana(text)
        let split = NameProcessor.splitName(normalized)
        guard !split.lastName.isEmpty, !split.firstName.isEmpty else { return nil }
        guard plausibleReadingLength(split.lastName, for: parsed.lastName),
              plausibleReadingLength(split.firstName, for: parsed.firstName) else {
            return nil
        }
        return split
    }

    private static func plausibleReadingLength(_ reading: String, for name: String) -> Bool {
        let compactReading = reading.replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "　", with: "")
        let compactName = name.replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "　", with: "")
        guard !compactReading.isEmpty, !compactName.isEmpty else { return false }

        let ideographCount = compactName.unicodeScalars.filter {
            (0x3400...0x4DBF).contains($0.value) || (0x4E00...0x9FFF).contains($0.value)
        }.count
        let minimum = ideographCount >= 2 ? 2 : 1
        let maximum = max(4, compactName.count * 4 + 2)
        return (minimum...maximum).contains(compactReading.count)
    }

    /// トークナイザーが漢字を変換できず原文を返した場合は、自動入力へ使わない。
    private static func isPlausibleGeneratedNameReading(_ reading: String, for name: String) -> Bool {
        let compact = reading
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "　", with: "")
        guard !compact.isEmpty,
              compact.unicodeScalars.allSatisfy({ (0x3040...0x30FF).contains($0.value) }),
              plausibleReadingLength(compact, for: name) else {
            return false
        }
        return true
    }

    private static func isRomajiName(_ text: String) -> Bool {
        let parts = text.split(separator: " ").filter { !$0.isEmpty }
        guard (2...3).contains(parts.count) else { return false }
        return text.unicodeScalars.allSatisfy {
            (0x41...0x5A).contains($0.value) || (0x61...0x7A).contains($0.value)
                || $0.value == 0x20 || $0.value == 0x2E
        }
    }

    private static func containsLatinInitialism(_ text: String) -> Bool {
        let runs = text.split(whereSeparator: { !isASCIILetter($0) }).map(String.init)
        return runs.contains(where: isLatinInitialism)
    }

    private static func sanitizedCandidate(_ reading: String) -> String {
        let trimmed = reading.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.unicodeScalars.allSatisfy(\.isASCII) else { return "" }
        return trimmed
    }

    private static func spatiallyRelated(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
        abs(lhs.midY - rhs.midY) <= max(lhs.height, rhs.height) * 3.2
            && abs(lhs.midX - rhs.midX) <= max(lhs.width, rhs.width) * 0.9 + 0.08
    }

    /// 印字された読みは、対象文字列と同じ向きで、より小さく、行または列が重なる注記に限定する。
    /// 「近くにあるかな文字列」だけでは、縦書き名刺の別フィールドを読みとして誤採用するため。
    private static func isLikelyReadingAnnotation(
        _ candidate: CardTextSpan,
        for anchor: CardTextSpan
    ) -> Bool {
        guard spatiallyRelated(candidate.boundingBox, anchor.boundingBox) else { return false }
        let anchorIsVertical = anchor.textDirection == .topToBottom
            || anchor.boundingBox.height > anchor.boundingBox.width * 1.4
        let candidateIsVertical = candidate.textDirection == .topToBottom
            || candidate.boundingBox.height > candidate.boundingBox.width * 1.4
        guard anchorIsVertical == candidateIsVertical else { return false }

        if anchorIsVertical {
            let overlap = min(candidate.boundingBox.maxY, anchor.boundingBox.maxY)
                - max(candidate.boundingBox.minY, anchor.boundingBox.minY)
            let overlapRatio = overlap / max(min(candidate.boundingBox.height, anchor.boundingBox.height), 0.001)
            return candidate.boundingBox.width <= anchor.boundingBox.width * 0.85
                && overlapRatio >= 0.5
        }

        let overlap = min(candidate.boundingBox.maxX, anchor.boundingBox.maxX)
            - max(candidate.boundingBox.minX, anchor.boundingBox.minX)
        let overlapRatio = overlap / max(min(candidate.boundingBox.width, anchor.boundingBox.width), 0.001)
        return candidate.boundingBox.height <= anchor.boundingBox.height * 0.85
            && overlapRatio >= 0.5
    }

    private static func distance(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
        hypot(lhs.midX - rhs.midX, lhs.midY - rhs.midY)
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

            // OCRが氏名を誤分割すると参照読みとの一致だけではメール候補まで失われる。
            // 2要素のローカルパートは一般的な「姓.名」順を補助候補として残し、
            // 自動確定はせずOCR確認画面でユーザーが選択できるようにする。
            if readings.count == 2,
               isPlausibleEmailNameSegment(segments[0]),
               isPlausibleEmailNameSegment(segments[1]) {
                return (lastNameReading: readings[0], firstNameReading: readings[1])
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

    private static func isPlausibleEmailNameSegment(_ segment: String) -> Bool {
        guard (2...32).contains(segment.count) else { return false }
        return segment.unicodeScalars.allSatisfy {
            (0x61...0x7A).contains($0.value)
        }
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
