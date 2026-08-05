import Foundation
import Testing
@testable import eMeishi

struct CardListItemSnapshotTests {
    @Test func favoriteUpdateKeepsRowAndDetailInOneGeneration() throws {
        let objectURI = try #require(URL(string: "x-coredata://fixture/BusinessCard/p1"))
        let detail = CardDetailDisplaySnapshot(
            objectURI: objectURI,
            lastName: "合成姓",
            lastNameReading: "ごうせいせい",
            firstName: "合成名",
            firstNameReading: "ごうせいめい",
            company: "合成会社",
            department: "検証部",
            title: "担当",
            phone: "000-0000",
            email: "fixture@example.invalid",
            address: "",
            website: "https://example.invalid",
            notes: "",
            createdAt: Date(timeIntervalSinceReferenceDate: 100),
            isFavorite: false,
            tags: [
                CardDetailTagSnapshot(
                    id: "x-coredata://fixture/Tag/p1",
                    name: "合成タグ",
                    colorHex: "#34C759"
                )
            ]
        )
        let item = CardListItemSnapshot(
            id: objectURI,
            row: CardRowDisplaySnapshot(
                displayName: detail.displayName,
                company: detail.company,
                affiliation: detail.affiliation,
                isFavorite: false,
                firstTag: CardRowTagSnapshot(name: "合成タグ", colorHex: "#34C759"),
                additionalTagCount: 0,
                accessibilityLabel: "合成名刺"
            ),
            detail: detail,
            imageIdentifier: "fixture-image-revision"
        )

        let updated = item.settingFavorite(true)

        #expect(updated.id == objectURI)
        #expect(updated.imageIdentifier == item.imageIdentifier)
        #expect(updated.row.isFavorite)
        #expect(updated.detail.isFavorite)
        #expect(updated.row.displayName == item.row.displayName)
        #expect(updated.detail.contacts == item.detail.contacts)
        #expect(updated.detail.tags == item.detail.tags)
    }

    @Test func sectionIdentityDoesNotDependOnManagedObjects() throws {
        let first = try makeItem(path: "p1", displayName: "合成名一")
        let second = try makeItem(path: "p2", displayName: "合成名二")

        let section = CardListItemSection(
            id: "fixture-section",
            title: "合成区分",
            items: [first, second]
        )

        #expect(section.id == "fixture-section")
        #expect(section.items.map(\.id) == [first.id, second.id])
        #expect(Set(section.items.map(\.id)).count == 2)
    }

    private func makeItem(path: String, displayName: String) throws -> CardListItemSnapshot {
        let objectURI = try #require(URL(string: "x-coredata://fixture/BusinessCard/\(path)"))
        let detail = CardDetailDisplaySnapshot(
            objectURI: objectURI,
            lastName: displayName,
            lastNameReading: "",
            firstName: "",
            firstNameReading: "",
            company: "合成会社",
            department: "",
            title: "",
            phone: "",
            email: "",
            address: "",
            website: "",
            notes: "",
            createdAt: nil,
            isFavorite: false,
            tags: []
        )
        return CardListItemSnapshot(
            id: objectURI,
            row: CardRowDisplaySnapshot(
                displayName: displayName,
                company: "合成会社",
                affiliation: "",
                isFavorite: false,
                firstTag: nil,
                additionalTagCount: 0,
                accessibilityLabel: displayName
            ),
            detail: detail,
            imageIdentifier: "fixture-image-\(path)"
        )
    }
}
