import Testing
import CoreData
@testable import eMeishi

// MARK: - テスト用ヘルパー

@MainActor
private func makeTestContext() -> NSManagedObjectContext {
    PersistenceController(inMemory: true).container.viewContext
}

@MainActor
private func makeCard(
    context: NSManagedObjectContext,
    lastName: String? = nil,
    lastNameReading: String? = nil,
    firstName: String? = nil,
    company: String? = nil,
    companyReading: String? = nil,
    createdAt: Date = Date()
) -> BusinessCard {
    let card = BusinessCard(context: context)
    card.id              = UUID()
    card.lastName        = lastName
    card.lastNameReading = lastNameReading
    card.firstName       = firstName
    card.company         = company
    card.companyReading  = companyReading
    card.createdAt       = createdAt
    card.updatedAt       = createdAt
    return card
}

// MARK: - sectionKey

struct CardGroupingServiceSectionKeyTests {

    @Test func hiraganaAGyoFromA() {
        #expect(CardGroupingService.sectionKey(for: "あ") == "あ行")
        #expect(CardGroupingService.sectionKey(for: "お") == "あ行")
    }

    @Test func hiraganaKaGyo() {
        #expect(CardGroupingService.sectionKey(for: "か") == "か行")
        #expect(CardGroupingService.sectionKey(for: "こ") == "か行")
    }

    @Test func hiraganaSaGyo() {
        #expect(CardGroupingService.sectionKey(for: "さ") == "さ行")
    }

    @Test func hiraganaTaGyo() {
        #expect(CardGroupingService.sectionKey(for: "た") == "た行")
        #expect(CardGroupingService.sectionKey(for: "と") == "た行")
    }

    @Test func hiraganaNaGyo() {
        #expect(CardGroupingService.sectionKey(for: "な") == "な行")
    }

    @Test func hiraganaHaGyo() {
        #expect(CardGroupingService.sectionKey(for: "は") == "は行")
    }

    @Test func hiraganaMaGyo() {
        #expect(CardGroupingService.sectionKey(for: "ま") == "ま行")
    }

    @Test func hiraganaYaGyo() {
        #expect(CardGroupingService.sectionKey(for: "や") == "や行")
    }

    @Test func hiraganaRaGyo() {
        #expect(CardGroupingService.sectionKey(for: "ら") == "ら行")
    }

    @Test func hiraganaWaGyoIncludesWoAndN() {
        // 「わ」「を」「ん」は 0x308F..0x3093 で「わ行」扱い
        #expect(CardGroupingService.sectionKey(for: "わ") == "わ行")
        #expect(CardGroupingService.sectionKey(for: "を") == "わ行")
        #expect(CardGroupingService.sectionKey(for: "ん") == "わ行")
    }

    @Test func katakanaIsConvertedToHiragana() {
        // カタカナ→ひらがな変換（0x30A1..0x30F6 → -0x60）
        #expect(CardGroupingService.sectionKey(for: "ア") == "あ行")
        #expect(CardGroupingService.sectionKey(for: "ワ") == "わ行")
        #expect(CardGroupingService.sectionKey(for: "ヲ") == "わ行")
    }

    @Test func dakutenOutsideRangeFallsToOther() {
        // 現在の仕様：行範囲から外れる濁音・半濁音は「その他」に落ちる
        // 「ご」U+3054（か行端の外）、「そ」U+305D（さ行・た行の隙間）、「ぼ」U+307C（は行・ま行の隙間）
        #expect(CardGroupingService.sectionKey(for: "ご") == "その他")
        #expect(CardGroupingService.sectionKey(for: "そ") == "その他")
        #expect(CardGroupingService.sectionKey(for: "ぼ") == "その他")
    }

    @Test func katakanaVuFallsToOther() {
        // 「ヴ」U+30F4 → 変換後 0x3094 で case にマッチせず「その他」
        #expect(CardGroupingService.sectionKey(for: "ヴ") == "その他")
    }

    @Test func alphabetUpperCaseReturnsSelf() {
        #expect(CardGroupingService.sectionKey(for: "A") == "A")
        #expect(CardGroupingService.sectionKey(for: "Z") == "Z")
    }

