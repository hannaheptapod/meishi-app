import CoreGraphics
import Testing
@testable import eMeishi

@MainActor
struct CardFieldResolutionTests {

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

        #expect(result.automaticValues[.lastName] == nil)
        #expect(result.automaticValues[.firstName] == nil)
    }

    @Test func initialismIsCandidateButLongUppercaseWordIsUnresolved() {
        #expect(NameReadingGenerator.generateCompanyReading(from: "T") == "てぃー")
        #expect(NameReadingGenerator.generateCompanyReading(from: "NTTデータ") == "えぬてぃーてぃーでーた")
        #expect(NameReadingGenerator.generateCompanyReading(from: "SONY") == "")
        #expect(NameReadingGenerator.generateCompanyReading(from: "Apple Japan") == "")
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
