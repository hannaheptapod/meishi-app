import Foundation
import CoreGraphics
import os

// ルールベースのフィールド分類器（ファサード）
// 実際の処理は ContactPatternExtractor / FieldDetector / NameProcessor に委譲
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

    // MARK: - ルールベース前段処理（ハイブリッド方式用）

    struct StructuredFieldsResult {
        var parsed: ParsedCard
        var unclassifiedLines: [String]
    }

    func classifyStructuredFields(lines: [RecognizedLine]) -> StructuredFieldsResult {
        let lines = expandCombinedNameCompanyLines(lines)
        var result = ParsedCard()
        var unclassified: [RecognizedLine] = []

        AppLogger.classifier.debug("=== Pass1 開始 (\(lines.count, privacy: .public)行) ===")

        // --- Pass1: パターン・キーワードで確実に判定できるフィールドを抽出 ---
        for line in lines {
            let trimmed = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }

            if result.email.isEmpty, let email = ContactPatternExtractor.extractEmail(from: trimmed) {
                result.email = email
                AppLogger.classifier.debug("email: \(trimmed, privacy: .private)")
            } else if let phone = ContactPatternExtractor.extractPhone(from: trimmed) {
                result.phones.append(phone)
                AppLogger.classifier.debug("phone: \(trimmed, privacy: .private)")
            } else if result.website.isEmpty, let url = ContactPatternExtractor.extractURL(from: trimmed) {
                result.website = url
                AppLogger.classifier.debug("website: \(trimmed, privacy: .private)")
            } else if result.address.isEmpty, FieldDetector.isAddress(trimmed) {
                result.address = trimmed
                AppLogger.classifier.debug("address: \(trimmed, privacy: .private)")
            } else if FieldDetector.isAddress(trimmed) {
                result.address += " " + trimmed
                AppLogger.classifier.debug("address(追加): \(trimmed, privacy: .private)")
            } else if result.company.isEmpty, FieldDetector.isCompany(trimmed) {
                result.company = trimmed.trimmingCharacters(in: .whitespaces)
                AppLogger.classifier.debug("company: \(trimmed, privacy: .private)")
            } else if FieldDetector.isDepartment(trimmed) {
                result.department = result.department.isEmpty
                    ? trimmed
                    : result.department + " " + trimmed
                AppLogger.classifier.debug("department: \(trimmed, privacy: .private)")
            } else if result.title.isEmpty, FieldDetector.isJobTitle(trimmed) {
                result.title = trimmed
                AppLogger.classifier.debug("title: \(trimmed, privacy: .private)")
            } else {
                unclassified.append(line)
                AppLogger.classifier.debug("未分類: \(trimmed, privacy: .private)")
            }
        }

        AppLogger.classifier.debug("Pass1結果: email=\(result.email.isEmpty ? "×" : "○", privacy: .public) phone=\(result.phones.count, privacy: .public)件 web=\(result.website.isEmpty ? "×" : "○", privacy: .public) addr=\(result.address.isEmpty ? "×" : "○", privacy: .public) co=\(result.company.isEmpty ? "×" : "○", privacy: .public) dept=\(result.department.isEmpty ? "×" : "○", privacy: .public) title=\(result.title.isEmpty ? "×" : "○", privacy: .public)")

        // --- Pass1.5: 建物名を住所に追加 ---
        if !result.address.isEmpty {
            unclassified.removeAll { line in
                let t = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if FieldDetector.isBuildingName(t) {
                    result.address += " " + t
                    AppLogger.classifier.debug("address(建物名): \(t, privacy: .private)")
                    return true
                }
                return false
            }
        }

        // --- Pass2: 空間情報を使った名前スコアリング ---
        if !unclassified.isEmpty {
            let scores = unclassified.map { NameProcessor.personNameScore(for: $0, candidates: unclassified) }
            for (idx, line) in unclassified.enumerated() {
                let t = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
                AppLogger.classifier.debug("Pass2スコア: \(t, privacy: .private) = \(String(format: "%.3f", scores[idx]), privacy: .public)")
            }
            if let bestIdx = scores.indices.max(by: { scores[$0] < scores[$1] }),
               scores[bestIdx] > 0.35 {
                let bestText = unclassified[bestIdx].text.trimmingCharacters(in: .whitespacesAndNewlines)
                AppLogger.classifier.debug("名前確定(>0.35): \(bestText, privacy: .private) (score=\(String(format: "%.3f", scores[bestIdx]), privacy: .public))")
                unclassified = NameProcessor.resolveNameFromUnclassified(&result, unclassified: unclassified)
                AppLogger.classifier.debug("名前解決後: lastName=\(result.lastName, privacy: .private) firstName=\(result.firstName, privacy: .private)")
                // フリガナ行を氏名読み仮名として取得
                if let furiganaLine = unclassified.first(where: { NameProcessor.isFuriganaLine($0) }) {
                    let rawReading = furiganaLine.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    let (lastR, firstR) = NameProcessor.splitName(rawReading)
                    result.lastNameReading = NameProcessor.normalizeToHiragana(lastR)
                    result.firstNameReading = NameProcessor.normalizeToHiragana(firstR)
                    AppLogger.classifier.debug("フリガナ: lastR=\(result.lastNameReading, privacy: .private) firstR=\(result.firstNameReading, privacy: .private)")
                } else if let romajiLine = unclassified.first(where: { NameProcessor.isRomajiNameLine($0) }),
                          let romajiReading = NameProcessor.resolveRomajiReading(
                              romajiLine: romajiLine,
                              lastName: result.lastName,
                              firstName: result.firstName
                          ) {
                    result.lastNameReading = romajiReading.lastNameReading
                    result.firstNameReading = romajiReading.firstNameReading
                    AppLogger.classifier.debug("ローマ字読み: lastR=\(result.lastNameReading, privacy: .private) firstR=\(result.firstNameReading, privacy: .private)")
                }
                unclassified.removeAll { NameProcessor.isFuriganaLine($0) }
                unclassified.removeAll { NameProcessor.isRomajiNameLine($0) }
            } else {
                AppLogger.classifier.debug("名前スコア不足 → LLMに委譲")
            }
        }

        let unclassifiedTexts = unclassified.map {
            $0.text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        AppLogger.classifier.debug("最終未分類: \(unclassifiedTexts, privacy: .private)")
        return StructuredFieldsResult(parsed: result, unclassifiedLines: unclassifiedTexts)
    }

    // MARK: - 分類エントリポイント（従来API: 全フィールド分類）

    func classify(lines: [RecognizedLine]) -> ParsedCard {
        let lines = expandCombinedNameCompanyLines(lines)
        var result = ParsedCard()
        var unclassified: [RecognizedLine] = []

        for line in lines {
            let trimmed = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }

            if result.email.isEmpty, let email = ContactPatternExtractor.extractEmail(from: trimmed) {
                result.email = email
            } else if let phone = ContactPatternExtractor.extractPhone(from: trimmed) {
                result.phones.append(phone)
            } else if result.website.isEmpty, let url = ContactPatternExtractor.extractURL(from: trimmed) {
                result.website = url
            } else if result.address.isEmpty, FieldDetector.isAddress(trimmed) {
                result.address = trimmed
            } else if result.company.isEmpty, FieldDetector.isCompany(trimmed) {
                result.company = trimmed.trimmingCharacters(in: .whitespaces)
            } else if FieldDetector.isDepartment(trimmed) {
                result.department = result.department.isEmpty
                    ? trimmed
                    : result.department + " " + trimmed
            } else if result.title.isEmpty, FieldDetector.isJobTitle(trimmed) {
                result.title = trimmed
            } else {
                unclassified.append(line)
            }
        }

        // --- Pass1.5：建物名を住所に追加 ---
        if !result.address.isEmpty {
            unclassified.removeAll { line in
                let t = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if FieldDetector.isBuildingName(t) {
                    result.address += " " + t
                    return true
                }
                return false
            }
        }

        // --- Pass2：未分類の行から氏名を推定 ---
        unclassified = NameProcessor.resolveNameFromUnclassified(&result, unclassified: unclassified)

        // フリガナ行を氏名読み仮名として取得
        if let furiganaLine = unclassified.first(where: { NameProcessor.isFuriganaLine($0) }) {
            let rawReading = furiganaLine.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let (lastR, firstR) = NameProcessor.splitName(rawReading)
            result.lastNameReading  = NameProcessor.normalizeToHiragana(lastR)
            result.firstNameReading = NameProcessor.normalizeToHiragana(firstR)
        } else if let romajiLine = unclassified.first(where: { NameProcessor.isRomajiNameLine($0) }),
                  let romajiReading = NameProcessor.resolveRomajiReading(
                      romajiLine: romajiLine,
                      lastName: result.lastName,
                      firstName: result.firstName
                  ) {
            result.lastNameReading = romajiReading.lastNameReading
            result.firstNameReading = romajiReading.firstNameReading
        }
        unclassified.removeAll { NameProcessor.isFuriganaLine($0) }
        unclassified.removeAll { NameProcessor.isRomajiNameLine($0) }

        // 会社名フォールバック
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

        return result
    }

    private func expandCombinedNameCompanyLines(_ lines: [RecognizedLine]) -> [RecognizedLine] {
        lines.flatMap { splitCombinedNameCompanyLine($0) }
    }

    private func splitCombinedNameCompanyLine(_ line: RecognizedLine) -> [RecognizedLine] {
        let text = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return [line] }
        guard FieldDetector.isCompany(text) else { return [line] }
        guard ContactPatternExtractor.extractEmail(from: text) == nil,
              ContactPatternExtractor.extractPhone(from: text) == nil,
              ContactPatternExtractor.extractURL(from: text) == nil,
              !FieldDetector.isAddress(text) else {
            return [line]
        }

        let parts = text.components(separatedBy: CharacterSet(charactersIn: " \u{3000}"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard parts.count >= 2, isJapaneseNamePart(parts[0]) else { return [line] }

        if parts.count >= 3,
           isJapaneseNamePart(parts[1]) {
            let company = parts.dropFirst(2).joined(separator: "")
            if FieldDetector.isCompany(company) {
                return makeSplitLines(name: "\(parts[0]) \(parts[1])", company: company, source: line)
            }
        }

        let second = parts[1]
        guard let legalRange = earliestLegalEntityRange(in: second),
              legalRange.lowerBound > second.startIndex else {
            return [line]
        }
        let firstName = String(second[..<legalRange.lowerBound])
        let company = String(second[legalRange.lowerBound...]) + parts.dropFirst(2).joined()
        guard isJapaneseNamePart(firstName), FieldDetector.isCompany(company) else { return [line] }

        return makeSplitLines(name: "\(parts[0]) \(firstName)", company: company, source: line)
    }

    private func makeSplitLines(name: String, company: String, source: RecognizedLine) -> [RecognizedLine] {
        [
            RecognizedLine(
                text: name,
                boundingBox: source.boundingBox,
                confidence: source.confidence,
                textDirection: source.textDirection
            ),
            RecognizedLine(
                text: company,
                boundingBox: source.boundingBox,
                confidence: source.confidence,
                textDirection: source.textDirection
            ),
        ]
    }

    private func earliestLegalEntityRange(in text: String) -> Range<String.Index>? {
        LegalEntityTerms.allDetectionTerms
            .compactMap { text.range(of: $0) }
            .min { lhs, rhs in
                lhs.lowerBound < rhs.lowerBound
            }
    }

    private func isJapaneseNamePart(_ text: String) -> Bool {
        let stripped = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...4).contains(stripped.count) else { return false }
        guard stripped.unicodeScalars.allSatisfy({ scalar in
            (0x3040...0x30FF).contains(scalar.value)
                || (0x4E00...0x9FFF).contains(scalar.value)
        }) else { return false }
        return !FieldDetector.companySuffixes.contains { stripped.contains($0) }
            && !FieldDetector.departmentSuffixes.contains { stripped.contains($0) }
            && !FieldDetector.jobTitleKeywords.contains { stripped.contains($0) }
    }
}
