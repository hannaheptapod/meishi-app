import Testing
import CoreData
@testable import eMeishi

// MARK: - マージロジック テスト（DuplicateMergeView.merge() の CoreData 相当）

@MainActor
struct MergeLogicTests {

    let context = makeTestContext()

    /// DuplicateMergeView.merge() と同等のロジックを実行するヘルパー
    @discardableResult
    private func performMerge(
        cardA: BusinessCard,
        cardB: BusinessCard,
        nameChoice:       Bool = true,  // true=A, false=B
        companyChoice:    Bool = true,
        departmentChoice: Bool = true,
        titleChoice:      Bool = true,
        phoneChoice:      Bool = true,
        emailChoice:      Bool = true,
        addressChoice:    Bool = true,
        websiteChoice:    Bool = true,
        notesChoice:      Bool = true
    ) -> BusinessCard {
        guard !cardB.isDeleted, cardB.managedObjectContext != nil else { return cardA }

        if !nameChoice {
            cardA.lastName         = cardB.lastName         ?? ""
            cardA.lastNameReading  = cardB.lastNameReading  ?? ""
            cardA.firstName        = cardB.firstName        ?? ""
            cardA.firstNameReading = cardB.firstNameReading ?? ""
        }
        cardA.company    = companyChoice    ? (cardA.company    ?? "") : (cardB.company    ?? "")
        cardA.department = departmentChoice ? (cardA.department ?? "") : (cardB.department ?? "")
        cardA.title      = titleChoice      ? (cardA.title      ?? "") : (cardB.title      ?? "")
        cardA.phone      = phoneChoice      ? (cardA.phone      ?? "") : (cardB.phone      ?? "")
        cardA.email      = emailChoice      ? (cardA.email      ?? "") : (cardB.email      ?? "")
        cardA.address    = addressChoice    ? (cardA.address    ?? "") : (cardB.address    ?? "")
        cardA.website    = websiteChoice    ? (cardA.website    ?? "") : (cardB.website    ?? "")
        cardA.notes      = notesChoice      ? (cardA.notes      ?? "") : (cardB.notes      ?? "")
        if cardA.imageData == nil { cardA.imageData = cardB.imageData }

        if let bTags = cardB.tags as? Set<eMeishi.Tag> {
            for tag in bTags { cardA.addToTags(tag) }
        }

        cardA.updatedAt = Date()
        context.delete(cardB)
        // テストヘルパーでは save しない（save 後は isDeleted が false にリセットされるため）
        return cardA
    }

    @Test func mergeNameChoiceB() {
        // 名前は B を採用した場合、読み仮名も B から転送される
        let a = makeCard(context: context, lastName: "山田", lastNameReading: "やまだ",
                         firstName: "太郎", firstNameReading: "たろう")
        let b = makeCard(context: context, lastName: "田中", lastNameReading: "たなか",
                         firstName: "花子", firstNameReading: "はなこ")
        performMerge(cardA: a, cardB: b, nameChoice: false)
        #expect(a.lastName         == "田中")
        #expect(a.lastNameReading  == "たなか")
        #expect(a.firstName        == "花子")
        #expect(a.firstNameReading == "はなこ")
    }

    @Test func mergeDepartmentChoiceB() {
        // 部署フィールドが B から正しく転送される
        let a = makeCard(context: context, department: "営業部")
        let b = makeCard(context: context, department: "開発部")
        performMerge(cardA: a, cardB: b, departmentChoice: false)
        #expect(a.department == "開発部")
    }

    @Test func mergeDepartmentChoiceA() {
        let a = makeCard(context: context, department: "営業部")
        let b = makeCard(context: context, department: "開発部")
        performMerge(cardA: a, cardB: b, departmentChoice: true)
        #expect(a.department == "営業部")
    }

    @Test func mergeTagsTransferredFromCardB() {
        // マージ後に cardB のタグが cardA に引き継がれる
        let a = makeCard(context: context)
        let b = makeCard(context: context)
        let tag = eMeishi.Tag(context: context)
        tag.id   = UUID()
        tag.name = "IT"
        b.addToTags(tag)

        performMerge(cardA: a, cardB: b)

        let aTags = (a.tags as? Set<eMeishi.Tag>) ?? []
        #expect(aTags.contains(where: { $0.name == "IT" }))
    }

    @Test func mergeTagsDeduplicatedWhenBothHaveSameTag() {
        // cardA と cardB が同じタグを持つ場合、重複なく 1 件だけ残る
        let a = makeCard(context: context)
        let b = makeCard(context: context)
        let tag = eMeishi.Tag(context: context)
        tag.id   = UUID()
        tag.name = "IT"
        a.addToTags(tag)
        b.addToTags(tag)

        performMerge(cardA: a, cardB: b)

        let aTags = (a.tags as? Set<eMeishi.Tag>) ?? []
        let itTags = aTags.filter { $0.name == "IT" }
        #expect(itTags.count == 1)
    }

    @Test func mergeCardBDeletedAfterMerge() {
        // マージ後に cardB が削除されている
        let a = makeCard(context: context)
        let b = makeCard(context: context)
        performMerge(cardA: a, cardB: b)
        #expect(b.isDeleted)
    }

    @Test func mergeSkipsAlreadyDeletedCardB() {
        // cardB が既に削除済みの場合はスキップして cardA を変更しない
        let a = makeCard(context: context, lastName: "山田", lastNameReading: "やまだ")
        let b = makeCard(context: context, lastName: "田中", lastNameReading: "たなか")
        context.delete(b)
        try? context.save()

        performMerge(cardA: a, cardB: b)
        // cardB は削除済みなのでマージ処理がスキップされ、cardA の lastName は変わらない
        #expect(a.lastName == "山田")
    }
}
