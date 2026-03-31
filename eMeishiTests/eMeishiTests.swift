import Testing
import CoreData
import CoreGraphics
import CoreML
@testable import eMeishi

// MARK: - テスト用ヘルパー

/// テスト用インメモリ CoreData コンテキストを生成する
private func makeTestContext() -> NSManagedObjectContext {
    PersistenceController(inMemory: true).container.viewContext
}

/// テスト用 BusinessCard を生成する
private func makeCard(
    context: NSManagedObjectContext,
    lastName: String? = nil,
    lastNameReading: String? = nil,
    firstName: String? = nil,
    firstNameReading: String? = nil,
    company: String? = nil,
    companyReading: String? = nil,
    department: String? = nil,
    title: String? = nil,
    email: String? = nil,
    phone: String? = nil,
    address: String? = nil,
    website: String? = nil,
    notes: String? = nil
) -> BusinessCard {
    let card = BusinessCard(context: context)
    card.id               = UUID()
    card.lastName         = lastName
    card.lastNameReading  = lastNameReading
    card.firstName        = firstName
    card.firstNameReading = firstNameReading
    card.company          = company
    card.companyReading   = companyReading
    card.department       = department
    card.title            = title
    card.email            = email
    card.phone            = phone
    card.address          = address
    card.website          = website
    card.notes            = notes
    card.createdAt        = Date()
    card.updatedAt        = Date()
    return card
}

/// テスト用 RecognizedLine を生成する（midX/midY で中心位置を指定）
private func makeLine(
    _ text: String,
    midX: CGFloat = 0.5,
    midY: CGFloat = 0.6,
    width: CGFloat = 0.3,
    height: CGFloat = 0.05
) -> RecognizedLine {
    RecognizedLine(
        text: text,
        boundingBox: CGRect(
            x: midX - width / 2,
            y: midY - height / 2,
            width: width,
            height: height
        ),
        confidence: 1.0
    )
}

// MARK: - BusinessCard 計算プロパティ テスト

struct BusinessCardPropertiesTests {

    let context = makeTestContext()

    @Test func fullNameBothParts() {
        let card = makeCard(context: context, lastName: "山田", lastNameReading: "やまだ", firstName: "太郎", firstNameReading: "たろう")
        #expect(card.fullName == "山田 太郎")
    }

    @Test func fullNameLastOnly() {
        let card = makeCard(context: context, lastName: "山田", lastNameReading: "やまだ")
        #expect(card.fullName == "山田")
    }

    @Test func fullNameFirstOnly() {
        let card = makeCard(context: context, firstName: "太郎", firstNameReading: "たろう")
        #expect(card.fullName == "太郎")
    }

    @Test func fullNameBothNilIsEmpty() {
        let card = makeCard(context: context)
        #expect(card.fullName == "")
    }

    @Test func fullNameTrimsWhitespace() {
        let card = makeCard(context: context, lastName: "  山田  ", lastNameReading: "やまだ", firstName: "  太郎  ", firstNameReading: "たろう")
        #expect(card.fullName == "山田 太郎")
    }

    @Test func phoneListNilIsEmpty() {
        let card = makeCard(context: context)
        #expect(card.phoneList.isEmpty)
    }

    @Test func phoneListEmptyStringIsEmpty() {
        let card = makeCard(context: context, phone: "")
        #expect(card.phoneList.isEmpty)
    }

    @Test func phoneListSingle() {
        let card = makeCard(context: context, phone: "090-1234-5678")
        #expect(card.phoneList == ["090-1234-5678"])
    }

    @Test func phoneListMultiple() {
        let card = makeCard(context: context, phone: "090-1234-5678\n03-9876-5432")
        #expect(card.phoneList == ["090-1234-5678", "03-9876-5432"])
    }

    @Test func phoneListFiltersEmptyLines() {
        let card = makeCard(context: context, phone: "090-1234-5678\n\n03-9876-5432")
        #expect(card.phoneList.count == 2)
    }
}

// MARK: - DuplicateChecker 類似度テスト

struct DuplicateCheckerSimilarityTests {

    let checker = DuplicateChecker()

    @Test func identicalStrings() {
        #expect(checker.similarity("山田太郎", "山田太郎") == 1.0)
    }

