import CoreData
import ImageIO
import UIKit

/// UIKit画像をactor境界の外へ返すための不変ラッパー。
/// UIImageは値として生成後に変更せず、SwiftUI表示専用として扱う。
nonisolated struct DecodedCardImage: @unchecked Sendable {
    let image: UIImage
}

/// Core Dataの画像属性変更イベントだけを追跡する、セッション内revision管理。
/// 全Data走査や部分サンプルによる衝突を避けつつ、非画像編集ではキャッシュを維持する。
private nonisolated final class CardImageRevisionStore: @unchecked Sendable {
    static let shared = CardImageRevisionStore()

    private let lock = NSLock()
    private var revisions: [NSManagedObjectID: UUID] = [:]
    private var observer: NSObjectProtocol?

    private init() {
        observer = NotificationCenter.default.addObserver(
            forName: .NSManagedObjectContextObjectsDidChange,
            object: nil,
            queue: nil
        ) { [weak self] notification in
            // changedValuesForCurrentEvent()は通知ターン内でだけ有効なため、
            // RunLoopへ遅延させず、発行元コンテキストのキュー上で抽出する。
            self?.consumeSynchronously(notification)
        }
    }

    func revision(for objectID: NSManagedObjectID) -> UUID {
        lock.lock()
        defer { lock.unlock() }
        if let revision = revisions[objectID] { return revision }
        let revision = UUID()
        revisions[objectID] = revision
        return revision
    }

    private func consumeSynchronously(_ notification: Notification) {
        guard let userInfo = notification.userInfo else { return }
        lock.lock()
        defer { lock.unlock() }
        if (userInfo[NSInvalidatedAllObjectsKey] as? Bool) == true {
            revisions.removeAll()
            return
        }

        let inserted = userInfo[NSInsertedObjectsKey] as? Set<NSManagedObject> ?? []
        let updated = userInfo[NSUpdatedObjectsKey] as? Set<NSManagedObject> ?? []
        let deleted = userInfo[NSDeletedObjectsKey] as? Set<NSManagedObject> ?? []

        for case let card as BusinessCard in inserted {
            revisions[card.objectID] = UUID()
        }
        for case let card as BusinessCard in updated
        where card.changedValuesForCurrentEvent().keys.contains("imageData") {
            revisions[card.objectID] = UUID()
        }
        // refreshは同じ永続値の再faultでも発生する。画像変更が確認できない通知で
        // revisionを進めると、詳細から戻った直後だけ全サムネイルが失効するため無視する。
        // CloudKitを含む実際の属性mergeはupdatedObjectsの変更キーで判定する。
        for case let card as BusinessCard in deleted {
            revisions[card.objectID] = nil
        }
    }
}

/// View評価を止めない定数時間のキャッシュキーを作る。
@MainActor
enum CardImageCacheKey {
    static func businessCard(_ card: BusinessCard) -> String {
        let objectID = card.objectID.uriRepresentation().absoluteString
        let revision = CardImageRevisionStore.shared.revision(for: card.objectID)
        return "\(objectID)|\(revision.uuidString)"
    }

    /// 既存呼出しとの互換。Dataはキー生成に読まず、画像変更通知のrevisionを使用する。
    static func businessCard(_ card: BusinessCard, data: Data) -> String {
        businessCard(card)
    }

    static func transient(owner: ObjectIdentifier, revision: UUID, dataCount: Int) -> String {
        "transient|\(owner)|\(revision.uuidString)|\(dataCount)"
    }

}

nonisolated enum StoredCardImageLoadResult: @unchecked Sendable {
    case image(DecodedCardImage)
    case missing
    case invalid
}

/// actor外からもキャッシュヒットだけを同期取得できる、ロック付き画像キャッシュ。
/// 詳細から一覧へ戻った最初の描画でプレースホルダーを挟まないために使用する。
private nonisolated final class CardImageCacheStore: @unchecked Sendable {
    private let lock = NSLock()
    private let cache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 100
        cache.totalCostLimit = 48 * 1_024 * 1_024
        return cache
    }()

    func image(forKey key: NSString) -> UIImage? {
        lock.lock()
        defer { lock.unlock() }
        return cache.object(forKey: key)
    }

    func insert(_ image: UIImage, forKey key: NSString, cost: Int) {
        lock.lock()
        defer { lock.unlock() }
        cache.setObject(image, forKey: key, cost: cost)
    }
}

