import Testing
@testable import eMeishi

// MARK: - メールアドレス抽出

@MainActor
struct ContactPatternExtractorEmailTests {

    @Test func extractsStandardEmail() {
        let result = ContactPatternExtractor.extractEmail(from: "連絡先: user@example.com まで")
        #expect(result == "user@example.com")
    }

    @Test func extractsPlusTagEmail() {
        let result = ContactPatternExtractor.extractEmail(from: "user+tag@example.co.jp")
        #expect(result == "user+tag@example.co.jp")
    }

    @Test func extractsFirstEmailWhenMultiple() {
        let result = ContactPatternExtractor.extractEmail(from: "a@foo.com b@bar.com")
        #expect(result == "a@foo.com")
    }

    @Test func returnsNilForNoEmail() {
        #expect(ContactPatternExtractor.extractEmail(from: "電話: 03-1234-5678") == nil)
    }

    @Test func returnsNilForEmptyString() {
        #expect(ContactPatternExtractor.extractEmail(from: "") == nil)
    }
}

// MARK: - 電話番号抽出

@MainActor
struct ContactPatternExtractorPhoneTests {

    @Test func extractsHyphenatedLocalNumber() {
        let result = ContactPatternExtractor.extractPhone(from: "TEL: 03-1234-5678")
        #expect(result == "03-1234-5678")
    }

    @Test func extractsMobileNumber() {
        let result = ContactPatternExtractor.extractPhone(from: "携帯: 090-1234-5678")
        #expect(result == "090-1234-5678")
    }

    @Test func extractsInternationalPrefix() {
        let result = ContactPatternExtractor.extractPhone(from: "+81-3-1234-5678")
        #expect(result != nil)
    }

    @Test func returnsNilForNoPhone() {
        #expect(ContactPatternExtractor.extractPhone(from: "mail@example.com") == nil)
    }
}

// MARK: - URL 抽出

@MainActor
struct ContactPatternExtractorURLTests {

    @Test func extractsHttpsURL() {
        let result = ContactPatternExtractor.extractURL(from: "詳細は https://example.com/path を参照")
        #expect(result == "https://example.com/path")
    }

    @Test func extractsHttpURL() {
        let result = ContactPatternExtractor.extractURL(from: "http://old.example.com")
        #expect(result == "http://old.example.com")
    }

    @Test func extractsWwwURLWhenNoHttps() {
        let result = ContactPatternExtractor.extractURL(from: "www.example.com をご覧ください")
        #expect(result == "www.example.com")
    }

    @Test func prefersHttpsOverWww() {
        let result = ContactPatternExtractor.extractURL(from: "https://secure.com www.other.com")
        #expect(result == "https://secure.com")
    }

    @Test func returnsNilForNoURL() {
        #expect(ContactPatternExtractor.extractURL(from: "名刺 03-1234-5678") == nil)
    }
}

// MARK: - firstMatch / matches

@MainActor
struct ContactPatternExtractorMatchTests {

    @Test func firstMatchReturnsMatchedSubstring() {
        let result = ContactPatternExtractor.firstMatch(pattern: #"\d+"#, in: "abc123def456")
        #expect(result == "123")
    }

    @Test func firstMatchReturnsNilForInvalidPattern() {
        let result = ContactPatternExtractor.firstMatch(pattern: "[invalid", in: "abc")
        #expect(result == nil)
    }

    @Test func firstMatchReturnsNilForNoMatch() {
        let result = ContactPatternExtractor.firstMatch(pattern: #"\d+"#, in: "abc")
        #expect(result == nil)
    }

    @Test func matchesReturnsTrueWhenFound() {
        #expect(ContactPatternExtractor.matches(pattern: #"\d+"#, in: "abc123") == true)
    }

    @Test func matchesReturnsFalseWhenNotFound() {
        #expect(ContactPatternExtractor.matches(pattern: #"\d+"#, in: "abc") == false)
    }

    @Test func matchesReturnsFalseForInvalidPattern() {
        #expect(ContactPatternExtractor.matches(pattern: "[invalid", in: "abc") == false)
    }
}
