import Testing
import Foundation
@testable import eMeishi

@MainActor
struct AISearchServicePrivacyTests {
    @Test func diagnosticCategoryNeverContainsQueryAssociatedValues() {
        let service = AISearchService()

        #expect(service.queryCategory(for: "東京都") == .location)
        #expect(service.queryCategory(for: "株式会社サンプル") == .company)
        #expect(service.queryCategory(for: "例示さん") == .name)
        #expect(service.queryCategory(for: "技術に強い担当者") == .conceptual)

        let safeValues = Set(AISearchQueryCategory.allLogValues)
        #expect(safeValues == ["location", "name", "company", "conceptual"])
    }

    @Test func fieldSearchUsesOnlySendableSnapshots() async {
        let expectedID = UUID()
        let cards = [
            makeSnapshot(
                id: expectedID,
                company: "例示販売株式会社",
                address: "例示県架空市"
            ),
            makeSnapshot(
                id: UUID(),
                company: "架空開発株式会社",
                address: "サンプル県見本市"
            ),
        ]

        let result = await AISearchService().search(query: "例示県", cards: cards)

        #expect(result.matchedCardIDs == [expectedID])
    }

    private func makeSnapshot(
        id: UUID,
        company: String,
        address: String
    ) -> AISearchCardSnapshot {
        AISearchCardSnapshot(
            id: id,
            fullName: "例示 一郎",
            lastName: "例示",
            firstName: "一郎",
            lastNameReading: "れいじ",
            firstNameReading: "いちろう",
            company: company,
            department: "営業部",
            title: "担当",
            address: address,
            notes: "",
            tagNames: ["営業"],
            hasPhone: false,
            hasEmail: false,
            createdAt: nil
        )
    }
}

private extension AISearchQueryCategory {
    static var allLogValues: [String] {
        [location, name, company, conceptual].map(\.rawValue)
    }
}
