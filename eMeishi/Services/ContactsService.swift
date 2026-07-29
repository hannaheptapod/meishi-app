import Foundation
import Contacts
import CoreData
import os

// iPhoneの連絡先との連携サービス。
// 権限状態のUI連携だけをMainActor側の窓口に残し、ContactStoreへの全アクセスはworker actorへ委譲する。
@MainActor
final class ContactsService {

    static let shared = ContactsService()

    private let storeWorker = ContactsStoreWorker()
    private let dataTransferWorker = CardDataTransferWorker()

    // MARK: - 権限確認・要求

    /// 連絡先へのアクセス権限を要求する
    func requestAccess() async throws {
        try await storeWorker.requestAccess()
    }

    // MARK: - 連絡先へエクスポート

    /// 名刺をiPhoneの連絡先に保存する。
    /// 画像BLOBを含む単一件DTOはprivate contextで読み、View/MainActorではfaultしない。
    func export(request: ContactExportRequest) async throws {
        let contact = try await dataTransferWorker.loadContact(request)
        try Task.checkCancellation()
        try await storeWorker.export(contact: contact)
    }

    // MARK: - 連絡先からインポート

    /// iPhone の連絡先を BusinessCard 相当の構造体として読み込む
    func importContacts() async throws -> [ImportedContact] {
        try await storeWorker.importContacts()
    }

    // MARK: - エラー定義

    nonisolated enum ContactsError: LocalizedError {
        case accessDenied
        case saveFailed(Error)
        case fetchFailed(Error)

        var errorDescription: String? {
            switch self {
            case .accessDenied:
                return "連絡先へのアクセスが拒否されています。設定アプリから許可してください。"
            case .saveFailed(let e):
                return "連絡先への保存に失敗しました: \(e.localizedDescription)"
            case .fetchFailed(let e):
                return "連絡先の読み込みに失敗しました: \(e.localizedDescription)"
            }
        }
    }
}