    @Test func bothEmpty() {
        #expect(checker.similarity("", "") == 1.0)
    }

    @Test func oneEmpty() {
        #expect(checker.similarity("山田", "") == 0.0)
        #expect(checker.similarity("", "山田") == 0.0)
    }

    @Test func singleCharDifference() {
        // "abc" vs "aXc" → 編集距離 1、最大長 3 → similarity = 1 - 1/3
        let sim = checker.similarity("abc", "aXc")
        #expect(abs(sim - (1.0 - 1.0 / 3.0)) < 0.001)
    }

    @Test func completelyDifferentStrings() {
        let sim = checker.similarity("abc", "xyz")
        #expect(sim < 0.5)
    }

    @Test func caseInsensitive() {
        #expect(checker.similarity("ABC", "abc") == 1.0)
    }

    @Test func trailingWhitespaceTrimmed() {
        #expect(checker.similarity("山田 ", "山田") == 1.0)
    }

    @Test func partialOverlap() {
        // "山田" vs "山本" → 編集距離 1、最大長 2 → similarity = 0.5
        let sim = checker.similarity("山田", "山本")
        #expect(abs(sim - 0.5) < 0.001)
    }
}

// MARK: - DuplicateChecker 重複検出テスト

struct DuplicateCheckerFindTests {

    let context = makeTestContext()
    let checker = DuplicateChecker(threshold: 0.75)

    @Test func emptyInput() {
        #expect(checker.findDuplicates(in: []).isEmpty)
    }

    @Test func singleCard() {
        let card = makeCard(context: context, lastName: "山田", lastNameReading: "やまだ", firstName: "太郎", firstNameReading: "たろう")
        #expect(checker.findDuplicates(in: [card]).isEmpty)
    }

    @Test func identicalNamesScore1() {
        // 完全一致の名前はスコア 1.0 → 会社名が異なっても重複として検出
        let a = makeCard(context: context, lastName: "山田", lastNameReading: "やまだ", firstName: "太郎", firstNameReading: "たろう", company: "A社")
        let b = makeCard(context: context, lastName: "山田", lastNameReading: "やまだ", firstName: "太郎", firstNameReading: "たろう", company: "B社")
        let pairs = checker.findDuplicates(in: [a, b])
        #expect(pairs.count == 1)
        #expect(pairs[0].score == 1.0)
    }

    @Test func identicalCardDetected() {
        let a = makeCard(context: context, lastName: "山田", lastNameReading: "やまだ", firstName: "太郎", firstNameReading: "たろう", company: "テスト株式会社", companyReading: "てすと")
        let b = makeCard(context: context, lastName: "山田", lastNameReading: "やまだ", firstName: "太郎", firstNameReading: "たろう", company: "テスト株式会社", companyReading: "てすと")
        let pairs = checker.findDuplicates(in: [a, b])
        #expect(!pairs.isEmpty)
        #expect(pairs[0].score >= 0.75)
    }

    @Test func lowSimilarityNotDetected() {
        let a = makeCard(context: context, lastName: "山田", lastNameReading: "やまだ", firstName: "太郎", firstNameReading: "たろう")
        let b = makeCard(context: context, lastName: "佐藤", lastNameReading: "さとう", firstName: "花子", firstNameReading: "はなこ")
        #expect(checker.findDuplicates(in: [a, b]).isEmpty)
    }

    @Test func sortedByScoreDescending() {
        let a = makeCard(context: context, lastName: "山田", lastNameReading: "やまだ", firstName: "太郎", firstNameReading: "たろう")
        let b = makeCard(context: context, lastName: "山田", lastNameReading: "やまだ", firstName: "太郎", firstNameReading: "たろう") // a-b = 1.0
        let c = makeCard(context: context, lastName: "山田", lastNameReading: "やまだ", firstName: "次郎", firstNameReading: "じろう") // a-c, b-c < 1.0
        let pairs = checker.findDuplicates(in: [a, b, c])
        guard pairs.count >= 2 else { return }
        #expect(pairs[0].score >= pairs[1].score)
    }

    @Test func bothEmptyNamesIgnored() {
        let a = makeCard(context: context)
        let b = makeCard(context: context)
        #expect(checker.findDuplicates(in: [a, b]).isEmpty)
    }

