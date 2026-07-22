import CoreGraphics
import Testing
@testable import eMeishi

@MainActor
struct CardFieldResolutionTests {
    @Test func emailCorrectsIncorrectOCRNameBoundary() {
        let corrected = NameReadingGenerator.correctedNameSplitUsingEmail(
            lastName: "山田花",
            firstName: "子",
            email: "yamada.hanako@example.invalid"
        )

        #expect(corrected?.lastName == "山田")
        #expect(corrected?.firstName == "花子")
    }

    @Test func resolvesFullCardWithoutReusingSemanticSpans() {
        let lines = [
            makeLine("株式会社テスト", midY: 0.85, height: 0.05),
            makeLine("営業部", midY: 0.70, height: 0.04),
            makeLine("営業部長", midY: 0.62, height: 0.04),
            makeLine("山田 太郎", midY: 0.52, height: 0.08),
            makeLine("090-1234-5678", midY: 0.20, height: 0.03),
            makeLine("yamada@example.com", midY: 0.14, height: 0.03),
        ]

        let result = CardFieldClassifier().classifyStructuredFields(lines: lines)

        #expect(result.parsed.company == "株式会社テスト")
        #expect(result.parsed.department == "営業部")
        #expect(result.parsed.title == "営業部長")
        #expect(result.parsed.lastName == "山田")
        #expect(result.parsed.firstName == "太郎")
        #expect(result.parsed.phones == ["090-1234-5678"])
        #expect(result.parsed.email == "yamada@example.com")
        let semanticIDs = result.assignments
            .filter { [.personName, .company, .department, .title].contains($0.field) }
            .flatMap(\.spanIDs)
        #expect(Set(semanticIDs).count == semanticIDs.count)
    }

    @Test func combinedContactLineKeepsBothEmailAndPhone() {
        let lines = [
            makeLine("Email: sample@example.invalid Tel: 03-1234-5678", midY: 0.20, height: 0.03),
        ]

        let result = CardFieldClassifier().classifyStructuredFields(lines: lines)

        #expect(result.parsed.email == "sample@example.invalid")
        #expect(result.parsed.phones == ["03-1234-5678"])
    }

    @Test func validatorRejectsFieldOutsideCandidateSet() {
        let span = CardTextSpan(
            sourceLineIndex: 0,
            text: "山田 太郎",
            boundingBox: CGRect(x: 0.2, y: 0.5, width: 0.3, height: 0.08),
            ocrConfidence: 0.99,
            textDirection: .leftToRight,
            readingOrder: 0
        )
        let candidate = FieldCandidate(
            spanIDs: [span.id],
            field: .personName,
            value: span.text,
            score: 0.45,
            evidence: [.nameShape]
        )
        let request = CardFieldResolutionRequest(
            spans: [span],
            candidates: [candidate],
            assignments: [],
            ambiguousSpanIDs: [span.id]
        )

        let invalid = CardFieldResolver().validate(
            decisions: [CardFieldDecision(spanID: span.id, field: .company)],
            request: request
        )
        let valid = CardFieldResolver().validate(
            decisions: [CardFieldDecision(spanID: span.id, field: .personName)],
            request: request
        )

        #expect(invalid.isEmpty)
        #expect(valid.first?.value == "山田 太郎")
    }

    @Test func nearbyPrintedKanaIsAutomaticNameReading() {
        var parsed = CardFieldClassifier.ParsedCard()
        parsed.lastName = "山田"
        parsed.firstName = "太郎"
        let name = makeSpan(id: "name", text: "山田 太郎", y: 0.60, height: 0.08)
        let kana = makeSpan(id: "kana", text: "やまだ たろう", y: 0.70, height: 0.035)
        let assignment = FieldAssignment(
            spanIDs: [name.id], field: .personName, value: name.text,
            confidence: .high, source: .resolver
        )

        let result = NameReadingGenerator.resolveReadings(
            parsed: parsed,
            spans: [name, kana],
            assignments: [assignment]
        )

        #expect(result.automaticValues[.lastName] == "やまだ")
        #expect(result.automaticValues[.firstName] == "たろう")
        #expect(result.candidates(for: .lastName).first?.source == .printedKana)
    }

    @Test func distantKanaDoesNotBecomeAutomaticNameReading() {
        var parsed = CardFieldClassifier.ParsedCard()
        parsed.lastName = "山田"
        parsed.firstName = "太郎"
        let name = makeSpan(id: "name", text: "山田 太郎", y: 0.80, height: 0.08)
        let product = makeSpan(id: "product", text: "サンプルサービス", y: 0.10, height: 0.03)
        let assignment = FieldAssignment(
            spanIDs: [name.id], field: .personName, value: name.text,
            confidence: .high, source: .resolver
        )

        let result = NameReadingGenerator.resolveReadings(
            parsed: parsed,
            spans: [name, product],
            assignments: [assignment]
        )

        #expect(result.automaticValues[.lastName] == "やまだ")
        #expect(result.automaticValues[.firstName] == "たろう")
        #expect(!result.candidates.contains { $0.source == .printedKana })
    }

    @Test func nearbyJobTitleDoesNotBecomeAutomaticNameReading() {
        var parsed = CardFieldClassifier.ParsedCard()
        parsed.lastName = "山田"
        parsed.firstName = "花子"
        let name = makeSpan(id: "name", text: "山田 花子", y: 0.60, height: 0.08)
        let title = makeSpan(id: "title", text: "アソシエイト", y: 0.67, height: 0.035)
        let assignment = FieldAssignment(
            spanIDs: [name.id], field: .personName, value: name.text,
            confidence: .high, source: .resolver
        )

        let result = NameReadingGenerator.resolveReadings(
            parsed: parsed,
            spans: [name, title],
            assignments: [assignment]
        )

        #expect(result.automaticValues[.lastName] == "やまだ")
        #expect(result.automaticValues[.firstName] == "はなこ")
        #expect(!result.candidates.contains { $0.source == .printedKana })
    }

