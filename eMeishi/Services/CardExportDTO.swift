import CoreData
import Foundation

// BusinessCard を MainActor 外（actor 跨ぎ）で安全に渡すための値型 DTO。
// ExportService / ContactsService は本 DTO を受け取り、CoreData オブジェクトに依存しない。
nonisolated struct CardExportDTO: Sendable {
    let lastName: String?
    let firstName: String?
    let company: String?
    let department: String?
    let title: String?
    let phoneList: [String]
    let email: String?
    let address: String?
    let website: String?
    let notes: String?
    let createdAt: Date?

    /// 「姓 名」形式（空白トリム済み）。BusinessCard.fullName と同じ挙動
    var fullName: String {
        let last  = lastName?.trimmingCharacters(in: .whitespaces) ?? ""
        let first = firstName?.trimmingCharacters(in: .whitespaces) ?? ""
        switch (last.isEmpty, first.isEmpty) {
        case (false, false): return "\(last) \(first)"
        case (false, true):  return last
        case (true, false):  return first
        default:             return ""
        }
    }
}

/// 連絡先保存だけで使用する画像付きDTO。
/// CSV/vCardの全件処理から画像BLOBを型レベルで分離する。
nonisolated struct ContactExportDTO: Sendable {
    let card: CardExportDTO
    let imageData: Data?
}

/// 連絡先保存時にMainActorから渡すのはCore DataのURIと不変coordinator参照だけとする。
nonisolated struct ContactExportRequest: Sendable {
    let objectURI: URL
    let coordinatorReference: PersistentStoreCoordinatorReference
}

nonisolated enum CardDataTransferError: LocalizedError {
    case missingPersistentStore
    case objectNotFound

    var errorDescription: String? {
        switch self {
        case .missingPersistentStore:
            return "データストアを読み込めません。"
        case .objectNotFound:
            return "対象の名刺が見つかりません。"
        }
    }
}

/// エクスポートに必要な値をprivate contextで読み出す。
/// 全件CSV/vCardでは`imageData`を一切faultせず、連絡先保存の単一件だけ画像を読む。
actor CardDataTransferWorker {
    func loadCard(
        objectURI: URL,
        coordinatorReference: PersistentStoreCoordinatorReference
    ) async throws -> CardExportDTO {
        try Task.checkCancellation()
        let coordinator = coordinatorReference.coordinator
        guard let objectID = coordinator.managedObjectID(forURIRepresentation: objectURI) else {
            throw CardDataTransferError.objectNotFound
        }
        let context = makeContext(
            name: "CardExportSnapshotLoader",
            coordinatorReference: coordinatorReference
        )
        return try await context.perform {
            try Task.checkCancellation()
            let request = NSFetchRequest<NSDictionary>(entityName: "BusinessCard")
            request.resultType = .dictionaryResultType
            request.predicate = NSPredicate(format: "SELF == %@", objectID)
            request.fetchLimit = 1
            request.propertiesToFetch = Self.exportPropertyKeys
            guard let card = try context.fetch(request).first else {
                throw CardDataTransferError.objectNotFound
            }
            return Self.makeExportDTO(from: card)
        }
    }

    func loadCards(
        orderedCardIDs: [UUID],
        coordinatorReference: PersistentStoreCoordinatorReference
    ) async throws -> [CardExportDTO] {
        try Task.checkCancellation()
        guard !orderedCardIDs.isEmpty else { return [] }

        let context = makeContext(
            name: "CardExportSnapshotLoader",
            coordinatorReference: coordinatorReference
        )
        return try await context.perform {
            try Task.checkCancellation()
            let request = NSFetchRequest<NSDictionary>(entityName: "BusinessCard")
            request.resultType = .dictionaryResultType
            request.predicate = NSPredicate(format: "id IN %@", orderedCardIDs)
            request.propertiesToFetch = Self.exportPropertyKeys
            let fetched = try context.fetch(request)
            try Task.checkCancellation()

            let cardsByID = Dictionary(uniqueKeysWithValues: fetched.compactMap { values in
                (values["id"] as? UUID).map { ($0, values) }
            })
            guard cardsByID.count == orderedCardIDs.count else {
                throw CardDataTransferError.objectNotFound
            }
            return try orderedCardIDs.map { cardID in
                guard let card = cardsByID[cardID] else {
                    throw CardDataTransferError.objectNotFound
                }
                return Self.makeExportDTO(from: card)
            }
        }
    }

    func loadContact(_ request: ContactExportRequest) async throws -> ContactExportDTO {
        try Task.checkCancellation()
        let coordinator = request.coordinatorReference.coordinator
        guard let objectID = coordinator.managedObjectID(forURIRepresentation: request.objectURI) else {
            throw CardDataTransferError.objectNotFound
        }

        let context = makeContext(
            name: "ContactExportSnapshotLoader",
            coordinatorReference: request.coordinatorReference
        )
        return try await context.perform {
            try Task.checkCancellation()
            let fetchRequest = NSFetchRequest<NSDictionary>(entityName: "BusinessCard")
            fetchRequest.resultType = .dictionaryResultType
            fetchRequest.predicate = NSPredicate(format: "SELF == %@", objectID)
            fetchRequest.fetchLimit = 1
            fetchRequest.propertiesToFetch = Self.exportPropertyKeys + ["imageData"]
            guard let card = try context.fetch(fetchRequest).first else {
                throw CardDataTransferError.objectNotFound
            }
            try Task.checkCancellation()
            return ContactExportDTO(
                card: Self.makeExportDTO(from: card),
                imageData: card["imageData"] as? Data
            )
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

    private nonisolated static let exportPropertyKeys = [
        "id", "lastName", "firstName", "company", "department", "title", "phone",
        "email", "address", "website", "notes", "createdAt",
    ]

    private nonisolated static func makeExportDTO(from card: NSDictionary) -> CardExportDTO {
        let phone = card["phone"] as? String
        return CardExportDTO(
            lastName: card["lastName"] as? String,
            firstName: card["firstName"] as? String,
            company: card["company"] as? String,
            department: card["department"] as? String,
            title: card["title"] as? String,
            phoneList: Self.phoneList(from: phone),
            email: card["email"] as? String,
            address: card["address"] as? String,
            website: card["website"] as? String,
            notes: card["notes"] as? String,
            createdAt: card["createdAt"] as? Date
        )
    }

    private nonisolated static func phoneList(from phone: String?) -> [String] {
        guard let phone, !phone.isEmpty else { return [] }
        return phone.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}

@MainActor
extension BusinessCard {
    func toExportDTO() -> CardExportDTO {
        CardExportDTO(
            lastName: lastName,
            firstName: firstName,
            company: company,
            department: department,
            title: title,
            phoneList: phoneList,
            email: email,
            address: address,
            website: website,
            notes: notes,
            createdAt: createdAt
        )
    }
}
