import Testing
@testable import eMeishi

// MARK: - 法人格（LegalEntityTerms）テスト

struct LegalEntityTermsTests {

    // MARK: - stripKanji

    @Test func stripKanjiPrefix() {
        // 前株
        #expect(LegalEntityTerms.stripKanji(from: "株式会社テスト") == "テスト")
        #expect(LegalEntityTerms.stripKanji(from: "合同会社テスト") == "テスト")
        #expect(LegalEntityTerms.stripKanji(from: "有限会社テスト") == "テスト")
        #expect(LegalEntityTerms.stripKanji(from: "一般社団法人テスト") == "テスト")
    }

    @Test func stripKanjiSuffix() {
        // 後株
        #expect(LegalEntityTerms.stripKanji(from: "テスト株式会社") == "テスト")
        #expect(LegalEntityTerms.stripKanji(from: "テスト合同会社") == "テスト")
        #expect(LegalEntityTerms.stripKanji(from: "テスト有限会社") == "テスト")
    }

    @Test func stripKanjiAbbreviated() {
        // 略称形
        #expect(LegalEntityTerms.stripKanji(from: "(株)テスト") == "テスト")
        #expect(LegalEntityTerms.stripKanji(from: "テスト(株)") == "テスト")
        #expect(LegalEntityTerms.stripKanji(from: "（株）テスト") == "テスト")
        #expect(LegalEntityTerms.stripKanji(from: "(有)テスト") == "テスト")
        #expect(LegalEntityTerms.stripKanji(from: "テスト（有）") == "テスト")
    }

    @Test func stripKanjiEnglish() {
        #expect(LegalEntityTerms.stripKanji(from: "Test Inc.") == "Test")
        #expect(LegalEntityTerms.stripKanji(from: "Test LLC") == "Test")
        #expect(LegalEntityTerms.stripKanji(from: "Test Co., Ltd.") == "Test")
        #expect(LegalEntityTerms.stripKanji(from: "Test GmbH") == "Test")
    }

    @Test func stripKanjiPassthrough() {
        // 法人格なしはそのまま
        #expect(LegalEntityTerms.stripKanji(from: "テスト商事") == "テスト商事")
        #expect(LegalEntityTerms.stripKanji(from: "ABC") == "ABC")
        #expect(LegalEntityTerms.stripKanji(from: "") == "")
    }

    // MARK: - stripReading

    @Test func stripReadingPrefix() {
        #expect(LegalEntityTerms.stripReading(from: "かぶしきがいしゃてすと") == "てすと")
        #expect(LegalEntityTerms.stripReading(from: "ごうどうがいしゃてすと") == "てすと")
    }

    @Test func stripReadingSuffix() {
        #expect(LegalEntityTerms.stripReading(from: "てすとかぶしきがいしゃ") == "てすと")
    }

    @Test func stripReadingPassthrough() {
        #expect(LegalEntityTerms.stripReading(from: "てすと") == "てすと")
    }

    // MARK: - allDetectionTerms

    @Test func allDetectionTermsContainsAllTypes() {
        let terms = LegalEntityTerms.allDetectionTerms
        // 漢字
        #expect(terms.contains("株式会社"))
        #expect(terms.contains("合名会社"))
        #expect(terms.contains("医療法人"))
        // 英語
        #expect(terms.contains("Inc."))
        #expect(terms.contains("S.A."))
        #expect(terms.contains("Pty"))
        // 略称
        #expect(terms.contains("(株)"))
        #expect(terms.contains("（有）"))
    }
}
