import Testing
import CoreData
@testable import eMeishi

// Swift Testing の Tag と CoreData の Tag が衝突するため別名で参照する
private typealias CardTag = eMeishi.Tag

// MARK: - テスト用ヘルパー

@MainActor
private func makeTestContext() -> NSManagedObjectContext {
    PersistenceController(inMemory: true).container.viewContext
}

@MainActor
private func makeTag(context: NSManagedObjectContext, name: String, colorHex: String = "#FF0000") -> CardTag {
    let tag = CardTag(context: context)
    tag.id = UUID()
    tag.name = name
    tag.colorHex = colorHex
    tag.createdAt = Date()
    return tag
}

@MainActor
private func makeCard(
    context: NSManagedObjectContext,
    lastName: String? = nil,
    firstName: String? = nil,
    company: String? = nil,
    department: String? = nil,
    title: String? = nil,
    email: String? = nil,
    phone: String? = nil,
    address: String? = nil,
    website: String? = nil,
    notes: String? = nil
) -> BusinessCard {
    let card = BusinessCard(context: context)
    card.id        = UUID()
    card.lastName  = lastName
    card.firstName = firstName
    card.company   = company
    card.department = department
    card.title     = title
    card.email     = email
    card.phone     = phone
    card.address   = address
    card.website   = website
    card.notes     = notes
    card.createdAt = Date()
    card.updatedAt = Date()
    return card
}

@MainActor
private func fetchAllCards(_ context: NSManagedObjectContext) throws -> [BusinessCard] {
    try context.fetch(BusinessCard.fetchRequest())
}

// MARK: - 初期化（新規作成）

@MainActor
struct CardFormViewModelInitNewTests {

    @Test func newFormHasEmptyFields() {
        let vm = CardFormViewModel(context: makeTestContext())
        #expect(vm.lastName.isEmpty)
        #expect(vm.firstName.isEmpty)
        #expect(vm.company.isEmpty)
        #expect(vm.email.isEmpty)
        #expect(vm.phones == [""])
        #expect(vm.selectedTags.isEmpty)
        #expect(vm.suggestedTagIDs.isEmpty)
    }

    @Test func newFormIsNotEditing() {
        let vm = CardFormViewModel(context: makeTestContext())
        #expect(vm.isEditing == false)
    }

    @Test func newFormIsNotProcessingOCR() {
        let vm = CardFormViewModel(context: makeTestContext())
        #expect(vm.isProcessingOCR == false)
        #expect(vm.ocrErrorMessage == nil)
    }
}

// MARK: - 初期化（既存カード編集）

@MainActor
struct CardFormViewModelInitEditTests {

    @Test func editFormPopulatesFromCard() {
        let context = makeTestContext()
        let card = makeCard(
            context: context,
            lastName: "山田", firstName: "太郎",
            company: "テスト株式会社", department: "営業部", title: "部長",
            email: "taro@test.jp",
            phone: "090-1111-1111\n03-2222-2222",
            address: "東京都渋谷区", website: "https://test.jp", notes: "メモ"
        )

        let vm = CardFormViewModel(card: card, context: context)

        #expect(vm.lastName == "山田")
        #expect(vm.firstName == "太郎")
        #expect(vm.company == "テスト株式会社")
        #expect(vm.department == "営業部")
        #expect(vm.title == "部長")
        #expect(vm.email == "taro@test.jp")
        #expect(vm.phones == ["090-1111-1111", "03-2222-2222"])
        #expect(vm.address == "東京都渋谷区")
        #expect(vm.website == "https://test.jp")
        #expect(vm.notes == "メモ")
    }

    @Test func editFormIsEditing() {
        let context = makeTestContext()
        let card = makeCard(context: context, lastName: "山田")
        let vm = CardFormViewModel(card: card, context: context)
        #expect(vm.isEditing == true)
    }

    @Test func editFormWithNoPhonesYieldsSingleEmpty() {
        // phoneList が空なら UI で 1 行入力欄を表示するため [""] にする
        let context = makeTestContext()
        let card = makeCard(context: context, lastName: "山田", phone: nil)
        let vm = CardFormViewModel(card: card, context: context)
        #expect(vm.phones == [""])
    }

    @Test func editFormPopulatesSelectedTags() {
        let context = makeTestContext()
        let card = makeCard(context: context, lastName: "山田")
        let tag1 = makeTag(context: context, name: "重要")
        let tag2 = makeTag(context: context, name: "営業")
        card.addToTags(tag1)
        card.addToTags(tag2)

        let vm = CardFormViewModel(card: card, context: context)
        #expect(vm.selectedTags.contains(try! #require(tag1.id)))
        #expect(vm.selectedTags.contains(try! #require(tag2.id)))
    }
}

// MARK: - タグ提案操作

