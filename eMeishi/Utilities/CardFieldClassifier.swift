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
        var spans: [CardTextSpan]
        var candidates: [FieldCandidate]
        var assignments: [FieldAssignment]
        var ambiguousSpanIDs: [String]

        init(
            parsed: ParsedCard,
            unclassifiedLines: [String],
            spans: [CardTextSpan] = [],
            candidates: [FieldCandidate] = [],
            assignments: [FieldAssignment] = [],
            ambiguousSpanIDs: [String] = []
        ) {
            self.parsed = parsed
            self.unclassifiedLines = unclassifiedLines
            self.spans = spans
            self.candidates = candidates
            self.assignments = assignments
            self.ambiguousSpanIDs = ambiguousSpanIDs
        }
    }

    func classifyStructuredFields(lines: [RecognizedLine]) -> StructuredFieldsResult {
        let spans = makeSpans(from: lines)
        let candidates = makeCandidates(spans: spans)
        let resolver = CardFieldResolver()
        let assignments = resolver.resolve(spans: spans, candidates: candidates)
        let ambiguous = resolver.ambiguousSpanIDs(candidates: candidates, assignments: assignments)
        var parsed = makeParsedCard(assignments: assignments)
        let readings = NameReadingGenerator.resolveReadings(
            parsed: parsed,
            spans: spans,
            assignments: assignments
        )
        parsed.lastNameReading = readings.automaticValues[.lastName] ?? ""
        parsed.firstNameReading = readings.automaticValues[.firstName] ?? ""
        parsed.companyReading = readings.automaticValues[.company] ?? ""
        let spanByID = Dictionary(uniqueKeysWithValues: spans.map { ($0.id, $0) })
        let unresolved = ambiguous.compactMap { spanByID[$0]?.text }

        return StructuredFieldsResult(
            parsed: parsed,
            unclassifiedLines: unresolved,
            spans: spans,
            candidates: candidates,
            assignments: assignments,
            ambiguousSpanIDs: ambiguous
        )
    }

    // MARK: - 分類エントリポイント（従来API: 全フィールド分類）

    func classify(lines: [RecognizedLine]) -> ParsedCard {
        classifyStructuredFields(lines: lines).parsed
    }

    private func makeSpans(from lines: [RecognizedLine]) -> [CardTextSpan] {
        lines.enumerated().flatMap { sourceIndex, line in
            splitCombinedNameCompanyLine(line).enumerated().compactMap { fragmentIndex, fragment in
                let text = fragment.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { return nil }
                return CardTextSpan(
                    sourceLineIndex: sourceIndex,
                    fragmentIndex: fragmentIndex,
                    text: text,
                    boundingBox: fragment.boundingBox,
                    ocrConfidence: fragment.confidence,
                    textDirection: fragment.textDirection,
                    readingOrder: sourceIndex
                )
            }
        }
    }

    private func makeCandidates(spans: [CardTextSpan]) -> [FieldCandidate] {
        let lines = spans.map {
            RecognizedLine(text: $0.text, boundingBox: $0.boundingBox, confidence: $0.ocrConfidence, textDirection: $0.textDirection)
        }
        var result: [FieldCandidate] = []

        for (index, span) in spans.enumerated() {
            let text = span.text
            if let email = ContactPatternExtractor.extractEmail(from: text) {
                result.append(candidate(span, field: .email, value: email, score: 0.99, evidence: [.contactPattern]))
            }
            if let phone = ContactPatternExtractor.extractPhone(from: text) {
                result.append(candidate(span, field: .phone, value: phone, score: 0.99, evidence: [.contactPattern]))
            }
            if let url = ContactPatternExtractor.extractURL(from: text) {
                result.append(candidate(span, field: .website, value: url, score: 0.98, evidence: [.contactPattern]))
            }
            if FieldDetector.isAddress(text) {
                result.append(candidate(span, field: .address, value: text, score: 0.92, evidence: [.contactPattern]))
            }
            let isCompany = FieldDetector.isCompany(text)
            let isDepartment = FieldDetector.isDepartment(text)
            let isTitle = FieldDetector.isJobTitle(text)

            if isCompany {
                result.append(candidate(span, field: .company, value: text, score: 0.96, evidence: [.legalEntity]))
            } else if FieldDetector.companySuffixes.contains(where: { text.contains($0) }) {
                result.append(candidate(span, field: .company, value: text, score: 0.72, evidence: [.organizationKeyword]))
            }
            if isDepartment {
                result.append(candidate(span, field: .department, value: text, score: 0.88, evidence: [.organizationKeyword]))
            }
            if isTitle {
                result.append(candidate(span, field: .title, value: text, score: 0.90, evidence: [.titleKeyword]))
            }

            let nameScore = NameProcessor.personNameScore(for: lines[index], candidates: lines)
            // 組織・役職の明示語を氏名候補へ重複登録すると、単独行で氏名が先に
            // span を消費する。意味が確定する語は氏名候補から除外する。
            if !isCompany && !isDepartment && !isTitle && nameScore >= 0.15 {
                var evidence: Set<FieldEvidence> = [.nameShape]
                if lines.contains(where: { other in
                    other.boundingBox != lines[index].boundingBox
                        && (NameProcessor.isFuriganaLine(other) || NameProcessor.isRomajiNameLine(other))
                        && spatiallyRelated(lines[index], other)
                }) {
                    evidence.insert(.nearbyReading)
                }
                if span.boundingBox.height > medianHeight(spans) * 1.15 {
                    evidence.insert(.relativeTypography)
                }
                result.append(candidate(span, field: .personName, value: text, score: nameScore, evidence: evidence))
            }
        }
        return result
    }

    private func makeParsedCard(assignments: [FieldAssignment]) -> ParsedCard {
        var result = ParsedCard()
        for assignment in assignments {
            switch assignment.field {
            case .personName:
                let split = NameProcessor.splitName(assignment.value)
                result.lastName = split.lastName
                result.firstName = split.firstName
            case .company: result.company = assignment.value
            case .department: result.department = assignment.value
            case .title: result.title = assignment.value
            case .address:
                result.address = result.address.isEmpty ? assignment.value : result.address + " " + assignment.value
            case .phone: result.phones.append(assignment.value)
            case .email: if result.email.isEmpty { result.email = assignment.value }
            case .website: if result.website.isEmpty { result.website = assignment.value }
            default: break
            }
        }
        return result
    }

    private func candidate(
        _ span: CardTextSpan,
        field: CardFieldKind,
        value: String,
        score: Double,
        evidence: Set<FieldEvidence>
    ) -> FieldCandidate {
        FieldCandidate(spanIDs: [span.id], field: field, value: value, score: score, evidence: evidence)
    }

    private func medianHeight(_ spans: [CardTextSpan]) -> CGFloat {
        let values = spans.map(\.boundingBox.height).sorted()
        guard !values.isEmpty else { return 0.05 }
        return values[values.count / 2]
    }

    private func spatiallyRelated(_ lhs: RecognizedLine, _ rhs: RecognizedLine) -> Bool {
        let verticalDistance = abs(lhs.boundingBox.midY - rhs.boundingBox.midY)
        let horizontalDistance = abs(lhs.boundingBox.midX - rhs.boundingBox.midX)
        return verticalDistance <= max(lhs.boundingBox.height, rhs.boundingBox.height) * 2.5
            && horizontalDistance <= max(lhs.boundingBox.width, rhs.boundingBox.width) * 0.8 + 0.08
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
        let nonNameBusinessTerms: Set<String> = [
            "営業", "開発", "企画", "管理", "総務", "人事", "経理", "財務",
            "販売", "賃貸", "相談", "本社", "支店", "店舗", "代理", "事業",
        ]
        guard !nonNameBusinessTerms.contains(stripped) else { return false }
        guard !FieldDetector.isCompany(stripped),
              !FieldDetector.isDepartment(stripped),
              !FieldDetector.isJobTitle(stripped),
              !FieldDetector.isAddress(stripped) else {
            return false
        }
        guard stripped.unicodeScalars.allSatisfy({ scalar in
            (0x3040...0x30FF).contains(scalar.value)
                || (0x4E00...0x9FFF).contains(scalar.value)
        }) else { return false }
        return !FieldDetector.companySuffixes.contains { stripped.contains($0) }
            && !FieldDetector.departmentSuffixes.contains { stripped.contains($0) }
            && !FieldDetector.jobTitleKeywords.contains { stripped.contains($0) }
    }
}
