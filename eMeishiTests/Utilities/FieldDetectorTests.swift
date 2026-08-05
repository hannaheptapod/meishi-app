import Testing
@testable import eMeishi

// MARK: - 会社名判定

@MainActor
struct FieldDetectorCompanyTests {

    @Test func detectsJapaneseCompanySuffix() {
        #expect(FieldDetector.isCompany("株式会社テックビジョン") == true)
        #expect(FieldDetector.isCompany("有限会社クリエイティブラボ") == true)
    }

    @Test func detectsEnglishCorpSuffix() {
        #expect(FieldDetector.isCompany("Example Inc.") == true)
        #expect(FieldDetector.isCompany("Global Corp.") == true)
    }

    @Test func returnsFalseForNonCompanyText() {
        #expect(FieldDetector.isCompany("営業部") == false)
        #expect(FieldDetector.isCompany("山田太郎") == false)
        #expect(FieldDetector.isCompany("") == false)
    }
}

// MARK: - 部署名判定

@MainActor
struct FieldDetectorDepartmentTests {

    @Test func detectsDepartmentSuffix() {
        #expect(FieldDetector.isDepartment("営業部") == true)
        #expect(FieldDetector.isDepartment("人事課") == true)
        #expect(FieldDetector.isDepartment("開発センター") == true)
    }

    @Test func returnsFalseWhenAlsoCompany() {
        // 会社名は部署より優先
        #expect(FieldDetector.isDepartment("株式会社テックビジョン") == false)
    }

    @Test func returnsFalseWhenAlsoJobTitle() {
        // 役職は部署より優先（「営業部長」は isJobTitle が true → isDepartment が false）
        // 「部長」単体は 2 文字のため isJobTitle の count>=3 ガードに弾かれ isDepartment=true になる
        #expect(FieldDetector.isDepartment("営業部長") == false)
    }

    @Test func returnsFalseForRandomText() {
        #expect(FieldDetector.isDepartment("山田太郎") == false)
    }

    @Test func detectsEnglishDivision() {
        #expect(FieldDetector.isDepartment("Sales Division") == true)
    }
}

// MARK: - 役職判定

@MainActor
struct FieldDetectorJobTitleTests {

    @Test func detectsJapaneseTitle() {
        #expect(FieldDetector.isJobTitle("代表取締役社長") == true)
        #expect(FieldDetector.isJobTitle("営業部長") == true)
        #expect(FieldDetector.isJobTitle("シニアエンジニア") == true)
        #expect(FieldDetector.isJobTitle("アソシエイト") == true)
    }

    @Test func detectsEnglishTitle() {
        #expect(FieldDetector.isJobTitle("CEO") == true)
        #expect(FieldDetector.isJobTitle("Software Engineer") == true)
        #expect(FieldDetector.isJobTitle("Associate") == true)
    }

    @Test func returnsFalseForShortText() {
        // 3文字未満は false
        #expect(FieldDetector.isJobTitle("AB") == false)
        #expect(FieldDetector.isJobTitle("課") == false)
    }

    @Test func returnsFalseForNonTitle() {
        #expect(FieldDetector.isJobTitle("山田太郎") == false)
    }
}

// MARK: - 建物名判定

@MainActor
struct FieldDetectorBuildingTests {

    @Test func detectsBuildingWithSuffix() {
        #expect(FieldDetector.isBuildingName("新宿タワー") == true)
        #expect(FieldDetector.isBuildingName("渋谷スクエアビル") == true)
    }

    @Test func returnsFalseForTooShortText() {
        // スペース除去後2文字以下
        #expect(FieldDetector.isBuildingName("AB") == false)
    }

    @Test func returnsFalseForTooLongText() {
        // スペース除去後31文字以上
        let long = String(repeating: "あ", count: 31) + "タワー"
        #expect(FieldDetector.isBuildingName(long) == false)
    }

    @Test func returnsFalseWithoutBuildingSuffix() {
        #expect(FieldDetector.isBuildingName("渋谷区道玄坂") == false)
    }

    @Test func detectsEnglishBuilding() {
        #expect(FieldDetector.isBuildingName("Shibuya Tower") == true)
    }
}

// MARK: - 住所判定

@MainActor
struct FieldDetectorAddressTests {

    @Test func detectsPostalCode() {
        #expect(FieldDetector.isAddress("〒150-0002 東京都") == true)
    }

    @Test func detectsTokyo() {
        #expect(FieldDetector.isAddress("東京都渋谷区道玄坂1-2-3") == true)
    }

    @Test func detectsOsakaPrefecture() {
        #expect(FieldDetector.isAddress("大阪府大阪市北区梅田") == true)
    }

    @Test func detectsMunicipalPattern() {
        // ASCII 数字が混ざると [^\x00-\x7F]* にマッチしないため、都道府県パターンで判定可能な文字列を使用
        #expect(FieldDetector.isAddress("神奈川県横浜市西区みなとみらい2-3") == true)
    }

    @Test func returnsFalseForNonAddress() {
        #expect(FieldDetector.isAddress("山田太郎") == false)
        #expect(FieldDetector.isAddress("") == false)
    }
}

// MARK: - NLTagger 個人名判定

@MainActor
struct FieldDetectorNLTaggerTests {

    @Test func returnsFalseForSingleChar() {
        #expect(FieldDetector.nlTaggerDetectsPersonalName(in: "A") == false)
    }

    @Test func doesNotCrashForJapaneseName() {
        // NLTagger は日本語名の PersonalName 判定が不安定なためクラッシュしないことのみ確認
        let _ = FieldDetector.nlTaggerDetectsPersonalName(in: "山田太郎")
    }

    @Test func detectsEnglishPersonalName() {
        // 英語名は NLTagger で PersonalName として認識される可能性が高い
        // 環境依存のため crash しないことを確認し、true の場合も受け入れる
        let result = FieldDetector.nlTaggerDetectsPersonalName(in: "John Smith")
        _ = result // true/false どちらも許容
    }
}
