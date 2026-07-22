import CoreData
import Foundation
import Testing
@testable import eMeishi

@MainActor
struct BulkAutoTagWriterTests {
    @Test func appliesSuggestionOnlyWhenCardRevisionStillMatches() async throws {
        let context = makeTestContext()
        let card = makeCard(context: context, company: "例示販売株式会社")
        let initialRevision = Date(timeIntervalSince1970: 1_000)
        card.updatedAt = initialRevision

        let tag = Tag(context: context)
        tag.id = UUID()
        tag.name = "合成タグ"
        tag.colorHex = "#007AFF"
        try context.save()

        let coordinator = try #require(context.persistentStoreCoordinator)
        let result = try await BulkAutoTagWriter().apply(
            suggestions: [
                BulkAutoTagSuggestion(
                    objectURI: card.objectID.uriRepresentation(),
                    expectedUpdatedAt: initialRevision,
                    tagIDs: [try #require(tag.id)]
                ),
            ],
            coordinatorReference: PersistentStoreCoordinatorReference(coordinator: coordinator)
        )

        context.refresh(card, mergeChanges: false)
        #expect(result.updatedObjectURIs == [card.objectID.uriRepresentation()])
        #expect((card.tags as? Set<eMeishi.Tag>)?.contains(where: { $0.id == tag.id }) == true)
    }

    @Test func rejectsSuggestionAfterConcurrentEdit() async throws {
        let context = makeTestContext()
        let card = makeCard(context: context, company: "架空開発株式会社")
        let initialRevision = Date(timeIntervalSince1970: 2_000)
        card.updatedAt = initialRevision

        let tag = Tag(context: context)
        tag.id = UUID()
        tag.name = "検証タグ"
        tag.colorHex = "#34C759"
        try context.save()

        card.updatedAt = Date(timeIntervalSince1970: 3_000)
        try context.save()

        let coordinator = try #require(context.persistentStoreCoordinator)
        let result = try await BulkAutoTagWriter().apply(
            suggestions: [
                BulkAutoTagSuggestion(
                    objectURI: card.objectID.uriRepresentation(),
                    expectedUpdatedAt: initialRevision,
                    tagIDs: [try #require(tag.id)]
                ),
            ],
            coordinatorReference: PersistentStoreCoordinatorReference(coordinator: coordinator)
        )

        context.refresh(card, mergeChanges: false)
        #expect(result.updatedObjectURIs.isEmpty)
        #expect(result.staleObjectCount == 1)
        #expect((card.tags as? Set<eMeishi.Tag>)?.isEmpty != false)
    }
}
