import Testing
@testable import eMeishi

// ContactPatternExtractor は正規表現ベースの純ロジックのため
// CoreData / 環境依存は不要。

// MARK: - extractEmail

struct ContactPatternExtractorEmailTests {

    @Test func extractsSimpleEmail() {
        #expect(ContactPatternExtractor.extractEmail(from: "foo@example.com") == "foo@example.com")
    }

    @Test func extractsFromJapaneseMixedText() {
        // 日本語混在テキストからも英字メールを抽出できる
        let text = "メール: test@ex.jp 送信してください"
        #expect(ContactPatternExtractor.extractEmail(from: text) == "test@ex.jp")
    }

    @Test func extractsEmailWithPlusAndDot() {
        let text = "first.last+tag@sub.example.co.jp"
        #expect(ContactPatternExtractor.extractEmail(from: text) == "first.last+tag@sub.example.co.jp")
    }

    @Test func returnsFirstEmailWhenMultiple() {
        // 複数ある場合は先頭のみ
        let text = "a@first.com もう一つ b@second.com"
        #expect(ContactPatternExtractor.extractEmail(from: text) == "a@first.com")
    }

    @Test func returnsNilForSingleCharTLD() {
        // TLD が 1 文字はマッチしない（`[A-Za-z]{2,}` 指定）
        #expect(ContactPatternExtractor.extractEmail(from: "a@b.c") == nil)
    }

    @Test func returnsNilWhenNoAtSign() {
        #expect(ContactPatternExtractor.extractEmail(from: "no email here") == nil)
    }
}

// MARK: - extractPhone

struct ContactPatternExtractorPhoneTests {

    @Test func extractsMobilePhone() {
        #expect(ContactPatternExtractor.extractPhone(from: "090-1234-5678") == "090-1234-5678")
    }

    @Test func extractsFixedLinePhone() {
        #expect(ContactPatternExtractor.extractPhone(from: "03-1234-5678") == "03-1234-5678")
    }

    @Test func extractsTollFreePhone() {
        // 末尾 4 桁が必要な正規表現のため、0120-XX-XXXX 形式を使用
        #expect(ContactPatternExtractor.extractPhone(from: "0120-12-3456") == "0120-12-3456")
    }

    @Test func extractsInternationalFormatWithHyphen() {
        #expect(ContactPatternExtractor.extractPhone(from: "+81-90-1234-5678") == "+81-90-1234-5678")
    }

    @Test func extractsInternationalFormatWithSpace() {
        #expect(ContactPatternExtractor.extractPhone(from: "+81 90 1234 5678") == "+81 90 1234 5678")
    }

    @Test func extractsWithoutHyphen() {
        #expect(ContactPatternExtractor.extractPhone(from: "09012345678") == "09012345678")
    }

    @Test func extractsFromTextContext() {
        // 前後にテキストがあっても本体を抽出
        let text = "TEL: 03-1234-5678 (代表)"
        #expect(ContactPatternExtractor.extractPhone(from: text) == "03-1234-5678")
    }

    @Test func returnsFirstPhoneWhenMultiple() {
        let text = "090-1111-1111 / 03-2222-2222"
        #expect(ContactPatternExtractor.extractPhone(from: text) == "090-1111-1111")
    }

    @Test func shortFormMatchesCurrentSpec() {
        // 正規表現 `\d{1,4}` で最短ケースもマッチする現在の仕様
        // `0\d-\d-\d{4}` = 最短 `0X-X-XXXX`（例: 01-2-3456）
        #expect(ContactPatternExtractor.extractPhone(from: "01-2-3456") != nil)
    }

    @Test func returnsNilForNonJapaneseFormat() {
        // 先頭が `0` でも `+81` でもない形式はマッチしない
        #expect(ContactPatternExtractor.extractPhone(from: "(555) 123-4567") == nil)
    }

    @Test func returnsNilForTwoGroupNumber() {
        // 2 グループだけの数字列（0 始まりでも）はマッチしない
        #expect(ContactPatternExtractor.extractPhone(from: "123-4567") == nil)
    }
}

// MARK: - extractURL

struct ContactPatternExtractorURLTests {

    @Test func extractsHttpsURL() {
        #expect(ContactPatternExtractor.extractURL(from: "https://example.com") == "https://example.com")
    }

    @Test func extractsHttpURL() {
        #expect(ContactPatternExtractor.extractURL(from: "http://example.com") == "http://example.com")
    }

    @Test func extractsWWWFallback() {
        // http(s) が無い場合は www. フォールバック
        #expect(ContactPatternExtractor.extractURL(from: "www.example.com") == "www.example.com")
    }

    @Test func prefersHttpsOverWWW() {
        // https パターンが先に試行される
        let text = "https://first.com www.second.com"
        #expect(ContactPatternExtractor.extractURL(from: text) == "https://first.com")
    }

    @Test func returnsNilWhenNoURL() {
        #expect(ContactPatternExtractor.extractURL(from: "ここにURLはない") == nil)
    }
}

// MARK: - firstMatch / matches ヘルパー

struct ContactPatternExtractorHelperTests {

    @Test func firstMatchReturnsMatchedSubstring() {
        let result = ContactPatternExtractor.firstMatch(pattern: #"\d+"#, in: "abc 123 def 456")
        #expect(result == "123")
    }

    @Test func firstMatchReturnsNilWhenNoMatch() {
        #expect(ContactPatternExtractor.firstMatch(pattern: #"\d+"#, in: "no digits here") == nil)
    }

    @Test func firstMatchReturnsNilForInvalidPattern() {
        // 不正な正規表現は `try?` で捕捉され nil を返す
        #expect(ContactPatternExtractor.firstMatch(pattern: "[invalid", in: "text") == nil)
    }

    @Test func matchesReturnsTrueWhenPatternFound() {
        #expect(ContactPatternExtractor.matches(pattern: #"\d+"#, in: "abc 123") == true)
    }

    @Test func matchesReturnsFalseWhenPatternNotFound() {
        #expect(ContactPatternExtractor.matches(pattern: #"\d+"#, in: "no digits") == false)
    }

    @Test func matchesReturnsFalseForInvalidPattern() {
        // 不正な正規表現は false を返す
        #expect(ContactPatternExtractor.matches(pattern: "[invalid", in: "text") == false)
    }
}