/// 一覧・詳細用画像を表示サイズに合わせて縮小デコードし、再描画時の全画像デコードを避ける。
actor CardImageDecodingService {
    static let shared = CardImageDecodingService()

    private nonisolated let cache = CardImageCacheStore()
    /// 画像ごとにprivate contextを生成すると、一覧初期表示で行数分の生成コストが発生する。
    /// coordinator単位で読取専用contextを再利用し、各読取り後にresetしてBLOBを保持しない。
    private var readContexts: [ObjectIdentifier: NSManagedObjectContext] = [:]

    nonisolated func cachedImage(
        maximumPixelSize: CGFloat,
        cacheIdentifier: String
    ) -> DecodedCardImage? {
        let key = cacheKey(
            maximumPixelSize: maximumPixelSize,
            cacheIdentifier: cacheIdentifier
        )
        return cache.image(forKey: key).map(DecodedCardImage.init(image:))
    }

    func image(
        from data: Data,
        maximumPixelSize: CGFloat,
        cacheIdentifier: String
    ) -> DecodedCardImage? {
        guard !Task.isCancelled else { return nil }
        let key = cacheKey(
            maximumPixelSize: maximumPixelSize,
            cacheIdentifier: cacheIdentifier
        )
        if let cached = cache.image(forKey: key) {
            return DecodedCardImage(image: cached)
        }

        let pixelSize = max(1, Int(maximumPixelSize.rounded(.up)))

        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        guard !Task.isCancelled else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: pixelSize,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        guard !Task.isCancelled else { return nil }

        let image = UIImage(cgImage: cgImage)
        guard !Task.isCancelled else { return nil }
        cache.insert(
            image,
            forKey: key,
            cost: cgImage.bytesPerRow * cgImage.height
        )
        return DecodedCardImage(image: image)
    }

    /// ViewのbodyやMainActor contextで画像BLOBをfaultせず、表示対象の1件だけを
    /// private queue contextから取得して縮小デコードする。
    func storedImage(
        objectURI: URL,
        coordinatorReference: PersistentStoreCoordinatorReference,
        maximumPixelSize: CGFloat,
        cacheIdentifier: String
    ) async -> StoredCardImageLoadResult {
        if let cached = cachedImage(
            maximumPixelSize: maximumPixelSize,
            cacheIdentifier: cacheIdentifier
        ) {
            return .image(cached)
        }
        guard !Task.isCancelled else { return .invalid }

        let coordinator = coordinatorReference.coordinator
        guard let objectID = coordinator.managedObjectID(forURIRepresentation: objectURI) else {
            return .invalid
        }
        let context = readContext(for: coordinator)

        let data: Data?
        do {
            data = try await context.perform {
                defer { context.reset() }
                let object = try context.existingObject(with: objectID)
                return object.value(forKey: "imageData") as? Data
            }
        } catch {
            return .invalid
        }
        guard !Task.isCancelled else { return .invalid }
        guard let data else { return .missing }
        guard let decoded = image(
            from: data,
            maximumPixelSize: maximumPixelSize,
            cacheIdentifier: cacheIdentifier
        ) else {
            return .invalid
        }
        return .image(decoded)
    }

    private func readContext(
        for coordinator: NSPersistentStoreCoordinator
    ) -> NSManagedObjectContext {
        let key = ObjectIdentifier(coordinator)
        if let context = readContexts[key] {
            return context
        }

        let context = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
        context.persistentStoreCoordinator = coordinator
        context.undoManager = nil
        context.mergePolicy = NSMergePolicy.mergeByPropertyObjectTrump
        readContexts[key] = context
        return context
    }


    private nonisolated func cacheKey(
        maximumPixelSize: CGFloat,
        cacheIdentifier: String
    ) -> NSString {
        let pixelSize = max(1, Int(maximumPixelSize.rounded(.up)))
        return "\(cacheIdentifier)-\(pixelSize)" as NSString
    }
}
