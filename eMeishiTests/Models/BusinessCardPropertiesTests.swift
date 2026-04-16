import Testing
import CoreData
@testable import eMeishi

// MARK: - BusinessCard 計算プロパティ テスト

@MainActor
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
