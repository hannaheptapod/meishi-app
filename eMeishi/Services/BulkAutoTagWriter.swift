import CoreData
import Foundation

/// 一括AIタグ提案へ渡す、管理オブジェクト非依存の入力。
nonisolated struct BulkAutoTagCardSnapshot: Equatable, Sendable {
    let objectURI: URL
    let updatedAt: Date?
    let cardInfo: AutoTagService.CardInfo
}

/// 推論開始時のカード世代と提案タグを結び付ける。
nonisolated struct BulkAutoTagSuggestion: Equatable, Sendable {
    let objectURI: URL
    let expectedUpdatedAt: Date?
    let tagIDs: Set<UUID>
}

nonisolated struct BulkAutoTagWriteResult: Equatable, Sendable {
    let updatedObjectURIs: [URL]
    let staleObjectCount: Int
}

/// AI推論後のタグ反映をprivate queueで原子的に保存する。
/// 推論中に編集されたカードは`updatedAt`照合で除外し、古い結果で上書きしない。
actor BulkAutoTagWriter {
    func apply(
        suggestions: [BulkAutoTagSuggestion],
        coordinatorReference: PersistentStoreCoordinatorReference
    ) async throws -> BulkAutoTagWriteResult {
        try Task.checkCancellation()
        guard !suggestions.isEmpty else {
            return BulkAutoTagWriteResult(updatedObjectURIs: [], staleObjectCount: 0)
        }

        let context = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
        context.persistentStoreCoordinator = coordinatorReference.coordinator
        context.name = "BulkAutoTagWriter"
        context.undoManager = nil

        return try await context.perform {
            try Task.checkCancellation()

            let allTagIDs = Set(suggestions.flatMap(\.tagIDs))
            let tagRequest = NSFetchRequest<NSManagedObject>(entityName: "Tag")
            tagRequest.predicate = NSPredicate(format: "id IN %@", Array(allTagIDs))
            tagRequest.returnsObjectsAsFaults = false
            let tagsByID = Dictionary(
                uniqueKeysWithValues: try context.fetch(tagRequest).compactMap { tag in
                    (tag.value(forKey: "id") as? UUID).map { ($0, tag) }
                }
            )

            var updatedObjectURIs: [URL] = []
            var staleObjectCount = 0

            for suggestion in suggestions {
                try Task.checkCancellation()
                guard let objectID = coordinatorReference.coordinator.managedObjectID(
                    forURIRepresentation: suggestion.objectURI
                ), let card = try? context.existingObject(with: objectID), !card.isDeleted else {
                    staleObjectCount += 1
                    continue
                }

                let currentUpdatedAt = card.value(forKey: "updatedAt") as? Date
                guard currentUpdatedAt == suggestion.expectedUpdatedAt else {
                    staleObjectCount += 1
                    continue
                }

                let relationship = card.mutableSetValue(forKey: "tags")
                var addedAny = false
                for tagID in suggestion.tagIDs {
                    guard let tag = tagsByID[tagID], !relationship.contains(tag) else { continue }
                    relationship.add(tag)
                    addedAny = true
                }
                guard addedAny else { continue }

                card.setValue(Date(), forKey: "updatedAt")
                updatedObjectURIs.append(suggestion.objectURI)
            }

            try Task.checkCancellation()
            if context.hasChanges {
                try context.save()
            }
            return BulkAutoTagWriteResult(
                updatedObjectURIs: updatedObjectURIs,
                staleObjectCount: staleObjectCount
            )
        }
    }
}
