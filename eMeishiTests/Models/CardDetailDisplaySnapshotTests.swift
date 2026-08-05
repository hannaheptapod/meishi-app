import CoreData
import Foundation
import Testing
@testable import eMeishi

@MainActor
struct CardDetailDisplaySnapshotTests {
    @Test func capturesRelationshipsAndContactValuesOnce() throws {
        let context = makeTestContext()
        let card = makeCard(
            context: context,
            lastName: "試験",
            lastNameReading: "しけん",
            firstName: "一号",
            firstNameReading: "いちごう",
            company: "合成会社",
            department: "検証部",
            title: "担当",
            email: "tester@example.invalid",
            phone: "000-0000\n111-1111",
            address: "合成市1-2-3",
            website: "example.invalid",
            notes: "合成メモ"
        )
        let tag = Tag(context: context)
        tag.id = UUID()
        tag.name = "合成タグ"
        tag.colorHex = "#34C759"
        card.addToTags(tag)
        try context.obtainPermanentIDs(for: [card, tag])

        let snapshot = CardDetailDisplaySnapshot(card: card)

        #expect(snapshot.displayName == "試験 一号")
        #expect(snapshot.affiliation == "検証部 · 担当")
        #expect(snapshot.contacts.map(\.kind) == [.phone, .phone, .email, .address, .website])
        #expect(snapshot.previewContacts.map(\.value) == ["000-0000", "111-1111"])
        #expect(snapshot.contacts.first?.destination?.scheme == "tel")
        #expect(snapshot.contacts.first { $0.kind == .email }?.destination?.scheme == "mailto")
        #expect(snapshot.contacts.first { $0.kind == .website }?.destination?.scheme == "https")
        #expect(snapshot.tags == [
            CardDetailTagSnapshot(
                id: tag.objectID.uriRepresentation().absoluteString,
                name: "合成タグ",
                colorHex: "#34C759"
            )
        ])

        // 描画中に管理オブジェクトが変わっても、既存snapshotは混在状態にならない。
        card.phone = "222-2222"
        card.removeFromTags(tag)
        #expect(snapshot.previewContacts.map(\.value) == ["000-0000", "111-1111"])
        #expect(snapshot.tags.count == 1)

        let refreshed = CardDetailDisplaySnapshot(card: card)
        #expect(refreshed.previewContacts.map(\.value) == ["222-2222", "tester@example.invalid"])
        #expect(refreshed.tags.isEmpty)
    }
}