    @Test func scoreTextIsPercentage() {
        let a = makeCard(context: context, lastName: "山田", lastNameReading: "やまだ", firstName: "太郎", firstNameReading: "たろう")
        let b = makeCard(context: context, lastName: "山田", lastNameReading: "やまだ", firstName: "太郎", firstNameReading: "たろう")
        let pairs = checker.findDuplicates(in: [a, b])
        #expect(!pairs.isEmpty)
        #expect(pairs[0].scoreText == "100%")
    }

    @Test func weightedScoreMatchesFormula() {
        // 名前類似度 0.8・会社名類似度 1.0 → score = 0.8 * 0.7 + 1.0 * 0.3 = 0.86
        let lowThreshold = DuplicateChecker(threshold: 0.5)
        let a = makeCard(context: context, lastName: "山田", lastNameReading: "やまだ", firstName: "太郎", firstNameReading: "たろう", company: "テスト", companyReading: "てすと")
        let b = makeCard(context: context, lastName: "山田", lastNameReading: "やまだ", firstName: "次郎", firstNameReading: "じろう", company: "テスト", companyReading: "てすと")
        let pairs = lowThreshold.findDuplicates(in: [a, b])
        #expect(!pairs.isEmpty)
        let expectedName = lowThreshold.similarity("山田 太郎", "山田 次郎")
        let expectedComp = lowThreshold.similarity("テスト", "テスト")
        let expectedScore = expectedName * 0.7 + expectedComp * 0.3
        #expect(abs(pairs[0].score - expectedScore) < 0.001)
    }

    @Test func customThresholdFilters() {
        // 閾値 1.0 → 完全一致のみ検出
        let strictChecker = DuplicateChecker(threshold: 1.0)
        let a = makeCard(context: context, lastName: "山田", lastNameReading: "やまだ", firstName: "太郎", firstNameReading: "たろう")
        let b = makeCard(context: context, lastName: "山田", lastNameReading: "やまだ", firstName: "次郎", firstNameReading: "じろう")
        #expect(strictChecker.findDuplicates(in: [a, b]).isEmpty)
    }
}

// MARK: - ExportService CSV テスト

struct ExportServiceCSVTests {

    let service = ExportService()
    let context = makeTestContext()

    @Test func headerRow() {
        let firstLine = service.csvString(from: []).components(separatedBy: "\n").first ?? ""
        #expect(firstLine == "姓,名,会社名,部署,役職,電話番号,メールアドレス,住所,Webサイト,メモ,登録日時")
    }

    @Test func emptyCardsOnlyHeader() {
        let lines = service.csvString(from: []).components(separatedBy: "\n")
        #expect(lines.count == 1)
    }

    @Test func singleCardRowCount() {
        let card = makeCard(context: context, lastName: "山田", lastNameReading: "やまだ", firstName: "太郎", firstNameReading: "たろう")
        let lines = service.csvString(from: [card]).components(separatedBy: "\n")
        #expect(lines.count == 2)
    }

    @Test func rowFieldOrder() {
        // 姓,名,会社名,部署,役職,電話番号,メールアドレス,住所,Webサイト,メモ,登録日時
        let card = makeCard(context: context, lastName: "山田", lastNameReading: "やまだ",
                            firstName: "太郎", firstNameReading: "たろう",
                            company: "テスト株式会社", companyReading: "てすと",
                            title: "部長", email: "yamada@test.co.jp")
        let row = service.csvString(from: [card]).components(separatedBy: "\n")[1]
        #expect(row.hasPrefix("山田,太郎,テスト株式会社,,部長,,yamada@test.co.jp"))
    }

    @Test func multiplePhonesSeparated() {
        let card = makeCard(context: context, phone: "090-1111-1111\n090-2222-2222")
        let row = service.csvString(from: [card]).components(separatedBy: "\n")[1]
        #expect(row.contains("090-1111-1111 / 090-2222-2222"))
    }

    @Test func escapesComma() {
        let card = makeCard(context: context, address: "東京都渋谷区, 1-2-3")
        let csv = service.csvString(from: [card])
        #expect(csv.contains("\"東京都渋谷区, 1-2-3\""))
    }

