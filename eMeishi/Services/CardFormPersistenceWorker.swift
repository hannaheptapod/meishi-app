import CoreData
import Foundation

/// 編集対象を private context で再取得するための不変参照。
/// `BusinessCard` 自体は View / actor 境界を越えない。
nonisolated struct CardFormEditReference: Equatable, Sendable {
    let objectURI: URL
}

/// 編集開始時点の更新日時とレコードIDを保持し、保存前の競合検出に使う。
nonisolated struct CardFormEditGeneration: Equatable, Sendable {
    let objectURI: URL
    let recordID: UUID?
    let updatedAt: Date?
}

/// 編集フォームへ一括反映する値型スナップショット。
nonisolated struct CardFormEditSnapshot: Equatable, Sendable {
    let generation: CardFormEditGeneration
    let lastName: String
    let lastNameReading: String
    let firstName: String
    let firstNameReading: String
    let company: String
    let companyReading: String
    let department: String
    let title: String
    let email: String
    let phones: [String]
    let address: String
    let website: String
    let notes: String
    let imageData: Data?
    let selectedTagIDs: Set<UUID>
}

nonisolated enum CardFormImageUpdate: Equatable, Sendable {
    case preserveExisting
    case replace(Data?)
}

/// private writer context へ渡す保存値。管理オブジェクトを含めない。
nonisolated struct CardFormSavePayload: Equatable, Sendable {
    let lastName: String
    let lastNameReading: String
    let firstName: String
    let firstNameReading: String
    let company: String
    let companyReading: String
    let department: String
    let title: String
    let email: String
    let phone: String
    let address: String
    let website: String
    let notes: String
    let imageUpdate: CardFormImageUpdate
    let selectedTagIDs: Set<UUID>
}

nonisolated enum CardFormSaveChangeKind: Equatable, Sendable {
    case inserted
    case updated
}

nonisolated struct CardFormSaveResult: Equatable, Sendable {
    let generation: CardFormEditGeneration
    let changeKind: CardFormSaveChangeKind
}

nonisolated struct CardFormTagInfoSnapshot: Equatable, Sendable {
    let id: UUID
    let name: String
}

nonisolated enum CardFormPersistenceError: LocalizedError, Equatable, Sendable {
    case invalidObjectReference
    case cardNoLongerExists
    case cardChangedSinceEditingBegan
    case saveAlreadyInProgress

    var errorDescription: String? {
        switch self {
        case .invalidObjectReference:
            return "編集対象の名刺を確認できませんでした。"
        case .cardNoLongerExists:
            return "この名刺はすでに削除されています。"
        case .cardChangedSinceEditingBegan:
            return "別の画面または端末で名刺が更新されました。いったん閉じて最新の内容を確認してください。"
        case .saveAlreadyInProgress:
            return "名刺を保存しています。"
        }
    }
}