@MainActor
struct CardFormViewModelTagSuggestionTests {

    @Test func acceptMovesTagFromSuggestedToSelected() {
        let vm = CardFormViewModel(context: makeTestContext())
        let tagID = UUID()
        vm.suggestedTagIDs.insert(tagID)

        vm.acceptTagSuggestion(tagID)

        #expect(vm.selectedTags.contains(tagID))
        #expect(!vm.suggestedTagIDs.contains(tagID))
    }

    @Test func acceptWithUnknownIDAddsToSelected() {
        // 提案リストになくても selectedTags には追加される
        let vm = CardFormViewModel(context: makeTestContext())
        let tagID = UUID()

        vm.acceptTagSuggestion(tagID)

        #expect(vm.selectedTags.contains(tagID))
        #expect(vm.suggestedTagIDs.isEmpty)
    }

    @Test func dismissRemovesOnlyFromSuggested() {
        let vm = CardFormViewModel(context: makeTestContext())
        let tagID = UUID()
        vm.suggestedTagIDs.insert(tagID)

        vm.dismissTagSuggestion(tagID)

        #expect(!vm.suggestedTagIDs.contains(tagID))
        #expect(!vm.selectedTags.contains(tagID))
    }
}

// MARK: - save() — 新規作成

@MainActor
struct CardFormViewModelSaveNewTests {

    @Test func saveCreatesSingleCard() throws {
        let context = makeTestContext()
        let vm = CardFormViewModel(context: context)
        vm.lastName = "山田"

        vm.save()

        let cards = try fetchAllCards(context)
        #expect(cards.count == 1)
        #expect(cards.first?.lastName == "山田")
    }

    @Test func saveSetsIDAndTimestamps() throws {
        let context = makeTestContext()
        let vm = CardFormViewModel(context: context)
        vm.lastName = "山田"

        let beforeSave = Date()
        vm.save()

        let card = try #require(try fetchAllCards(context).first)
        #expect(card.id != nil)
        #expect(card.createdAt != nil)
        #expect(card.updatedAt != nil)
        #expect((card.createdAt ?? .distantPast) >= beforeSave.addingTimeInterval(-1))
    }

    @Test func savePersistsAllFields() throws {
        let context = makeTestContext()
        let vm = CardFormViewModel(context: context)
        vm.lastName  = "山田"
        vm.firstName = "太郎"
        vm.department = "営業部"
        vm.title     = "部長"
        vm.email     = "taro@test.jp"
        vm.address   = "東京都渋谷区"
        vm.website   = "https://test.jp"
        vm.notes     = "テストメモ"

        vm.save()

        let card = try #require(try fetchAllCards(context).first)
        #expect(card.lastName == "山田")
        #expect(card.firstName == "太郎")
        #expect(card.department == "営業部")
        #expect(card.title == "部長")
        #expect(card.email == "taro@test.jp")
        #expect(card.address == "東京都渋谷区")
        #expect(card.website == "https://test.jp")
        #expect(card.notes == "テストメモ")
    }

    @Test func savePersistsCapturedImage() throws {
        let context = makeTestContext()
        let vm = CardFormViewModel(context: context)
        vm.lastName = "山田"
        let imageData = Data([0x01, 0x02, 0x03])
        vm.capturedImageData = imageData

        vm.save()

        let card = try #require(try fetchAllCards(context).first)
        #expect(card.imageData == imageData)
    }
}

// MARK: - save() — 既存カード編集

@MainActor
struct CardFormViewModelSaveEditTests {

    @Test func saveOnEditDoesNotCreateNewCard() throws {
        let context = makeTestContext()
        let card = makeCard(context: context, lastName: "山田")
        try context.save()

        let vm = CardFormViewModel(card: card, context: context)
        vm.lastName = "田中"
        vm.save()

        let cards = try fetchAllCards(context)
        #expect(cards.count == 1)
        #expect(cards.first?.lastName == "田中")
    }

    @Test func saveOnEditPreservesID() throws {
        let context = makeTestContext()
        let card = makeCard(context: context, lastName: "山田")
        let originalID = card.id
        try context.save()

        let vm = CardFormViewModel(card: card, context: context)
        vm.lastName = "田中"
        vm.save()

        let saved = try #require(try fetchAllCards(context).first)
        #expect(saved.id == originalID)
    }

    @Test func saveOnEditUpdatesTimestamp() throws {
        let context = makeTestContext()
        // updatedAt を過去に設定して、save 後に更新されることを確認
        let card = makeCard(context: context, lastName: "山田")
        let oldTimestamp = Date(timeIntervalSinceReferenceDate: 0)
        card.updatedAt = oldTimestamp
        try context.save()

        let vm = CardFormViewModel(card: card, context: context)
        vm.lastName = "田中"
        vm.save()

        let saved = try #require(try fetchAllCards(context).first)
        #expect((saved.updatedAt ?? .distantPast) > oldTimestamp)
    }
}