    @Test func escapesDoubleQuote() {
        let card = makeCard(context: context, notes: "メモに\"引用\"あり")
        let csv = service.csvString(from: [card])
        #expect(csv.contains("\"メモに\"\"引用\"\"あり\""))
    }

    @Test func escapesNewline() {
        let card = makeCard(context: context, notes: "1行目\n2行目")
        let csv = service.csvString(from: [card])
        #expect(csv.contains("\"1行目\n2行目\""))
    }

    @Test func noEscapeForPlainText() {
        let card = makeCard(context: context, lastName: "山田", lastNameReading: "やまだ", firstName: "太郎", firstNameReading: "たろう")
        let csv = service.csvString(from: [card])
        #expect(csv.contains("山田,太郎"))
    }

    @Test func multipleCardsMultipleRows() {
        let a = makeCard(context: context, lastName: "山田", lastNameReading: "やまだ")
        let b = makeCard(context: context, lastName: "田中", lastNameReading: "たなか")
        let lines = service.csvString(from: [a, b]).components(separatedBy: "\n")
        // ヘッダー + 2行
        #expect(lines.count == 3)
    }

    @Test func departmentIncludedInRow() {
        let card = makeCard(context: context, company: "テスト株式会社", companyReading: "てすと", department: "営業部")
        let row = service.csvString(from: [card]).components(separatedBy: "\n")[1]
        // 3列目=会社名, 4列目=部署
        let fields = row.components(separatedBy: ",")
        #expect(fields[2] == "テスト株式会社")
        #expect(fields[3] == "営業部")
    }
}

// MARK: - ExportService vCard テスト

struct ExportServiceVCardTests {

    let service = ExportService()
    let context = makeTestContext()

    @Test func vCardStructure() {
        let card = makeCard(context: context, lastName: "山田", lastNameReading: "やまだ", firstName: "太郎", firstNameReading: "たろう")
        let vcf = service.vCardString(from: [card])
        #expect(vcf.contains("BEGIN:VCARD"))
        #expect(vcf.contains("VERSION:3.0"))
        #expect(vcf.contains("END:VCARD"))
    }

    @Test func nField() {
        let card = makeCard(context: context, lastName: "山田", lastNameReading: "やまだ", firstName: "太郎", firstNameReading: "たろう")
        let vcf = service.vCardString(from: [card])
        #expect(vcf.contains("N:山田;太郎;;;"))
    }

    @Test func fnField() {
        let card = makeCard(context: context, lastName: "山田", lastNameReading: "やまだ", firstName: "太郎", firstNameReading: "たろう")
        let vcf = service.vCardString(from: [card])
        #expect(vcf.contains("FN:山田 太郎"))
    }

    @Test func orgWithDepartment() {
        let card = makeCard(context: context, company: "テスト株式会社", companyReading: "てすと", department: "営業部")
        let vcf = service.vCardString(from: [card])
        #expect(vcf.contains("ORG:テスト株式会社;営業部"))
    }

    @Test func orgWithoutDepartment() {
        let card = makeCard(context: context, company: "テスト株式会社", companyReading: "てすと")
        let vcf = service.vCardString(from: [card])
        #expect(vcf.contains("ORG:テスト株式会社;"))
    }

    @Test func noOrgWhenBothEmpty() {
        let card = makeCard(context: context, lastName: "山田", lastNameReading: "やまだ")
        let vcf = service.vCardString(from: [card])
        #expect(!vcf.contains("ORG:"))
    }

    @Test func titleField() {
        let card = makeCard(context: context, title: "営業部長")
        let vcf = service.vCardString(from: [card])
        #expect(vcf.contains("TITLE:営業部長"))
    }

    @Test func telField() {
        let card = makeCard(context: context, phone: "090-1234-5678")
        let vcf = service.vCardString(from: [card])
        #expect(vcf.contains("TEL;TYPE=WORK:090-1234-5678"))
    }

    @Test func emailField() {
        let card = makeCard(context: context, email: "yamada@test.co.jp")
        let vcf = service.vCardString(from: [card])
        #expect(vcf.contains("EMAIL;TYPE=WORK:yamada@test.co.jp"))
    }

