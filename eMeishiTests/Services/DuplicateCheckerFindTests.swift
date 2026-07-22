import Testing
import CoreData
@testable import eMeishi

// MARK: - DuplicateChecker 重複検出テスト

@MainActor
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

    @Test func backgroundSnapshotScanMatchesSynchronousResult() async {
        let first = makeCard(
            context: context,
            lastName: "Fixture-A",
            firstName: "Person",
            company: "Example One株式会社"
        )
        let second = makeCard(
            context: context,
            lastName: "Fixture-A",
            firstName: "Person",
            company: "Example Two株式会社"
        )
        let unrelated = makeCard(
            context: context,
            lastName: "Fixture-Z",
            firstName: "Other",
            company: "Sample合同会社"
        )
        let cards = [first, second, unrelated]

        let synchronous = checker.findDuplicates(in: cards)
        let scan = await checker.scanRuleBased(
            snapshots: checker.makeSnapshots(from: cards),
            includeBorderline: true
        )

        #expect(scan?.confirmed.map(\.id) == synchronous.map(\.id))
        #expect(scan?.confirmed.map(\.score) == synchronous.map(\.score))
    }
}