    @Test func alphabetLowerCaseReturnsUpper() {
        #expect(CardGroupingService.sectionKey(for: "a") == "A")
        #expect(CardGroupingService.sectionKey(for: "z") == "Z")
    }

    @Test func nonAlphabetNonKanaReturnsOther() {
        #expect(CardGroupingService.sectionKey(for: "1") == "その他")
        #expect(CardGroupingService.sectionKey(for: "@") == "その他")
        #expect(CardGroupingService.sectionKey(for: "山") == "その他")
    }

    @Test func emptyStringReturnsOther() {
        #expect(CardGroupingService.sectionKey(for: "") == "その他")
    }
}

// MARK: - groupByName

@MainActor
struct CardGroupingServiceGroupByNameTests {

    @Test func prefersReadingOverLastName() throws {
        let context = makeTestContext()
        // 漢字の lastName が「山田」でも、reading「あかさ」が優先される
        _ = makeCard(context: context, lastName: "山田", lastNameReading: "あかさ")
        try context.save()

        let sections = CardGroupingService.groupByName(
            try #require(try context.fetch(BusinessCard.fetchRequest())),
            ascending: true
        )
        #expect(sections.first?.title == "あ行")
    }

    @Test func fallsBackToLastNameWhenReadingEmpty() throws {
        let context = makeTestContext()
        _ = makeCard(context: context, lastName: "Alpha")
        try context.save()

        let sections = CardGroupingService.groupByName(
            try #require(try context.fetch(BusinessCard.fetchRequest())),
            ascending: true
        )
        #expect(sections.first?.title == "A")
    }

    @Test func fallsBackToFirstNameWhenLastNameEmpty() throws {
        let context = makeTestContext()
        _ = makeCard(context: context, firstName: "Beta")
        try context.save()

        let sections = CardGroupingService.groupByName(
            try #require(try context.fetch(BusinessCard.fetchRequest())),
            ascending: true
        )
        #expect(sections.first?.title == "B")
    }

    @Test func emptyNameGoesToOther() throws {
        let context = makeTestContext()
        _ = makeCard(context: context)
        try context.save()

        let sections = CardGroupingService.groupByName(
            try #require(try context.fetch(BusinessCard.fetchRequest())),
            ascending: true
        )
        #expect(sections.first?.title == "その他")
    }

    @Test func ascendingFollowsSectionOrder() throws {
        let context = makeTestContext()
        _ = makeCard(context: context, lastName: "山田", lastNameReading: "やまだ")
        _ = makeCard(context: context, lastName: "安藤", lastNameReading: "あんどう")
        try context.save()

        let sections = CardGroupingService.groupByName(
            try #require(try context.fetch(BusinessCard.fetchRequest())),
            ascending: true
        )
        #expect(sections.map(\.title) == ["あ行", "や行"])
    }

    @Test func descendingReversesSectionOrder() throws {
        let context = makeTestContext()
        _ = makeCard(context: context, lastName: "山田", lastNameReading: "やまだ")
        _ = makeCard(context: context, lastName: "安藤", lastNameReading: "あんどう")
        try context.save()

        let sections = CardGroupingService.groupByName(
            try #require(try context.fetch(BusinessCard.fetchRequest())),
            ascending: false
        )
        #expect(sections.map(\.title) == ["や行", "あ行"])
    }
}

// MARK: - groupByCompany

@MainActor
struct CardGroupingServiceGroupByCompanyTests {

    @Test func groupsByCompanyReading() throws {
        let context = makeTestContext()
        _ = makeCard(context: context, lastName: "山田", company: "アルファ", companyReading: "あるふぁ")
        _ = makeCard(context: context, lastName: "佐藤", company: "カッパ",   companyReading: "かっぱ")
        try context.save()

        let sections = CardGroupingService.groupByCompany(
            try #require(try context.fetch(BusinessCard.fetchRequest())),
            ascending: true
        )
        #expect(sections.map(\.title) == ["あ行", "か行"])
    }

    @Test func companylessCardsGoToTrailingSectionAscending() throws {
        let context = makeTestContext()
        _ = makeCard(context: context, lastName: "山田", company: "アルファ", companyReading: "あるふぁ")
        _ = makeCard(context: context, lastName: "佐藤")  // 会社名なし
        try context.save()

        let sections = CardGroupingService.groupByCompany(
            try #require(try context.fetch(BusinessCard.fetchRequest())),
            ascending: true
        )
        // 会社名なしは常に末尾
        #expect(sections.last?.title == "（会社名なし）")
    }