    @Test func adrField() {
        let card = makeCard(context: context, address: "東京都渋谷区1-2-3")
        let vcf = service.vCardString(from: [card])
        #expect(vcf.contains("ADR;TYPE=WORK:;;東京都渋谷区1-2-3;;;;"))
    }

    @Test func urlField() {
        let card = makeCard(context: context, website: "https://example.com")
        let vcf = service.vCardString(from: [card])
        #expect(vcf.contains("URL:https://example.com"))
    }

    @Test func noteField() {
        let card = makeCard(context: context, notes: "備考欄")
        let vcf = service.vCardString(from: [card])
        #expect(vcf.contains("NOTE:備考欄"))
    }

    @Test func escapesComma() {
        let card = makeCard(context: context, company: "A,B Corp")
        let vcf = service.vCardString(from: [card])
        #expect(vcf.contains("A\\,B Corp"))
    }

    @Test func escapesSemicolon() {
        let card = makeCard(context: context, company: "A;B Corp")
        let vcf = service.vCardString(from: [card])
        #expect(vcf.contains("A\\;B Corp"))
    }

    @Test func escapesBackslash() {
        let card = makeCard(context: context, notes: "パス: C:\\test")
        let vcf = service.vCardString(from: [card])
        #expect(vcf.contains("C:\\\\test"))
    }

    @Test func multipleCards() {
        let a = makeCard(context: context, lastName: "山田", lastNameReading: "やまだ", firstName: "太郎", firstNameReading: "たろう")
        let b = makeCard(context: context, lastName: "田中", lastNameReading: "たなか", firstName: "花子", firstNameReading: "はなこ")
        let vcf = service.vCardString(from: [a, b])
        let count = vcf.components(separatedBy: "BEGIN:VCARD").count - 1
        #expect(count == 2)
    }

    @Test func omitsEmptyOptionalFields() {
        // 値が空のフィールドは vCard に含まれない
        let card = makeCard(context: context, lastName: "山田", lastNameReading: "やまだ")
        let vcf = service.vCardString(from: [card])
        #expect(!vcf.contains("TITLE:"))
        #expect(!vcf.contains("EMAIL"))
        #expect(!vcf.contains("ADR"))
        #expect(!vcf.contains("URL:"))
        #expect(!vcf.contains("NOTE:"))
    }
}

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

// MARK: - Qwen25Tokenizer バイトマッピング テスト

struct ByteMappingTests {

    // GPT-2方式の bytes_to_unicode が全256バイトを網羅するか
    @Test func coverageAllBytes() {
        let (enc, dec) = Qwen25Tokenizer.buildByteMapping()
        #expect(enc.count == 256, "全256バイトがエンコード対応している必要がある")
        #expect(dec.count == 256, "全256バイトがデコード対応している必要がある")
    }

    // スペース (0x20) が U+0120 (Ġ) にマップされること
    @Test func spaceEncodedAsGhostChar() {
        let (enc, _) = Qwen25Tokenizer.buildByteMapping()
        #expect(enc[0x20] == "Ġ", "スペースは Ġ (U+0120) にエンコードされる必要がある")
    }

    // 改行 (0x0A) が Ċ (U+010A) にマップされること
    @Test func newlineEncoded() {
        let (enc, _) = Qwen25Tokenizer.buildByteMapping()
        #expect(enc[0x0A] == "Ċ", "改行は Ċ (U+010A) にエンコードされる必要がある")
    }

    // 印字可能 ASCII (例: 'A' = 0x41) はそのままマップされること
    @Test func printableAsciiIdentity() {
        let (enc, dec) = Qwen25Tokenizer.buildByteMapping()
        #expect(enc[0x41] == "A", "印字可能 ASCII は自分自身にエンコードされる")
        #expect(dec["A"] == 0x41, "印字可能 ASCII は自分自身からデコードされる")
    }

    // エンコードとデコードが逆写像になっているか
    @Test func roundTrip() {
        let (enc, dec) = Qwen25Tokenizer.buildByteMapping()
        for b: UInt8 in 0...255 {
            if let ch = enc[b], let decoded = dec[ch] {
                #expect(decoded == b, "byte \(b) のラウンドトリップが失敗")
            }
        }
    }
}