/// CardForm の読込み・保存を private queue に閉じ込める。
/// 大きな画像BLOBとto-many relationshipをMainActor上でfaultさせない。
actor CardFormPersistenceWorker {
    func loadEditSnapshot(
        reference: CardFormEditReference,
        coordinatorReference: PersistentStoreCoordinatorReference
    ) async throws -> CardFormEditSnapshot {
        try Task.checkCancellation()
        let context = makeContext(
            name: "CardFormEditSnapshotLoader",
            coordinatorReference: coordinatorReference
        )

        return try await context.perform {
            try Task.checkCancellation()
            guard let objectID = coordinatorReference.coordinator.managedObjectID(
                forURIRepresentation: reference.objectURI
            ) else {
                throw CardFormPersistenceError.invalidObjectReference
            }

            let object: NSManagedObject
            do {
                object = try context.existingObject(with: objectID)
            } catch {
                throw CardFormPersistenceError.cardNoLongerExists
            }
            guard !object.isDeleted else {
                throw CardFormPersistenceError.cardNoLongerExists
            }

            let tags = (object.value(forKey: "tags") as? NSSet)?.allObjects ?? []
            let tagIDs = Set(tags.compactMap { tag in
                (tag as? NSManagedObject)?.value(forKey: "id") as? UUID
            })
            try Task.checkCancellation()
            let phone = Self.string(object, key: "phone")
            let phones = phone.components(separatedBy: "\n")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }

            return CardFormEditSnapshot(
                generation: CardFormEditGeneration(
                    objectURI: object.objectID.uriRepresentation(),
                    recordID: object.value(forKey: "id") as? UUID,
                    updatedAt: object.value(forKey: "updatedAt") as? Date
                ),
                lastName: Self.string(object, key: "lastName"),
                lastNameReading: Self.string(object, key: "lastNameReading"),
                firstName: Self.string(object, key: "firstName"),
                firstNameReading: Self.string(object, key: "firstNameReading"),
                company: Self.string(object, key: "company"),
                companyReading: Self.string(object, key: "companyReading"),
                department: Self.string(object, key: "department"),
                title: Self.string(object, key: "title"),
                email: Self.string(object, key: "email"),
                phones: phones.isEmpty ? [""] : phones,
                address: Self.string(object, key: "address"),
                website: Self.string(object, key: "website"),
                notes: Self.string(object, key: "notes"),
                imageData: object.value(forKey: "imageData") as? Data,
                selectedTagIDs: tagIDs
            )
        }
    }

    func loadTagInfos(
        coordinatorReference: PersistentStoreCoordinatorReference
    ) async throws -> [CardFormTagInfoSnapshot] {
        try Task.checkCancellation()
        let context = makeContext(
            name: "CardFormTagInfoLoader",
            coordinatorReference: coordinatorReference
        )
        return try await context.perform {
            try Task.checkCancellation()
            let request = NSFetchRequest<NSManagedObject>(entityName: "Tag")
            request.sortDescriptors = [NSSortDescriptor(key: "sortOrder", ascending: true)]
            request.fetchBatchSize = 100
            let tags = try context.fetch(request)
            try Task.checkCancellation()
            return tags.compactMap { tag in
                guard let id = tag.value(forKey: "id") as? UUID,
                      let name = tag.value(forKey: "name") as? String else {
                    return nil
                }
                return CardFormTagInfoSnapshot(id: id, name: name)
            }
        }
    }

    func save(
        payload: CardFormSavePayload,
        editing generation: CardFormEditGeneration?,
        coordinatorReference: PersistentStoreCoordinatorReference,
        now: Date = Date()
    ) async throws -> CardFormSaveResult {
        try Task.checkCancellation()
        let context = makeContext(
            name: "CardFormPrivateWriter",
            coordinatorReference: coordinatorReference
        )
        context.mergePolicy = NSMergePolicy.error

        return try await context.perform {
            do {
                try Task.checkCancellation()

                let object: NSManagedObject
                let changeKind: CardFormSaveChangeKind
                if let generation {
                    guard let objectID = coordinatorReference.coordinator.managedObjectID(
                        forURIRepresentation: generation.objectURI
                    ) else {
                        throw CardFormPersistenceError.invalidObjectReference
                    }
                    do {
                        object = try context.existingObject(with: objectID)
                    } catch {
                        throw CardFormPersistenceError.cardNoLongerExists
                    }
                    guard !object.isDeleted else {
                        throw CardFormPersistenceError.cardNoLongerExists
                    }
                    let currentRecordID = object.value(forKey: "id") as? UUID
                    let currentUpdatedAt = object.value(forKey: "updatedAt") as? Date
                    guard currentRecordID == generation.recordID,
                          currentUpdatedAt == generation.updatedAt else {
                        throw CardFormPersistenceError.cardChangedSinceEditingBegan
                    }
                    changeKind = .updated
                } else {
                    object = NSEntityDescription.insertNewObject(
                        forEntityName: "BusinessCard",
                        into: context
                    )
                    object.setValue(UUID(), forKey: "id")
                    object.setValue(now, forKey: "createdAt")
                    changeKind = .inserted
                }

                object.setValue(payload.lastName, forKey: "lastName")
                object.setValue(payload.lastNameReading, forKey: "lastNameReading")
                object.setValue(payload.firstName, forKey: "firstName")
                object.setValue(payload.firstNameReading, forKey: "firstNameReading")
                object.setValue(payload.company, forKey: "company")
                object.setValue(payload.companyReading, forKey: "companyReading")
                object.setValue(payload.department, forKey: "department")
                object.setValue(payload.title, forKey: "title")
                object.setValue(payload.email, forKey: "email")
                object.setValue(payload.phone, forKey: "phone")
                object.setValue(payload.address, forKey: "address")
                object.setValue(payload.website, forKey: "website")
                object.setValue(payload.notes, forKey: "notes")
                object.setValue(now, forKey: "updatedAt")
                if case .replace(let imageData) = payload.imageUpdate {
                    object.setValue(imageData, forKey: "imageData")
                }

                // 選択解除を含むrelationship全体をprivate queue内で再構成する。
                let tagRequest = NSFetchRequest<NSManagedObject>(entityName: "Tag")
                tagRequest.fetchBatchSize = 100
                let allTags = try context.fetch(tagRequest)
                let selectedTags = allTags.filter { tag in
                    guard let id = tag.value(forKey: "id") as? UUID else { return false }
                    return payload.selectedTagIDs.contains(id)
                }
                object.setValue(NSSet(array: selectedTags), forKey: "tags")

                try Task.checkCancellation()
                try context.save()
                let savedGeneration = CardFormEditGeneration(
                    objectURI: object.objectID.uriRepresentation(),
                    recordID: object.value(forKey: "id") as? UUID,
                    updatedAt: now
                )
                return CardFormSaveResult(
                    generation: savedGeneration,
                    changeKind: changeKind
                )
            } catch {
                context.rollback()
                throw error
            }
        }
    }

    private nonisolated func makeContext(
        name: String,
        coordinatorReference: PersistentStoreCoordinatorReference
    ) -> NSManagedObjectContext {
        let context = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
        context.persistentStoreCoordinator = coordinatorReference.coordinator
        context.name = name
        context.undoManager = nil
        return context
    }

    private nonisolated static func string(_ object: NSManagedObject, key: String) -> String {
        object.value(forKey: key) as? String ?? ""
    }
}
