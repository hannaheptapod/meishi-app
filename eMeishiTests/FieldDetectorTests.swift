import Testing
@testable import eMeishi

// FieldDetector は LegalEntityTerms 以外は純ロジック。
// nlTaggerDetectsPersonalName のみ NaturalLanguage.framework に依存するため
// 限定的な観点のみテストする。

// MARK: - isCompany

struct FieldDetectorIsCompanyTests {

    @Test func detectsKanjiLegalEntityPrefix() {
        #expect(FieldDetector.isCompany("株式会社テスト") == true)
    }

    @Test func detectsKanjiLegalEntitySuffix() {
        #expect(FieldDetector.isCompany("テスト合同会社") == true)
    }

    @Test func detectsEnglishLegalEntity() {
        #expect(FieldDetector.isCompany("Test Inc.") == true)
    }

    @Test func detectsAbbreviatedLegalEntity() {
        #expect(FieldDetector.isCompany("(株)テスト") == true)
    }

    @Test func rejectsCompanyNameWithoutLegalEntity() {
        // 法人格を含まない「商事」等はこの関数では検出しない（companySuffixes は別用途）
        #expect(FieldDetector.isCompany("テスト商事") == false)
    }

    @Test func rejectsEmptyString() {
        #expect(FieldDetector.isCompany("") == false)
    }
}

// MARK: - isDepartment

struct FieldDetectorIsDepartmentTests {

    @Test func detectsJapaneseDepartmentSuffix() {
        #expect(FieldDetector.isDepartment("営業部") == true)
    }

    @Test func detectsKaSuffix() {
        #expect(FieldDetector.isDepartment("開発課") == true)
    }

    @Test func detectsEnglishDepartment() {
        // "Engineering" は isJobTitle の "Engineer" に先取りされるため、
        // 役職キーワードと衝突しない Sales を使用
        #expect(FieldDetector.isDepartment("Sales Department") == true)
    }

    @Test func rejectsWhenJobTitleOverlaps() {
        // 「営業部長」は isJobTitle が先に true を返すため isDepartment は false
        #expect(FieldDetector.isDepartment("営業部長") == false)
    }

    @Test func rejectsWhenCompanyOverlaps() {
        // isCompany（「株式会社」を含む）を先に除外する
        #expect(FieldDetector.isDepartment("株式会社営業部") == false)
    }

    @Test func rejectsPlainText() {
        #expect(FieldDetector.isDepartment("ただのテキスト") == false)
    }
}

// MARK: - isJobTitle

struct FieldDetectorIsJobTitleTests {

    @Test func detectsCEO() {
        // 3 文字ちょうどは OK
        #expect(FieldDetector.isJobTitle("CEO") == true)
    }

    @Test func detectsJapaneseJobTitle() {
        #expect(FieldDetector.isJobTitle("代表取締役") == true)
    }

    @Test func detectsEnglishJobTitle() {
        #expect(FieldDetector.isJobTitle("Vice President") == true)
    }

    @Test func detectsCompoundJapaneseTitle() {
        // 「部長」は単体だと 2 文字で除外されるが、複合語はキーワード検出される
        #expect(FieldDetector.isJobTitle("営業部長") == true)
    }

    @Test func rejectsShortInputUnderThree() {
        // 3 文字未満は早期 return で false
        #expect(FieldDetector.isJobTitle("部長") == false)
    }

    @Test func rejectsNonJobTitleText() {
        #expect(FieldDetector.isJobTitle("営業") == false)
    }
}

// MARK: - isBuildingName

struct FieldDetectorIsBuildingNameTests {

    @Test func detectsJapaneseBuildingSuffix() {
        #expect(FieldDetector.isBuildingName("六本木ヒルズ") == true)
    }

    @Test func detectsEnglishBuildingSuffix() {
        #expect(FieldDetector.isBuildingName("ABC Tower") == true)
    }

    @Test func detectsMinimumThreeChars() {
        // ちょうど 3 文字（空白除去後）
        #expect(FieldDetector.isBuildingName("Aビル") == true)
    }

    @Test func rejectsTooShort() {
        // 空白除去後 2 文字は false
        #expect(FieldDetector.isBuildingName("ビル") == false)
    }

    @Test func rejectsTooLong() {
        // 空白除去後 31 文字以上は false（ビルサフィックス付きでも）
        let tooLong = String(repeating: "あ", count: 28) + "タワー" // 31 文字
        #expect(FieldDetector.isBuildingName(tooLong) == false)
    }

    @Test func stripsWhitespaceForLengthCheck() {
        // 「A B Cビル」は空白除去後 4 文字でタワー/ビルを含むので true
        #expect(FieldDetector.isBuildingName("A B Cビル") == true)
    }

    @Test func rejectsTextWithoutBuildingSuffix() {
        #expect(FieldDetector.isBuildingName("渋谷駅前") == false)
    }
}

// MARK: - isAddress

struct FieldDetectorIsAddressTests {

    @Test func detectsPostalCodeWithHalfWidthHyphen() {
        #expect(FieldDetector.isAddress("〒150-0001 東京都渋谷区") == true)
    }

    @Test func detectsPostalCodeWithFullWidthHyphen() {
        // 全角ハイフンにもマッチする正規表現
        #expect(FieldDetector.isAddress("〒123−4567") == true)
    }

    @Test func detectsPrefecturePattern() {
        #expect(FieldDetector.isAddress("大阪府大阪市中央区1-1") == true)
    }

    @Test func detectsPrefectureAloneFourChar() {
        // 「東京都」は特例 3 文字＋都
        #expect(FieldDetector.isAddress("東京都") == true)
    }

    @Test func detectsHokkaidou() {
        // 「北海道」（3 文字の特例）
        #expect(FieldDetector.isAddress("北海道") == true)
    }

    @Test func rejectsNoPrefectureOrPostalCode() {
        #expect(FieldDetector.isAddress("渋谷1-2-3") == false)
    }

    @Test func rejectsPlainText() {
        #expect(FieldDetector.isAddress("これは住所ではない") == false)
    }
}

// MARK: - nlTaggerDetectsPersonalName

// NLTagger は iOS バージョン・言語モデルに依存するため、
// 確実性の高いケースのみテスト対象とする（環境依存を最小化）
struct FieldDetectorNLTaggerTests {

    @Test func rejectsSingleCharacter() {
        // 2 文字未満はガード条件で即 false
        #expect(FieldDetector.nlTaggerDetectsPersonalName(in: "A") == false)
    }

    @Test func rejectsEmptyString() {
        #expect(FieldDetector.nlTaggerDetectsPersonalName(in: "") == false)
    }

    @Test func detectsClearEnglishPersonalName() {
        // iOS 標準 NLTagger で英語の明白な人名はほぼ必ず当たる
        #expect(FieldDetector.nlTaggerDetectsPersonalName(in: "John Smith") == true)
    }
}