    @Test func emailWithSurnameEvidenceAutoFillsDifficultGivenName() {
        var parsed = CardFieldClassifier.ParsedCard()
        parsed.lastName = "山田"
        parsed.firstName = "大翔"
        parsed.email = "haruto.yamada@example.invalid"
        let name = makeSpan(id: "name", text: "山田 大翔", y: 0.60, height: 0.08)
        let assignment = FieldAssignment(
            spanIDs: [name.id], field: .personName, value: name.text,
            confidence: .high, source: .resolver
        )

        let result = NameReadingGenerator.resolveReadings(
            parsed: parsed,
            spans: [name],
            assignments: [assignment]
        )

        #expect(result.automaticValues[.lastName] == "やまだ")
        #expect(result.automaticValues[.firstName] == "はると")
    }

    @Test func validatedEmailReadingOverridesUnrelatedNearbyKana() {
        var parsed = CardFieldClassifier.ParsedCard()
        parsed.lastName = "山田"
        parsed.firstName = "花子"
        parsed.email = "hanako.yamada@example.invalid"
        let name = makeSpan(id: "name", text: "山田 花子", y: 0.60, height: 0.08)
        let unrelated = makeSpan(id: "unrelated", text: "アソシエイト", y: 0.67, height: 0.035)
        let assignment = FieldAssignment(
            spanIDs: [name.id], field: .personName, value: name.text,
            confidence: .high, source: .resolver
        )

        let result = NameReadingGenerator.resolveReadings(
            parsed: parsed,
            spans: [name, unrelated],
            assignments: [assignment]
        )

        #expect(result.automaticValues[.lastName] == "やまだ")
        #expect(result.automaticValues[.firstName] == "はなこ")
        #expect(result.candidates(for: .lastName).first?.source == .email)
    }

    @Test func initialismIsCandidateButLongUppercaseWordIsUnresolved() {
        #expect(NameReadingGenerator.generateCompanyReading(from: "T") == "てぃー")
        #expect(NameReadingGenerator.generateCompanyReading(from: "NTTデータ") == "えぬてぃーてぃーでーた")
        #expect(NameReadingGenerator.generateCompanyReading(from: "SONY") == "")
        #expect(NameReadingGenerator.generateCompanyReading(from: "Apple Japan") == "")
    }

    @Test func numeralAndSymbolFragmentsNeverBecomePersonName() {
        let lines = [
            makeLine("六", midX: 0.62, midY: 0.72, width: 0.04, height: 0.12, textDirection: .topToBottom),
            makeLine("〇五", midX: 0.56, midY: 0.70, width: 0.04, height: 0.12, textDirection: .topToBottom),
            makeLine("株式会社架空商事", midX: 0.80, midY: 0.65, width: 0.05, height: 0.48, textDirection: .topToBottom),
        ]

        let result = CardFieldClassifier().classifyStructuredFields(lines: lines)

        #expect(result.parsed.lastName.isEmpty)
        #expect(result.parsed.firstName.isEmpty)
        #expect(!result.candidates.contains { $0.field == .personName })
    }

    @Test func adjacentVerticalNameColumnsResolveAsOneName() {
        let lines = [
            makeLine("架空", midX: 0.58, midY: 0.66, width: 0.05, height: 0.18, textDirection: .topToBottom),
            makeLine("例名", midX: 0.48, midY: 0.66, width: 0.05, height: 0.18, textDirection: .topToBottom),
            makeLine("株式会社架空商事", midX: 0.80, midY: 0.65, width: 0.05, height: 0.48, textDirection: .topToBottom),
        ]

        let result = CardFieldClassifier().classifyStructuredFields(lines: lines)

        #expect(result.parsed.lastName == "架空")
        #expect(result.parsed.firstName == "例名")
        #expect(result.assignments.contains {
            $0.field == .personName && $0.spanIDs.count == 2
        })
    }

    @Test func nearbyLargeKanaColumnIsNotCompanyReadingAnnotation() {
        var parsed = CardFieldClassifier.ParsedCard()
        parsed.company = "株式会社架空商事"
        let company = CardTextSpan(
            id: "company", sourceLineIndex: 0, text: parsed.company,
            boundingBox: CGRect(x: 0.72, y: 0.30, width: 0.05, height: 0.45),
            ocrConfidence: 0.99, textDirection: .topToBottom, readingOrder: 0
        )
        let unrelated = CardTextSpan(
            id: "unrelated", sourceLineIndex: 1, text: "かくうしょうひん",
            boundingBox: CGRect(x: 0.64, y: 0.34, width: 0.06, height: 0.38),
            ocrConfidence: 0.99, textDirection: .topToBottom, readingOrder: 1
        )
        let assignment = FieldAssignment(
            spanIDs: [company.id], field: .company, value: company.text,
            confidence: .high, source: .resolver
        )

        let result = NameReadingGenerator.resolveReadings(
            parsed: parsed,
            spans: [company, unrelated],
            assignments: [assignment]
        )

        #expect(result.automaticValues[.company] == nil)
    }

    private func makeSpan(id: String, text: String, y: CGFloat, height: CGFloat) -> CardTextSpan {
        CardTextSpan(
            id: id,
            sourceLineIndex: 0,
            text: text,
            boundingBox: CGRect(x: 0.25, y: y, width: 0.5, height: height),
            ocrConfidence: 0.99,
            textDirection: .leftToRight,
            readingOrder: 0
        )
    }
}