/// 連絡先インポートと全削除をprivate queueで直列化するwriter。
/// MainActorへ`NSManagedObject`を返さず、成功件数だけを返す。
actor ContactImportStoreWriter {
    func insert(
        contacts: [ImportedContact],
        coordinatorReference: PersistentStoreCoordinatorReference,
        now: Date = Date()
    ) async throws -> Int {
        try Task.checkCancellation()
        let context = makeContext(
            name: "ContactImportStoreWriter",
            coordinatorReference: coordinatorReference
        )
        return try await context.perform {
            do {
                var insertedCount = 0
                for contact in contacts {
                    try Task.checkCancellation()
                    let hasName = !contact.lastName.isEmpty || !contact.firstName.isEmpty
                    let hasInfo = !contact.company.isEmpty || !contact.phone.isEmpty || !contact.email.isEmpty
                    guard hasName || hasInfo else { continue }

                    let card = NSEntityDescription.insertNewObject(
                        forEntityName: "BusinessCard",
                        into: context
                    )
                    card.setValue(UUID(), forKey: "id")
                    card.setValue(Self.nilIfEmpty(contact.lastName), forKey: "lastName")
                    card.setValue(Self.nilIfEmpty(contact.firstName), forKey: "firstName")
                    card.setValue(Self.nilIfEmpty(contact.company), forKey: "company")
                    card.setValue(Self.nilIfEmpty(contact.department), forKey: "department")
                    card.setValue(Self.nilIfEmpty(contact.title), forKey: "title")
                    card.setValue(Self.nilIfEmpty(contact.phone), forKey: "phone")
                    card.setValue(Self.nilIfEmpty(contact.email), forKey: "email")
                    card.setValue(Self.nilIfEmpty(contact.address), forKey: "address")
                    card.setValue(Self.nilIfEmpty(contact.website), forKey: "website")
                    card.setValue(Self.nilIfEmpty(contact.notes), forKey: "notes")
                    card.setValue(now, forKey: "createdAt")
                    card.setValue(now, forKey: "updatedAt")
                    insertedCount += 1
                }
                try Task.checkCancellation()
                if context.hasChanges {
                    try context.save()
                }
                return insertedCount
            } catch {
                context.rollback()
                throw error
            }
        }
    }

    func deleteAll(
        coordinatorReference: PersistentStoreCoordinatorReference
    ) async throws {
        try Task.checkCancellation()
        let context = makeContext(
            name: "DeleteAllCardsStoreWriter",
            coordinatorReference: coordinatorReference
        )
        try await context.perform {
            do {
                let request = NSFetchRequest<NSManagedObject>(entityName: "BusinessCard")
                request.fetchBatchSize = 100
                request.includesPropertyValues = false
                let cards = try context.fetch(request)
                for card in cards {
                    try Task.checkCancellation()
                    context.delete(card)
                }
                try Task.checkCancellation()
                if context.hasChanges {
                    try context.save()
                }
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
        context.mergePolicy = NSMergePolicy.mergeByPropertyObjectTrump
        return context
    }

    private nonisolated static func nilIfEmpty(_ value: String) -> String? {
        value.isEmpty ? nil : value
    }
}

// MARK: - インポート用の中間データ構造

nonisolated struct ImportedContact: Sendable {
    let lastName: String
    let firstName: String
    let company: String
    let department: String
    let title: String
    let phone: String
    let email: String
    let address: String
    let website: String
    let notes: String

    init(
        lastName: String = "",
        firstName: String = "",
        company: String = "",
        department: String = "",
        title: String = "",
        phone: String = "",
        email: String = "",
        address: String = "",
        website: String = "",
        notes: String = ""
    ) {
        self.lastName = lastName
        self.firstName = firstName
        self.company = company
        self.department = department
        self.title = title
        self.phone = phone
        self.email = email
        self.address = address
        self.website = website
        self.notes = notes
    }

    nonisolated init(cnContact c: CNContact) {
        lastName   = c.familyName
        firstName  = c.givenName
        company    = c.organizationName
        department = c.departmentName
        title      = c.jobTitle
        phone     = c.phoneNumbers.first?.value.stringValue ?? ""
        email     = c.emailAddresses.first?.value as String? ?? ""
        address   = c.postalAddresses.first.map {
            CNPostalAddressFormatter.string(from: $0.value, style: .mailingAddress)
        } ?? ""
        website   = c.urlAddresses.first?.value as String? ?? ""
        notes     = ""
    }
}

/// `CNContactStore`とContact frameworkオブジェクトを単一actor内に閉じ込める。
/// `enumerateContacts`と`execute`はMainActor上では実行されない。
private actor ContactsStoreWorker {
    private let store = CNContactStore()

    func requestAccess() async throws {
        let status = CNContactStore.authorizationStatus(for: .contacts)
        switch status {
        case .authorized:
            return
        case .notDetermined:
            let granted = try await store.requestAccess(for: .contacts)
            if !granted { throw ContactsService.ContactsError.accessDenied }
        case .denied, .restricted, .limited:
            throw ContactsService.ContactsError.accessDenied
        @unknown default:
            throw ContactsService.ContactsError.accessDenied
        }
    }

    func export(contact exportDTO: ContactExportDTO) async throws {
        try await requestAccess()
        try Task.checkCancellation()
        let card = exportDTO.card
        let contact = CNMutableContact()
        contact.givenName = card.firstName ?? ""
        contact.familyName = card.lastName ?? ""

        if let company = card.company, !company.isEmpty {
            contact.organizationName = company
        }
        if let department = card.department, !department.isEmpty {
            contact.departmentName = department
        }
        if let title = card.title, !title.isEmpty {
            contact.jobTitle = title
        }
        if !card.phoneList.isEmpty {
            contact.phoneNumbers = card.phoneList.enumerated().map { index, phone in
                CNLabeledValue(
                    label: index == 0 ? CNLabelPhoneNumberMain : CNLabelWork,
                    value: CNPhoneNumber(stringValue: phone)
                )
            }
        }
        if let email = card.email, !email.isEmpty {
            contact.emailAddresses = [
                CNLabeledValue(label: CNLabelWork, value: email as NSString),
            ]
        }
        if let address = card.address, !address.isEmpty {
            let postal = CNMutablePostalAddress()
            postal.street = address
            contact.postalAddresses = [
                CNLabeledValue(label: CNLabelWork, value: postal),
            ]
        }
        if let website = card.website, !website.isEmpty {
            contact.urlAddresses = [
                CNLabeledValue(label: CNLabelWork, value: website as NSString),
            ]
        }
        if let notes = card.notes, !notes.isEmpty {
            contact.note = notes
        }
        if let imageData = exportDTO.imageData {
            contact.imageData = imageData
        }

        let request = CNSaveRequest()
        request.add(contact, toContainerWithIdentifier: nil)
        do {
            try Task.checkCancellation()
            try store.execute(request)
            AppLogger.contacts.info("連絡先へ保存完了")
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            AppLogger.contacts.error("連絡先への保存に失敗: \(error)")
            throw ContactsService.ContactsError.saveFailed(error)
        }
    }

    func importContacts() async throws -> [ImportedContact] {
        try await requestAccess()
        try Task.checkCancellation()

        // Notes entitlementと画像デコードを避け、名刺化に必要な軽量キーだけを列挙する。
        let keys: [CNKeyDescriptor] = [
            CNContactGivenNameKey as CNKeyDescriptor,
            CNContactFamilyNameKey as CNKeyDescriptor,
            CNContactOrganizationNameKey as CNKeyDescriptor,
            CNContactDepartmentNameKey as CNKeyDescriptor,
            CNContactJobTitleKey as CNKeyDescriptor,
            CNContactPhoneNumbersKey as CNKeyDescriptor,
            CNContactEmailAddressesKey as CNKeyDescriptor,
            CNContactPostalAddressesKey as CNKeyDescriptor,
            CNContactUrlAddressesKey as CNKeyDescriptor,
        ]
        let request = CNContactFetchRequest(keysToFetch: keys)
        request.sortOrder = .familyName

        var results: [ImportedContact] = []
        var wasCancelled = false
        do {
            try store.enumerateContacts(with: request) { contact, stop in
                guard !Task.isCancelled else {
                    wasCancelled = true
                    stop.pointee = true
                    return
                }
                results.append(ImportedContact(cnContact: contact))
            }
            if wasCancelled { throw CancellationError() }
            return results
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw ContactsService.ContactsError.fetchFailed(error)
        }
    }
}
