import Testing
import CoreData
@testable import eMeishi

struct SectionIndexSelectionTests {
    @Test func clampsStaleIndexAfterItemsShrink() {
        let result = SectionIndexSelection.adjustedIndex(
            current: 12,
            itemCount: 3,
            delta: -1
        )
        #expect(result == 1)
    }

    @Test func returnsNilWhenNoSectionsExist() {
        #expect(SectionIndexSelection.adjustedIndex(current: 4, itemCount: 0, delta: 1) == nil)
    }
}

// MARK: - テスト用ヘルパー

@MainActor
private func makeContext() -> NSManagedObjectContext {
    PersistenceController(inMemory: true).container.viewContext
}

@MainActor
private func makeGroupCard(
    context: NSManagedObjectContext,
    lastName: String? = nil,
    lastNameReading: String? = nil,
    firstName: String? = nil,
    company: String? = nil,
    companyReading: String? = nil
) -> BusinessCard {
    let card = BusinessCard(context: context)
    card.id = UUID()
    card.lastName = lastName
    card.lastNameReading = lastNameReading
    card.firstName = firstName
    card.company = company
    card.companyReading = companyReading
    card.createdAt = Date()
    card.updatedAt = Date()
    return card
}

// MARK: - sectionKey テスト

@MainActor
struct CardGroupingServiceSectionKeyTests {

