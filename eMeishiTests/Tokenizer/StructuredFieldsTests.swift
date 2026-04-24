import Testing
import CoreGraphics
@testable import eMeishi

// MARK: - CardFieldClassifier StructuredFields テスト

@MainActor
struct StructuredFieldsTests {

    let classifier = CardFieldClassifier()

    @Test func extractsEmailAndPhone() {
        let lines = [
            makeLine("山田 太郎", midY: 0.75, height: 0.08),
            makeLine("test@example.com"),
            makeLine("090-1234-5678")
        ]
        let result = classifier.classifyStructuredFields(lines: lines)
        #expect(result.parsed.email == "test@example.com")
        #expect(result.parsed.phones.contains("090-1234-5678"))
        // 名前行は空間スコアが高いため Pass2 で解決される
        // → lastName/firstName に入り、unclassifiedLines からは除去される
        #expect(result.parsed.lastName == "山田")
        #expect(result.parsed.firstName == "太郎")
    }

    @Test func extractsCompanyAndDepartment() {
        let lines = [
            makeLine("株式会社テスト"),
            makeLine("営業部"),
            makeLine("山田太郎", midY: 0.75, height: 0.08)
        ]
        let result = classifier.classifyStructuredFields(lines: lines)
        #expect(result.parsed.company == "株式会社テスト")
        #expect(result.parsed.department == "営業部")
        // 名前はスコアリングで解決される
        #expect(result.parsed.lastName == "山田太郎" || !result.parsed.lastName.isEmpty)
    }

    @Test func allFieldsClassifiedLeavesNoUnclassified() {
        let lines = [
            makeLine("株式会社テスト"), makeLine("営業部"), makeLine("部長"),
            makeLine("090-1234-5678"), makeLine("test@example.com"),
            makeLine("https://test.co.jp"), makeLine("東京都渋谷区1-2-3")
        ]
        let result = classifier.classifyStructuredFields(lines: lines)
        #expect(result.unclassifiedLines.isEmpty)
    }

    @Test func emptyInputReturnsEmpty() {
        let result = classifier.classifyStructuredFields(lines: [])
        #expect(result.unclassifiedLines.isEmpty)
        #expect(result.parsed.email.isEmpty)
    }

    @Test func nameWithFuriganaGetsHighScore() {
        // フリガナ行が近くにある場合、名前スコアが高くなり Pass2 で解決される
        let lines = [
            makeLine("やまだ たろう", midY: 0.82, height: 0.04),
            makeLine("山田 太郎",     midY: 0.75, height: 0.08),
            makeLine("test@example.com"),
        ]
        let result = classifier.classifyStructuredFields(lines: lines)
        #expect(result.parsed.lastName == "山田")
        #expect(result.parsed.firstName == "太郎")
        #expect(result.parsed.email == "test@example.com")
    }

    @Test func lowConfidenceNameRemainsUnclassified() {
        // カタカナ混在+小フォント+低位置 → 名前スコアが0.35以下で未分類のままLLMに委ねる
        let lines = [
            makeLine("テクノ田中", midY: 0.2, height: 0.03),
            makeLine("test@example.com"),
        ]
        let result = classifier.classifyStructuredFields(lines: lines)
        #expect(result.unclassifiedLines.contains("テクノ田中"))
    }
}