    @Test func companylessCardsGoToTrailingSectionDescending() throws {
        // 降順でも「会社名なし」は末尾
        let context = makeTestContext()
        _ = makeCard(context: context, lastName: "山田", company: "アルファ", companyReading: "あるふぁ")
        _ = makeCard(context: context, lastName: "佐藤")
        try context.save()

        let sections = CardGroupingService.groupByCompany(
            try #require(try context.fetch(BusinessCard.fetchRequest())),
            ascending: false
        )
        #expect(sections.last?.title == "（会社名なし）")
    }
}

// MARK: - groupByDate

@MainActor
struct CardGroupingServiceGroupByDateTests {

    @Test func todayCardGoesToTodayBucket() throws {
        let context = makeTestContext()
        _ = makeCard(context: context, lastName: "山田", createdAt: Date())
        try context.save()

        let sections = CardGroupingService.groupByDate(
            try #require(try context.fetch(BusinessCard.fetchRequest())),
            dateOf: { $0.createdAt },
            ascending: false
        )
        #expect(sections.contains { $0.title == "今日" })
    }

    @Test func oldCardGoesToBeforeBucket() throws {
        let context = makeTestContext()
        let sixMonthsAgo = Calendar.current.date(byAdding: .month, value: -6, to: Date()) ?? .distantPast
        _ = makeCard(context: context, lastName: "山田", createdAt: sixMonthsAgo)
        try context.save()

        let sections = CardGroupingService.groupByDate(
            try #require(try context.fetch(BusinessCard.fetchRequest())),
            dateOf: { $0.createdAt },
            ascending: false
        )
        #expect(sections.contains { $0.title == "それ以前" })
    }

    @Test func nilDateFallsBackToBeforeBucket() throws {
        let context = makeTestContext()
        _ = makeCard(context: context, lastName: "山田")
        try context.save()

        let sections = CardGroupingService.groupByDate(
            try #require(try context.fetch(BusinessCard.fetchRequest())),
            dateOf: { _ in nil },
            ascending: false
        )
        #expect(sections.first?.title == "それ以前")
    }

    @Test func descendingPutsTodayFirst() throws {
        let context = makeTestContext()
        let sixMonthsAgo = Calendar.current.date(byAdding: .month, value: -6, to: Date()) ?? .distantPast
        _ = makeCard(context: context, lastName: "山田", createdAt: Date())
        _ = makeCard(context: context, lastName: "佐藤", createdAt: sixMonthsAgo)
        try context.save()

        let sections = CardGroupingService.groupByDate(
            try #require(try context.fetch(BusinessCard.fetchRequest())),
            dateOf: { $0.createdAt },
            ascending: false
        )
        // ascending=false（新→古）の場合、今日が先頭、それ以前が末尾
        #expect(sections.first?.title == "今日")
        #expect(sections.last?.title == "それ以前")
    }

    @Test func ascendingPutsBeforeFirst() throws {
        let context = makeTestContext()
        let sixMonthsAgo = Calendar.current.date(byAdding: .month, value: -6, to: Date()) ?? .distantPast
        _ = makeCard(context: context, lastName: "山田", createdAt: Date())
        _ = makeCard(context: context, lastName: "佐藤", createdAt: sixMonthsAgo)
        try context.save()

        let sections = CardGroupingService.groupByDate(
            try #require(try context.fetch(BusinessCard.fetchRequest())),
            dateOf: { $0.createdAt },
            ascending: true
        )
        // ascending=true（古→新）の場合、それ以前が先頭、今日が末尾
        #expect(sections.first?.title == "それ以前")
        #expect(sections.last?.title == "今日")
    }
}

// MARK: - sectionOrder

struct CardGroupingServiceSectionOrderTests {

    @Test func sectionOrderContainsKanaAndAlphabetAndOther() {
        let order = CardGroupingService.sectionOrder
        // 50音先頭・末尾、アルファベット、その他の存在確認
        #expect(order.first == "あ行")
        #expect(order.contains("わ行"))
        #expect(order.contains("A"))
        #expect(order.contains("Z"))
        #expect(order.last == "その他")
    }
}