// MARK: - BPEPair テスト

@MainActor
struct BPEPairTests {

    @Test func hashEquality() {
        let p1 = BPEPair("hello", "world")
        let p2 = BPEPair("hello", "world")
        let p3 = BPEPair("world", "hello")
        #expect(p1 == p2)
        #expect(p1 != p3)
        var set = Set<BPEPair>()
        set.insert(p1)
        set.insert(p2)
        #expect(set.count == 1, "同じペアは重複なく格納される")
    }
}

// MARK: - LocalLLMService CausalMask テスト（モデル不要）

struct CausalMaskTests {

    let service = LocalLLMService.shared

    // 4D プリフィルマスク: 下三角が 0 (attend)、上三角が -30000 (block)
    @Test func prefillMask4DInt32() throws {
        let mask = try service.buildCausalMask(queryLen: 3, keyLen: 3)
        #expect(mask.shape == [1, 1, 3, 3])
        let allow = 0
        let block = -30000
        // [0,0,0,0]=allow  [0,0,0,1]=block  [0,0,0,2]=block
        // [0,0,1,0]=allow  [0,0,1,1]=allow   [0,0,1,2]=block
        // [0,0,2,0]=allow  [0,0,2,1]=allow   [0,0,2,2]=allow
        #expect(mask[0].intValue == allow)
        #expect(mask[1].intValue == block)
        #expect(mask[2].intValue == block)
        #expect(mask[3].intValue == allow)
        #expect(mask[4].intValue == allow)
        #expect(mask[5].intValue == block)
        #expect(mask[6].intValue == allow)
        #expect(mask[7].intValue == allow)
        #expect(mask[8].intValue == allow)
    }

    // 4D デコードマスク: queryLen=1 のとき全て 0 (attend all)
    @Test func decodeMask4DAllOnes() throws {
        let mask = try service.buildCausalMask(queryLen: 1, keyLen: 5)
        #expect(mask.shape == [1, 1, 1, 5])
        for i in 0..<5 {
            #expect(mask[i].intValue == 0, "デコードマスクは全て 0 (attend) である必要がある")
        }
    }
}

// MARK: - CardFieldClassifier StructuredFields テスト

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

// MARK: - ハイブリッドプロンプト テスト

struct HybridPromptTests {

    let service = LocalLLMService.shared

    @Test func hybridPromptContainsUnclassifiedLines() {
        let prompt = service.buildChatMLPrompt(
            unclassifiedLines: ["山田 太郎", "営業部長"],
            knownCompany: "株式会社テスト"
        )
        #expect(prompt.contains("山田 太郎"))
        #expect(prompt.contains("営業部長"))
    }

    @Test func hybridPromptContainsCompanyHint() {
        let prompt = service.buildChatMLPrompt(
            unclassifiedLines: ["山田 太郎"],
            knownCompany: "株式会社テスト"
        )
        #expect(prompt.contains("株式会社テスト"), "判明済みの会社名がヒントとして含まれる")
    }

    @Test func hybridPromptOmitsCompanyHintWhenEmpty() {
        let prompt = service.buildChatMLPrompt(
            unclassifiedLines: ["山田 太郎"],
            knownCompany: ""
        )
        #expect(!prompt.contains("company="), "会社名が空の場合はヒントが含まれない")
    }

    @Test func hybridPromptNoLeadingSpaces() {
        let prompt = service.buildChatMLPrompt(
            unclassifiedLines: ["テスト"],
            knownCompany: ""
        )
        // 各行の先頭にインデント用スペースが入っていないことを確認
        let lines = prompt.components(separatedBy: "\n")
        for line in lines where !line.isEmpty {
            #expect(!line.hasPrefix("    "), "プロンプト行に不要なインデントがないこと")
        }
    }
}

// MARK: - ChatML プロンプト テスト

struct ChatMLPromptTests {

    let service = LocalLLMService.shared

    @Test func promptContainsSpecialTokens() {
        let prompt = service.buildChatMLPrompt(lines: ["山田 太郎", "株式会社テスト"])
        #expect(prompt.contains("<|im_start|>"), "ChatML 開始トークンが必要")
        #expect(prompt.contains("<|im_end|>"),   "ChatML 終了トークンが必要")
        #expect(prompt.contains("system"),       "system ロールが必要")
        #expect(prompt.contains("user"),         "user ロールが必要")
        #expect(prompt.contains("assistant"),    "assistant プレフィクスが必要")
    }

