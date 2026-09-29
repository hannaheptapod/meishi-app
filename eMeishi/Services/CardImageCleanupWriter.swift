import CoreData

/// 保存済み名刺の画像だけを一括で外すwriter（Issue #203）。
/// テキスト項目・タグは変更しない。`updatedAt`も更新しない（更新日順の並びを一括整理で崩さないため）。
/// MainActorへ`NSManagedObject`を返さず、件数だけを返す。
actor CardImageCleanupWriter {
    /// 1回のsaveで扱う件数。画像Dataの展開量を抑えるため、保存ごとにcontextを空にする。
    private let batchSize: Int

    init(batchSize: Int = 50) {
        self.batchSize = max(1, batchSize)
    }

    /// 画像を持つ名刺の件数。countのみ実行し、画像Dataは読み込まない。
    func countCardsWithImage(
        coordinatorReference: PersistentStoreCoordinatorReference
    ) async throws -> Int {
        try Task.checkCancellation()
        let context = makeContext(
            name: "CardImageCountReader",
            coordinatorReference: coordinatorReference
        )
        return try await context.perform {
            try context.count(for: Self.cardsWithImageRequest())
        }
    }

    /// 全名刺の`imageData`をnilにし、画像を外した件数を返す。
    /// batchごとに保存するため、途中で取り消された場合もそれまでの削除は確定する。
    /// SQLiteの空き領域はCore Dataの保存後メンテナンス（incremental_vacuum）で回収される。
    func removeAllImages(
        coordinatorReference: PersistentStoreCoordinatorReference
    ) async throws -> Int {
        try Task.checkCancellation()
        let context = makeContext(
            name: "CardImageCleanupWriter",
            coordinatorReference: coordinatorReference
        )
        let batchSize = batchSize
        return try await context.perform {
            var removedCount = 0
            do {
                while true {
                    try Task.checkCancellation()
                    let request = Self.cardsWithImageRequest()
                    request.fetchLimit = batchSize
                    let cards = try context.fetch(request)
                    guard !cards.isEmpty else { break }

                    for card in cards {
                        card.setValue(nil, forKey: "imageData")
                    }
                    try context.save()
                    removedCount += cards.count
                    // 保存済みbatchの画像Dataをcontextから解放する。
                    // 保存済みの行は述語（imageData != nil）に一致しないため、次のfetchには含まれない。
                    context.reset()
                }
                return removedCount
            } catch {
                context.rollback()
                throw error
            }
        }
    }

    private nonisolated static func cardsWithImageRequest() -> NSFetchRequest<NSManagedObject> {
        let request = NSFetchRequest<NSManagedObject>(entityName: "BusinessCard")
        request.predicate = NSPredicate(format: "imageData != nil")
        return request
    }

    private nonisolated func makeContext(
        name: String,
        coordinatorReference: PersistentStoreCoordinatorReference
    ) -> NSManagedObjectContext {
        let context = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
        context.persistentStoreCoordinator = coordinatorReference.coordinator
        context.name = name
        context.undoManager = nil
        context.mergePolicy = NSMergePolicy.mergeByPropertyObjectTrump
        return context
    }
}
