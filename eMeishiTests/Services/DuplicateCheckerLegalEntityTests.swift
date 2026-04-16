import Testing
import CoreData
@testable import eMeishi

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

    // MARK: - カタカナ長音符ー保存テスト

    @Test func generateReadingPreservesKatakanaLongVowelMark() {
        // カタカナ会社名の ー がひらがなでも保存されること
        #expect(NameReadingGenerator.generateReading(from: "アバナード") == "あばなーど")
        #expect(NameReadingGenerator.generateReading(from: "グーグル") == "ぐーぐる")
        #expect(NameReadingGenerator.generateReading(from: "ジョーンズ") == "じょーんず")
        #expect(NameReadingGenerator.generateReading(from: "マイクロソフト") == "まいくろそふと")

        // NameProcessor 側も同様
        #expect(NameProcessor.generateReading(from: "アバナード") == "あばなーど")
        #expect(NameProcessor.generateReading(from: "グーグル") == "ぐーぐる")
    }

    @Test func normalizeToHiraganaPreservesLongVowelMark() {
        // OCRフリガナ行のカタカナ→ひらがな変換で ー が保存されること
        #expect(NameProcessor.normalizeToHiragana("アバナード") == "あばなーど")
        #expect(NameProcessor.normalizeToHiragana("ジョーンズ") == "じょーんず")
        #expect(NameProcessor.normalizeToHiragana("タナカ タロー") == "たなか たろー")
    }

    @Test func generateReadingKanjiNamesUnaffected() {
        // 漢字名の読み生成が影響を受けないこと（回帰テスト）
        #expect(NameReadingGenerator.generateReading(from: "山田") == "やまだ")
        #expect(NameReadingGenerator.generateReading(from: "佐藤") == "さとう")
        #expect(NameProcessor.generateReading(from: "山田") == "やまだ")
    }

    // MARK: - メール推定改善テスト

    @Test func readingsMatchToleratesDoubleVowel() {
        // おう vs おお（ローマ字由来とトークナイザー由来の長音差異）
        #expect(NameReadingGenerator.readingsMatch("おうた", "おおた"))
        #expect(NameProcessor.readingsMatch("おうた", "おおた"))
    }

    @Test func inferReadingFromEmailOhtaPattern() {
        // oh + 子音パターン: ohta → おうた vs CFStringTokenizer おおた
        let result = NameReadingGenerator.inferReadingFromEmail(
            email: "ohta.taro@example.com",
            lastName: "太田",
            firstName: "太郎"
        )
        #expect(result != nil)
        if let r = result {
            #expect(r.lastNameReading == "おおた")
            #expect(r.firstNameReading == "たろう")
        }
    }

    @Test func inferReadingFromEmailSingleSegmentLastName() {
        // 1セグメントで姓のみのメールアドレス
        let result = NameReadingGenerator.inferReadingFromEmail(
            email: "yamada@example.com",
            lastName: "山田",
            firstName: "太郎"
        )
        #expect(result != nil)
        if let r = result {
            #expect(r.lastNameReading == "やまだ")
        }
    }

    @Test func inferReadingFromEmailPartialMatch() {
        // 片方のみ姓マッチ → もう一方をメール由来の名読みとして採用
        let result = NameReadingGenerator.inferReadingFromEmail(
            email: "hifumi.yamada@example.com",
            lastName: "山田",
            firstName: "一二三"
        )
        #expect(result != nil)
        if let r = result {
            #expect(r.lastNameReading == "やまだ")
            #expect(r.firstNameReading == "ひふみ")
        }
    }
}
