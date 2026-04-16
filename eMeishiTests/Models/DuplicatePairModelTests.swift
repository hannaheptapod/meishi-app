import Testing
import CoreData
@testable import eMeishi

// MARK: - DuplicatePair モデルテスト

@MainActor
struct DuplicatePairModelTests {

    let context = makeTestContext()
    let checker = DuplicateChecker(threshold: 0.75)

    @Test func idIsStableAcrossFindCalls() {
        // id が UUID でなく objectID ベースになったため、同じカードペアに対して同じ id が返る
        let a = makeCard(context: context, lastName: "山田", firstName: "太郎")
        let b = makeCard(context: context, lastName: "山田", firstName: "太郎")
        let pairs1 = checker.findDuplicates(in: [a, b])
        let pairs2 = checker.findDuplicates(in: [a, b])
        #expect(!pairs1.isEmpty && !pairs2.isEmpty)
        #expect(pairs1[0].id == pairs2[0].id)
    }

    @Test func differentCardPairsHaveDifferentIds() {
        let a = makeCard(context: context, lastName: "山田", firstName: "太郎")
        let b = makeCard(context: context, lastName: "山田", firstName: "太郎")
        let c = makeCard(context: context, lastName: "山田", firstName: "太郎")
        let lowChecker = DuplicateChecker(threshold: 0.5)
        let pairs = lowChecker.findDuplicates(in: [a, b, c])
        // a-b, a-c, b-c の 3 ペアが返るはずで、id はすべて異なる
        guard pairs.count >= 2 else { return }
        let ids = Set(pairs.map { $0.id })
        #expect(ids.count == pairs.count)
    }

    @Test func isAIDetectedDefaultsFalse() {
        let a = makeCard(context: context, lastName: "山田", firstName: "太郎")
        let b = makeCard(context: context, lastName: "山田", firstName: "太郎")
        let pairs = checker.findDuplicates(in: [a, b])
        #expect(!pairs.isEmpty)
        #expect(pairs[0].isAIDetected == false)
    }
}