// MARK: - save() — トリミング・電話整形

@MainActor
struct CardFormViewModelSaveFormattingTests {

    @Test func saveTrimsWhitespaceFromFields() throws {
        let context = makeTestContext()
        let vm = CardFormViewModel(context: context)
        vm.lastName = "  山田  "
        vm.firstName = "\t太郎\n"
        vm.email = "  taro@test.jp  "
        vm.address = " 東京都渋谷区 "

        vm.save()

        let card = try #require(try fetchAllCards(context).first)
        #expect(card.lastName == "山田")
        #expect(card.firstName == "太郎")
        #expect(card.email == "taro@test.jp")
        #expect(card.address == "東京都渋谷区")
    }

    @Test func savePhonesJoinedWithNewlineAndFiltered() throws {
        let context = makeTestContext()
        let vm = CardFormViewModel(context: context)
        vm.lastName = "山田"
        // 空要素・空白のみ要素はフィルタされ、残りを trim して \n で結合
        vm.phones = ["  03-1111-1111  ", "", "   ", "090-2222-2222"]

        vm.save()

        let card = try #require(try fetchAllCards(context).first)
        #expect(card.phone == "03-1111-1111\n090-2222-2222")
    }

    @Test func saveAllEmptyPhonesYieldsEmptyString() throws {
        let context = makeTestContext()
        let vm = CardFormViewModel(context: context)
        vm.lastName = "山田"
        vm.phones = ["", "   "]

        vm.save()

        let card = try #require(try fetchAllCards(context).first)
        #expect(card.phone == "")
    }
}

// MARK: - save() — 会社名読み処理

@MainActor
struct CardFormViewModelSaveCompanyReadingTests {

    @Test func autoGeneratesCompanyReadingFromKatakana() throws {
        // companyReading が空なら NameReadingGenerator.generateReading 経由で自動生成される
        let context = makeTestContext()
        let vm = CardFormViewModel(context: context)
        vm.lastName = "山田"
        vm.company = "アルファ"
        vm.companyReading = ""

        vm.save()

        let card = try #require(try fetchAllCards(context).first)
        // カタカナは対応するひらがなに変換される
        #expect(card.companyReading == "あるふぁ")
    }

    @Test func stripsLegalEntityFromExplicitReading() throws {
        // 明示指定の読みからも法人格（読み）が除去される
        let context = makeTestContext()
        let vm = CardFormViewModel(context: context)
        vm.lastName = "山田"
        vm.company = "テスト株式会社"
        vm.companyReading = "てすとかぶしきがいしゃ"

        vm.save()

        let card = try #require(try fetchAllCards(context).first)
        #expect(card.companyReading == "てすと")
    }

    @Test func emptyCompanyYieldsEmptyReading() throws {
        let context = makeTestContext()
        let vm = CardFormViewModel(context: context)
        vm.lastName = "山田"
        vm.company = ""
        vm.companyReading = ""

        vm.save()

        let card = try #require(try fetchAllCards(context).first)
        #expect(card.companyReading == "")
    }
}

// MARK: - save() — タグリレーション

@MainActor
struct CardFormViewModelSaveTagsTests {

    @Test func saveAssignsSelectedTags() throws {
        let context = makeTestContext()
        let tag1 = makeTag(context: context, name: "重要")
        let tag2 = makeTag(context: context, name: "営業")
        try context.save()

        let vm = CardFormViewModel(context: context)
        vm.lastName = "山田"
        vm.selectedTags = [try #require(tag1.id), try #require(tag2.id)]

        vm.save()

        let card = try #require(try fetchAllCards(context).first)
        let tags = (card.tags as? Set<CardTag>) ?? []
        #expect(tags.count == 2)
        #expect(tags.contains(tag1))
        #expect(tags.contains(tag2))
    }

    @Test func saveRemovesUnselectedTagsOnEdit() throws {
        // 編集時に selectedTags から外したタグは target.tags からも外れる
        let context = makeTestContext()
        let tag1 = makeTag(context: context, name: "重要")
        let tag2 = makeTag(context: context, name: "営業")
        let card = makeCard(context: context, lastName: "山田")
        card.addToTags(tag1)
        card.addToTags(tag2)
        try context.save()

        let vm = CardFormViewModel(card: card, context: context)
        // 片方だけ残す
        vm.selectedTags = [try #require(tag1.id)]

        vm.save()

        let saved = try #require(try fetchAllCards(context).first)
        let tags = (saved.tags as? Set<CardTag>) ?? []
        #expect(tags.count == 1)
        #expect(tags.contains(tag1))
        #expect(!tags.contains(tag2))
    }
}