    // ひらがな各行
    @Test func hiraganaARow()  { #expect(CardGroupingService.sectionKey(for: "あいう") == "あ行") }
    @Test func hiraganaKaRow() { #expect(CardGroupingService.sectionKey(for: "か") == "か行") }
    @Test func hiraganaSaRow() { #expect(CardGroupingService.sectionKey(for: "さとう") == "さ行") }
    @Test func hiraganaTaRow() { #expect(CardGroupingService.sectionKey(for: "たなか") == "た行") }
    @Test func hiraganaNaRow() { #expect(CardGroupingService.sectionKey(for: "なかむら") == "な行") }
    @Test func hiraganaHaRow() { #expect(CardGroupingService.sectionKey(for: "はやし") == "は行") }
    @Test func hiraganaMaRow() { #expect(CardGroupingService.sectionKey(for: "まつだ") == "ま行") }
    @Test func hiraganaYaRow() { #expect(CardGroupingService.sectionKey(for: "やまだ") == "や行") }
    @Test func hiraganaRaRow() { #expect(CardGroupingService.sectionKey(for: "りんどう") == "ら行") }
    @Test func hiraganaWaRow() { #expect(CardGroupingService.sectionKey(for: "わたなべ") == "わ行") }

    // カタカナ → ひらがな変換
    @Test func katakanaYaConverted() { #expect(CardGroupingService.sectionKey(for: "ヤマダ") == "や行") }
    @Test func katakanaSaConverted() { #expect(CardGroupingService.sectionKey(for: "サトウ") == "さ行") }

    // アルファベット（大文字・小文字統一）
    @Test func uppercaseA() { #expect(CardGroupingService.sectionKey(for: "Apple") == "A") }
    @Test func uppercaseZ() { #expect(CardGroupingService.sectionKey(for: "Zoom") == "Z") }
    @Test func lowercaseAlpha() { #expect(CardGroupingService.sectionKey(for: "apple") == "A") }

    // その他（漢字・絵文字・空文字列）
    @Test func kanjiIsOther()        { #expect(CardGroupingService.sectionKey(for: "山田") == "その他") }
    @Test func emojiIsOther()        { #expect(CardGroupingService.sectionKey(for: "😀") == "その他") }
    @Test func emptyStringIsOther()  { #expect(CardGroupingService.sectionKey(for: "") == "その他") }
}

// MARK: - groupByName テスト

@MainActor
struct CardGroupingServiceGroupByNameTests {

    @Test func groupsUsingLastNameReading() {
        let ctx = makeContext()
        let cards = [
            makeGroupCard(context: ctx, lastName: "山田", lastNameReading: "やまだ"),
            makeGroupCard(context: ctx, lastName: "佐藤", lastNameReading: "さとう")
        ]

        let sections = CardGroupingService.groupByName(cards, ascending: true)
        let keys = sections.map(\.title)
        #expect(keys.contains("さ行"))
        #expect(keys.contains("や行"))
    }

    @Test func fallsBackToLastNameWhenNoReading() {
        let ctx = makeContext()
        let card = makeGroupCard(context: ctx, lastName: "Yamada", lastNameReading: nil)

        let sections = CardGroupingService.groupByName([card], ascending: true)
        // lastNameReading なし → "Yamada" の先頭 Y → "Y" セクション
        #expect(sections.first?.title == "Y")
    }

    @Test func fallsBackToFirstNameWhenNoLastName() {
        let ctx = makeContext()
        let card = makeGroupCard(context: ctx, lastName: nil, lastNameReading: nil, firstName: "Taro")

        let sections = CardGroupingService.groupByName([card], ascending: true)
        #expect(sections.first?.title == "T")
    }

    @Test func descendingReversesSectionOrder() {
        let ctx = makeContext()
        let cards = [
            makeGroupCard(context: ctx, lastNameReading: "あいう"),
            makeGroupCard(context: ctx, lastNameReading: "やまだ")
        ]

        let asc  = CardGroupingService.groupByName(cards, ascending: true)
        let desc = CardGroupingService.groupByName(cards, ascending: false)

        #expect(asc.first?.title == "あ行")
        #expect(desc.first?.title == "や行")
    }
}

// MARK: - groupByCompany テスト

@MainActor
struct CardGroupingServiceGroupByCompanyTests {

    @Test func groupsByCompanyReadingPrefix() {
        let ctx = makeContext()
        let cards = [
            makeGroupCard(context: ctx, company: "株式会社テック", companyReading: "てっく"),
            makeGroupCard(context: ctx, company: "有限会社アルファ", companyReading: "あるふぁ")
        ]

        let sections = CardGroupingService.groupByCompany(cards, ascending: true)
        let keys = sections.map(\.title)
        #expect(keys.contains("あ行"))
        #expect(keys.contains("た行"))
    }

    @Test func cardsWithoutCompanyGoToTrailingSection() {
        let ctx = makeContext()
        let withCompany = makeGroupCard(context: ctx, company: "株式会社テック", companyReading: "てっく")
        let noCompany   = makeGroupCard(context: ctx, company: nil, companyReading: nil)

        let sections = CardGroupingService.groupByCompany([withCompany, noCompany], ascending: true)
        let last = sections.last
        #expect(last?.title == "（会社名なし）")
        #expect(last?.cards.count == 1)
    }

    @Test func onlyNoCompanyCardsProducesSingleTrailingSection() {
        let ctx = makeContext()
        let card = makeGroupCard(context: ctx, company: nil, companyReading: nil)

        let sections = CardGroupingService.groupByCompany([card], ascending: true)
        #expect(sections.count == 1)
        #expect(sections.first?.title == "（会社名なし）")
    }
}

// MARK: - groupByDate テスト

@MainActor
struct CardGroupingServiceGroupByDateTests {

    @Test func groupsTodayCard() {
        let ctx = makeContext()
        let card = makeGroupCard(context: ctx, lastName: "テスト")

        let sections = CardGroupingService.groupByDate([card], dateOf: { _ in Date() }, ascending: false)
        #expect(sections.first?.title == "今日")
    }

    @Test func groupsOldCardAsItBefore() {
        let ctx = makeContext()
        let card = makeGroupCard(context: ctx, lastName: "テスト")
        let oldDate = Calendar.current.date(byAdding: .year, value: -5, to: Date())!

        let sections = CardGroupingService.groupByDate([card], dateOf: { _ in oldDate }, ascending: false)
        #expect(sections.first?.title == "それ以前")
    }

    @Test func nilDateUsesDistantPast() {
        let ctx = makeContext()
        let card = makeGroupCard(context: ctx, lastName: "テスト")

        // dateOf が nil を返す場合 .distantPast → "それ以前" バケット
        let sections = CardGroupingService.groupByDate([card], dateOf: { _ in nil }, ascending: false)
        #expect(sections.first?.title == "それ以前")
    }

    @Test func ascendingReversesBucketOrder() {
        let ctx = makeContext()
        let todayCard = makeGroupCard(context: ctx, lastName: "今日")
        let oldCard   = makeGroupCard(context: ctx, lastName: "古い")
        let oldDate   = Calendar.current.date(byAdding: .year, value: -5, to: Date())!

        let desc = CardGroupingService.groupByDate(
            [todayCard, oldCard],
            dateOf: { $0 === todayCard ? Date() : oldDate },
            ascending: false
        )
        let asc = CardGroupingService.groupByDate(
            [todayCard, oldCard],
            dateOf: { $0 === todayCard ? Date() : oldDate },
            ascending: true
        )

        #expect(desc.first?.title == "今日")
        #expect(asc.first?.title == "それ以前")
    }

    @Test func emptyCardsReturnsEmptySections() {
        let sections = CardGroupingService.groupByDate([], dateOf: { _ in Date() }, ascending: false)
        #expect(sections.isEmpty)
    }
}
