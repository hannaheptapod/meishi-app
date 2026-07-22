import CoreGraphics
import CoreData
import Testing
import UIKit
@testable import eMeishi

@MainActor
struct CardThumbnailServiceTests {
    @Test func landscapeLongEdgeFitsInvisibleFrame() {
        let size = CardThumbnailService.displaySize(for: CGSize(width: 200, height: 100))
        #expect(abs(size.width - 64) < 0.001)
        #expect(abs(size.height - 32) < 0.001)
    }

    @Test func portraitLongEdgeFitsInvisibleFrame() {
        let size = CardThumbnailService.displaySize(for: CGSize(width: 100, height: 200))
        #expect(abs(size.width - 32) < 0.001)
        #expect(abs(size.height - 64) < 0.001)
    }

    @Test func thumbnailCanScaleUpWithoutCropping() {
        let size = CardThumbnailService.displaySize(for: CGSize(width: 20, height: 10))
        #expect(abs(size.width - 64) < 0.001)
        #expect(abs(size.height - 32) < 0.001)
    }

    @Test func displayDecoderDownsamplesBeforeRendering() async throws {
        let source = UIGraphicsImageRenderer(size: CGSize(width: 1_200, height: 600)).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 1_200, height: 600))
        }
        let data = try #require(source.jpegData(compressionQuality: 0.9))
        let decoded = try #require(
            await CardImageDecodingService.shared.image(
                from: data,
                maximumPixelSize: 120,
                cacheIdentifier: "downsample-test"
            )
        )

        #expect(decoded.image.size.width <= 120)
        #expect(decoded.image.size.height <= 120)
        #expect(abs((decoded.image.size.width / decoded.image.size.height) - 2) < 0.01)
        let cached = CardImageDecodingService.shared.cachedImage(
            maximumPixelSize: 120,
            cacheIdentifier: "downsample-test"
        )
        #expect(cached != nil)
    }

    @Test func imageCacheKeyIgnoresNonImageCardUpdates() throws {
        let controller = PersistenceController(inMemory: true)
        let context = controller.container.viewContext
        let card = BusinessCard(context: context)
        card.id = UUID()
        card.updatedAt = Date(timeIntervalSinceReferenceDate: 100)
        let data = Data([0x01, 0x02, 0x03, 0x04])
        card.imageData = data
        try context.obtainPermanentIDs(for: [card])

        let firstKey = CardImageCacheKey.businessCard(card, data: data)
        card.updatedAt = Date(timeIntervalSinceReferenceDate: 200)
        card.isFavorite.toggle()
        let secondKey = CardImageCacheKey.businessCard(card, data: data)

        #expect(firstKey == secondKey)
    }

    @Test func imageCacheKeyChangesWhenSameLengthImageContentChanges() throws {
        let controller = PersistenceController(inMemory: true)
        let context = controller.container.viewContext
        let card = BusinessCard(context: context)
        card.id = UUID()
        try context.obtainPermanentIDs(for: [card])

        let firstData = Data(repeating: 0x11, count: 1_024)
        var secondData = firstData
        secondData[417] = 0x22
        card.imageData = firstData
        try context.save()
        let firstKey = CardImageCacheKey.businessCard(card, data: firstData)

        card.imageData = secondData
        context.processPendingChanges()
        let secondKey = CardImageCacheKey.businessCard(card, data: secondData)

        #expect(firstKey != secondKey)
    }

    @Test func corruptedImageDataFailsWithoutCachingAPlaceholder() async {
        let identifier = "synthetic-corrupted-image"
        let decoded = await CardImageDecodingService.shared.image(
            from: Data([0x00, 0x01, 0x02, 0x03]),
            maximumPixelSize: 120,
            cacheIdentifier: identifier
        )

        #expect(decoded == nil)
        #expect(
            CardImageDecodingService.shared.cachedImage(
                maximumPixelSize: 120,
                cacheIdentifier: identifier
            ) == nil
        )
    }

    @Test func storedImageLoadsFromPrivateContextAndPopulatesCache() async throws {
        let controller = PersistenceController(inMemory: true)
        let context = controller.container.viewContext
        let card = BusinessCard(context: context)
        card.id = UUID()
        let source = UIGraphicsImageRenderer(size: CGSize(width: 240, height: 120)).image { context in
            UIColor.systemTeal.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 240, height: 120))
        }
        card.imageData = source.jpegData(compressionQuality: 0.9)
        try context.save()

        let identifier = "stored-image-\(UUID().uuidString)"
        let result = await CardImageDecodingService.shared.storedImage(
            objectURI: card.objectID.uriRepresentation(),
            coordinatorReference: PersistentStoreCoordinatorReference(
                coordinator: controller.container.persistentStoreCoordinator
            ),
            maximumPixelSize: 120,
            cacheIdentifier: identifier
        )

        guard case .image(let decoded) = result else {
            Issue.record("保存済み画像を読み込めませんでした")
            return
        }
        #expect(decoded.image.size.width <= 120)
        #expect(decoded.image.size.height <= 120)
        #expect(
            CardImageDecodingService.shared.cachedImage(
                maximumPixelSize: 120,
                cacheIdentifier: identifier
            ) != nil
        )
    }

    @Test func storedImageDistinguishesMissingAndCorruptedData() async throws {
        let controller = PersistenceController(inMemory: true)
        let context = controller.container.viewContext
        let missingCard = BusinessCard(context: context)
        missingCard.id = UUID()
        let corruptedCard = BusinessCard(context: context)
        corruptedCard.id = UUID()
        corruptedCard.imageData = Data([0x00, 0x01, 0x02, 0x03])
        try context.save()
        let coordinator = PersistentStoreCoordinatorReference(
            coordinator: controller.container.persistentStoreCoordinator
        )

        let missing = await CardImageDecodingService.shared.storedImage(
            objectURI: missingCard.objectID.uriRepresentation(),
            coordinatorReference: coordinator,
            maximumPixelSize: 120,
            cacheIdentifier: "missing-image-\(UUID().uuidString)"
        )
        let corrupted = await CardImageDecodingService.shared.storedImage(
            objectURI: corruptedCard.objectID.uriRepresentation(),
            coordinatorReference: coordinator,
            maximumPixelSize: 120,
            cacheIdentifier: "corrupted-image-\(UUID().uuidString)"
        )

        guard case .missing = missing else {
            Issue.record("画像なしをmissingとして扱えませんでした")
            return
        }
        guard case .invalid = corrupted else {
            Issue.record("破損画像をinvalidとして扱えませんでした")
            return
        }
    }
}