    @Test func promptContainsInputLines() {
        let lines = ["山田 太郎", "株式会社テスト", "test@example.com"]
        let prompt = service.buildChatMLPrompt(lines: lines)
        for line in lines {
            #expect(prompt.contains(line), "入力行 '\(line)' がプロンプトに含まれる必要がある")
        }
    }

    @Test func promptEndsWithJSONPrefill() {
        let prompt = service.buildChatMLPrompt(lines: ["テスト"])
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(trimmed.hasSuffix("{\"lastName\":\""),
                "プロンプトは JSON プリフィル '{\"lastName\":\"' で終わる必要がある")
        #expect(trimmed.contains("/no_think"),
                "プロンプトに /no_think（思考モード無効化）が含まれる必要がある")
    }
}

// MARK: - JSON パース テスト

struct JSONParseTests {

    let service = LocalLLMService.shared

    @Test func parsesFullJSON() {
        let json = """
        {"lastName":"山田","firstName":"太郎","company":"テスト株式会社","title":"部長",\
        "phone":"090-1234-5678","email":"yamada@test.co.jp","address":"東京都","website":"https://test.co.jp"}
        """
        let result = service.parseJSON(json)
        #expect(result != nil)
        #expect(result?.lastName          == "山田")
        #expect(result?.firstName         == "太郎")
        #expect(result?.company           == "テスト株式会社")
        #expect(result?.title             == "部長")
        #expect(result?.phones.first      == "090-1234-5678")
        #expect(result?.email             == "yamada@test.co.jp")
        #expect(result?.address           == "東京都")
        #expect(result?.website           == "https://test.co.jp")
    }

    @Test func parsesJSONWithMarkdownFence() {
        let text = """
        ```json
        {"lastName":"田中","firstName":"花子","company":"","title":"","phone":"","email":"","address":"","website":""}
        ```
        """
        let result = service.parseJSON(text)
        #expect(result != nil, "```json フェンスを除去してパースできる必要がある")
        #expect(result?.lastName  == "田中")
        #expect(result?.firstName == "花子")
    }

    @Test func parsesJSONWithLeadingText() {
        let text = "以下がJSONです：\n{\"lastName\":\"佐藤\",\"firstName\":\"一郎\",\"company\":\"\",\"title\":\"\",\"phone\":\"\",\"email\":\"\",\"address\":\"\",\"website\":\"\"}"
        let result = service.parseJSON(text)
        #expect(result != nil, "前置きテキストがあってもパースできる必要がある")
        #expect(result?.lastName == "佐藤")
    }

    @Test func returnsNilForInvalidJSON() {
        #expect(service.parseJSON("") == nil)
        #expect(service.parseJSON("これはJSONではありません") == nil)
        #expect(service.parseJSON("{ 不正なJSON }") == nil)
    }

    @Test func parsesPartialJSON() {
        let json = "{\"lastName\":\"木村\",\"firstName\":\"次郎\"}"
        let result = service.parseJSON(json)
        // 欠けたフィールドは空文字列になる
        #expect(result?.lastName == "木村")
        #expect(result?.company  == "")
    }
}

// MARK: - SpecialToken ID テスト

struct SpecialTokenTests {

    @Test func tokenIDsMatchQwenSpec() {
        #expect(Qwen25Tokenizer.SpecialToken.imStart == 151644)
        #expect(Qwen25Tokenizer.SpecialToken.imEnd   == 151645)
        #expect(Qwen25Tokenizer.SpecialToken.eot     == 151643)
    }
}

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

// MARK: - 重複検出の法人格正規化テスト

struct DuplicateCheckerLegalEntityTests {

