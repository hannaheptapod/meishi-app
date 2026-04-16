import Testing
import CoreGraphics
@testable import eMeishi

// MARK: - CardFieldClassifier テスト

struct CardFieldClassifierTests {

    let classifier = CardFieldClassifier()

    // MARK: メール抽出

    @Test func classifiesEmail() {
        let result = classifier.classify(lines: [makeLine("test@example.com")])
        #expect(result.email == "test@example.com")
    }

    @Test func classifiesEmailWithPrefix() {
        let result = classifier.classify(lines: [makeLine("Mail: info@company.co.jp")])
        #expect(result.email == "info@company.co.jp")
    }

    // MARK: 電話番号抽出

    @Test func classifiesMobilePhone() {
        let result = classifier.classify(lines: [makeLine("090-1234-5678")])
        #expect(result.phones.contains("090-1234-5678"))
    }

    @Test func classifiesFixedLinePhone() {
        let result = classifier.classify(lines: [makeLine("03-1234-5678")])
        #expect(!result.phones.isEmpty)
    }

    @Test func classifiesMultiplePhones() {
        let lines = [makeLine("090-1234-5678"), makeLine("03-9876-5432")]
        let result = classifier.classify(lines: lines)
        #expect(result.phones.count == 2)
    }

    // MARK: URL抽出

    @Test func classifiesHttpsURL() {
        let result = classifier.classify(lines: [makeLine("https://www.example.com")])
        #expect(result.website == "https://www.example.com")
    }

    @Test func classifiesWWWURL() {
        let result = classifier.classify(lines: [makeLine("www.example.com")])
        #expect(result.website == "www.example.com")
    }

    // MARK: 住所抽出

    @Test func classifiesAddressWithPostalCode() {
        let result = classifier.classify(lines: [makeLine("〒150-0001 東京都渋谷区神宮前1-2-3")])
        #expect(result.address.contains("150"))
    }

    @Test func classifiesAddressWithPrefecture() {
        let result = classifier.classify(lines: [makeLine("大阪府大阪市中央区1-1")])
        #expect(result.address == "大阪府大阪市中央区1-1")
    }

    // MARK: 会社名抽出

    @Test func classifiesKabushikiKaisha() {
        let result = classifier.classify(lines: [makeLine("株式会社テスト")])
        #expect(result.company == "株式会社テスト")
    }

    @Test func classifiesIncCompany() {
        let result = classifier.classify(lines: [makeLine("Test Inc.")])
        #expect(result.company == "Test Inc.")
    }

    @Test func classifiesLLCCompany() {
        let result = classifier.classify(lines: [makeLine("Example LLC")])
        #expect(result.company == "Example LLC")
    }

    // MARK: 部署抽出

    @Test func classifiesDepartmentBu() {
        let result = classifier.classify(lines: [makeLine("営業部")])
        #expect(result.department == "営業部")
    }

    @Test func classifiesDepartmentKa() {
        let result = classifier.classify(lines: [makeLine("第一営業課")])
        #expect(result.department == "第一営業課")
    }

    // MARK: 役職抽出

    @Test func classifiesTitleBuchoTitle() {
        // 「部長」は2文字のためisJobTitleでは検出されないが、複合語は検出される
        let result = classifier.classify(lines: [makeLine("営業部長")])
        #expect(result.title == "営業部長")
    }

    @Test func classifiesTitleCEO() {
        let result = classifier.classify(lines: [makeLine("CEO")])
        #expect(result.title == "CEO")
    }

    @Test func classifiesTitleDirector() {
        let result = classifier.classify(lines: [makeLine("Director")])
        #expect(result.title == "Director")
    }

    // MARK: 氏名抽出

    @Test func classifiesNameWithHalfWidthSpace() {
        let lines = [makeLine("山田 太郎", midX: 0.5, midY: 0.75, height: 0.08)]
        let result = classifier.classify(lines: lines)
        #expect(result.lastName  == "山田")
        #expect(result.firstName == "太郎")
    }

    @Test func classifiesNameWithFullWidthSpace() {
        let lines = [makeLine("山田\u{3000}太郎", midX: 0.5, midY: 0.75, height: 0.08)]
        let result = classifier.classify(lines: lines)
        #expect(result.lastName  == "山田")
        #expect(result.firstName == "太郎")
    }

    // MARK: 複合テスト

    @Test func classifiesFullBusinessCard() {
        let lines = [
            makeLine("山田 太郎",       midX: 0.5, midY: 0.80, height: 0.08),
            makeLine("株式会社テスト"),
            makeLine("営業部"),
            makeLine("営業部長"),
            makeLine("090-1234-5678"),
            makeLine("yamada@test.co.jp"),
            makeLine("https://test.co.jp"),
            makeLine("東京都渋谷区1-2-3"),
        ]
        let result = classifier.classify(lines: lines)
        #expect(result.lastName  == "山田")
        #expect(result.firstName == "太郎")
        #expect(result.company   == "株式会社テスト")
        #expect(result.department == "営業部")
        #expect(result.title     == "営業部長")
        #expect(result.phones.contains("090-1234-5678"))
        #expect(result.email     == "yamada@test.co.jp")
        #expect(result.website   == "https://test.co.jp")
        #expect(result.address   == "東京都渋谷区1-2-3")
    }
}
