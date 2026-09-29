import CoreData
import Foundation
import Testing
@testable import eMeishi

@MainActor
struct CardImageCleanupWriterTests {
    @Test func removesOnlyImagesAndKeepsTextAndUpdatedAt() async throws {
        let context = makeTestContext()
        let revision = Date(timeIntervalSince1970: 1_000)
        let first = makeCard(context: context, lastName: "山田", company: "例示商事株式会社")
        first.imageData = Data(repeating: 0x01, count: 64)
        first.updatedAt = revision
        let second = makeCard(context: context, lastName: "佐藤")
        second.imageData = Data(repeating: 0x02, count: 64)
        second.updatedAt = revision
        let textOnly = makeCard(context: context, lastName: "鈴木")
        textOnly.updatedAt = revision
        try context.save()

        let coordinator = try #require(context.persistentStoreCoordinator)
        let reference = PersistentStoreCoordinatorReference(coordinator: coordinator)
        // batch境界をまたぐ経路を通すため、1件ずつ保存させる。
        let writer = CardImageCleanupWriter(batchSize: 1)

        #expect(try await writer.countCardsWithImage(coordinatorReference: reference) == 2)
        let removed = try await writer.removeAllImages(coordinatorReference: reference)
        #expect(removed == 2)
        #expect(try await writer.countCardsWithImage(coordinatorReference: reference) == 0)

        context.refreshAllObjects()
        for card in [first, second, textOnly] {
            #expect(card.imageData == nil)
            #expect(card.updatedAt == revision)
        }
        #expect(first.lastName == "山田")
        #expect(first.company == "例示商事株式会社")
        #expect(second.lastName == "佐藤")
    }

    @Test func returnsZeroWhenNoCardHasImage() async throws {
        let context = makeTestContext()
        _ = makeCard(context: context, lastName: "高橋")
        try context.save()

        let coordinator = try #require(context.persistentStoreCoordinator)
        let removed = try await CardImageCleanupWriter().removeAllImages(
            coordinatorReference: PersistentStoreCoordinatorReference(coordinator: coordinator)
        )
        #expect(removed == 0)
    }
}