    @Test func duplicateDetectionNormalizesCompanySuffix() {
        let ctx = makeTestContext()
        let checker = DuplicateChecker(threshold: 0.70)

        // 同一人物・前株 vs 後株
        let a = makeCard(context: ctx, lastName: "田中", firstName: "太郎", company: "株式会社ABC")
        let b = makeCard(context: ctx, lastName: "田中", firstName: "太郎", company: "ABC株式会社")
        let pairs = checker.findDuplicates(in: [a, b])

        #expect(!pairs.isEmpty)
        if let pair = pairs.first {
            // 法人格除去後の会社名が一致するため高スコア
            #expect(pair.score >= 0.95)
        }
    }

    @Test func duplicateDetectionNormalizesAbbreviatedSuffix() {
        let ctx = makeTestContext()
        let checker = DuplicateChecker(threshold: 0.70)

        let a = makeCard(context: ctx, lastName: "鈴木", firstName: "花子", company: "(株)テスト")
        let b = makeCard(context: ctx, lastName: "鈴木", firstName: "花子", company: "株式会社テスト")
        let pairs = checker.findDuplicates(in: [a, b])

        #expect(!pairs.isEmpty)
    }

    @Test func duplicateDetectionNormalizesCompanyVsNoSuffix() {
        let ctx = makeTestContext()
        let checker = DuplicateChecker(threshold: 0.70)

        let a = makeCard(context: ctx, lastName: "佐藤", firstName: "一郎", company: "株式会社テスト")
        let b = makeCard(context: ctx, lastName: "佐藤", firstName: "一郎", company: "テスト")
        let pairs = checker.findDuplicates(in: [a, b])

        #expect(!pairs.isEmpty)
    }

    // MARK: - 長音処理テスト

    @Test func readingsMatchToleratesLongVowelDifference() {
        // こへい vs こうへい（長音の有無）
        #expect(NameReadingGenerator.readingsMatch("こへい", "こうへい"))
        #expect(NameProcessor.readingsMatch("こへい", "こうへい"))

        // おた vs おうた
        #expect(NameReadingGenerator.readingsMatch("おた", "おうた"))

        // 完全一致
        #expect(NameReadingGenerator.readingsMatch("たなか", "たなか"))

        // 全く異なる読みは不一致
        #expect(!NameReadingGenerator.readingsMatch("やまだ", "たなか"))
    }

    @Test func normalizeRomajiHandlesOhConsonant() {
        // oh + 子音 → ouh
        #expect(NameReadingGenerator.normalizeRomaji("ohta") == "ouhta")
        #expect(NameReadingGenerator.normalizeRomaji("yohko") == "youhko")

        // 語末の oh → ou
        #expect(NameReadingGenerator.normalizeRomaji("itoh") == "itou")
        #expect(NameReadingGenerator.normalizeRomaji("satoh") == "satou")

        // oh + 母音はそのまま（例: ohashi）
        #expect(NameReadingGenerator.normalizeRomaji("ohashi") == "ohashi")

        // NameProcessor 側も同様
        #expect(NameProcessor.normalizeRomaji("ohta") == "ouhta")
        #expect(NameProcessor.normalizeRomaji("itoh") == "itou")
    }

    @Test func preferReadingUsesReferenceForLongVowels() {
        // 長音の違いだけなら参照読みを優先
        #expect(NameReadingGenerator.preferReading(romaji: "こへい", reference: "こうへい") == "こうへい")
        #expect(NameProcessor.preferReading(romaji: "こへい", reference: "こうへい") == "こうへい")

        // 完全一致なら参照を返す
        #expect(NameReadingGenerator.preferReading(romaji: "たなか", reference: "たなか") == "たなか")

        // 異なる読みならローマ字を優先（珍しい名前）
        #expect(NameReadingGenerator.preferReading(romaji: "ひふみ", reference: "いちにさん") == "ひふみ")

        // 参照が空ならローマ字を返す
        #expect(NameReadingGenerator.preferReading(romaji: "こへい", reference: "") == "こへい")
    }

    @Test func inferReadingFromEmailPreservesLongVowels() {
        // メールアドレスからの読み推定で長音が保持されること
        let result = NameReadingGenerator.inferReadingFromEmail(
            email: "kohei.tanaka@example.com",
            lastName: "田中",
            firstName: "康平"
        )
        #expect(result != nil)
        if let r = result {
            // 参照読み（こうへい）が優先されること
            #expect(r.firstNameReading == "こうへい")
        }
    }
}
