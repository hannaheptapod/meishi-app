import Foundation
import CoreGraphics

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
        var result = ParsedCard()
        var unclassified: [RecognizedLine] = []

        print("[Classifier] === Pass1 開始 (\(lines.count)行) ===")

        // --- Pass1: パターン・キーワードで確実に判定できるフィールドを抽出 ---
        for line in lines {
            let trimmed = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }

            if result.email.isEmpty, let email = ContactPatternExtractor.extractEmail(from: trimmed) {
                result.email = email
                print("[Classifier] email: '\(trimmed)'")
            } else if let phone = ContactPatternExtractor.extractPhone(from: trimmed) {
                result.phones.append(phone)
                print("[Classifier] phone: '\(trimmed)'")
            } else if result.website.isEmpty, let url = ContactPatternExtractor.extractURL(from: trimmed) {
                result.website = url
                print("[Classifier] website: '\(trimmed)'")
            } else if result.address.isEmpty, FieldDetector.isAddress(trimmed) {
                result.address = trimmed
                print("[Classifier] address: '\(trimmed)'")
            } else if FieldDetector.isAddress(trimmed) {
                result.address += " " + trimmed
                print("[Classifier] address(追加): '\(trimmed)'")
            } else if result.company.isEmpty, FieldDetector.isCompany(trimmed) {
                result.company = trimmed.trimmingCharacters(in: .whitespaces)
                print("[Classifier] company: '\(trimmed)'")
            } else if FieldDetector.isDepartment(trimmed) {
                result.department = result.department.isEmpty
                    ? trimmed
                    : result.department + " " + trimmed
                print("[Classifier] department: '\(trimmed)'")
            } else if result.title.isEmpty, FieldDetector.isJobTitle(trimmed) {
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
                if FieldDetector.isBuildingName(t) {
                    result.address += " " + t
                    print("[Classifier] address(建物名): '\(t)'")
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
                print("[Classifier] Pass2スコア: '\(t)' = \(String(format: "%.3f", scores[idx]))")
            }
            if let bestIdx = scores.indices.max(by: { scores[$0] < scores[$1] }),
               scores[bestIdx] > 0.35 {
                let bestText = unclassified[bestIdx].text.trimmingCharacters(in: .whitespacesAndNewlines)
                print("[Classifier] 名前確定(>0.35): '\(bestText)' (score=\(String(format: "%.3f", scores[bestIdx])))")
                unclassified = NameProcessor.resolveNameFromUnclassified(&result, unclassified: unclassified)
                print("[Classifier] 名前解決後: lastName='\(result.lastName)' firstName='\(result.firstName)'")
                // フリガナ行を氏名読み仮名として取得
                if let furiganaLine = unclassified.first(where: { NameProcessor.isFuriganaLine($0) }) {
                    let rawReading = furiganaLine.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    let (lastR, firstR) = NameProcessor.splitName(rawReading)
                    result.lastNameReading = NameProcessor.normalizeToHiragana(lastR)
                    result.firstNameReading = NameProcessor.normalizeToHiragana(firstR)
                    print("[Classifier] フリガナ: lastR='\(result.lastNameReading)' firstR='\(result.firstNameReading)'")
                } else if let romajiLine = unclassified.first(where: { NameProcessor.isRomajiNameLine($0) }),
                          let romajiReading = NameProcessor.resolveRomajiReading(
                              romajiLine: romajiLine,
                              lastName: result.lastName,
                              firstName: result.firstName
                          ) {
                    result.lastNameReading = romajiReading.lastNameReading
                    result.firstNameReading = romajiReading.firstNameReading
                    print("[Classifier] ローマ字読み: lastR='\(result.lastNameReading)' firstR='\(result.firstNameReading)'")
                }
                unclassified.removeAll { NameProcessor.isFuriganaLine($0) }
                unclassified.removeAll { NameProcessor.isRomajiNameLine($0) }
            } else {
                print("[Classifier] 名前スコア不足 → LLMに委譲")
            }
        }

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
}
