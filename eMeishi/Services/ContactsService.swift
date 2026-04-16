import Foundation
import Contacts
import os

// iPhoneの連絡先との連携サービス
// NOTE: BusinessCard（@MainActor）を直接受け取るため @MainActor class を選択。
// Phase 3 で Sendable DTO に置換後、actor への変換を検討する。
@MainActor
class ContactsService {

    static let shared = ContactsService()

    private let store = CNContactStore()

    // MARK: - 権限確認・要求

    /// 連絡先へのアクセス権限を要求する
    func requestAccess() async throws {
        let status = CNContactStore.authorizationStatus(for: .contacts)
        switch status {
        case .authorized:
            return
        case .notDetermined:
            let granted = try await store.requestAccess(for: .contacts)
            if !granted { throw ContactsError.accessDenied }
        case .denied, .restricted, .limited:
            throw ContactsError.accessDenied
        @unknown default:
            throw ContactsError.accessDenied
        }
    }

    // MARK: - 連絡先へエクスポート

    /// BusinessCard を iPhone の連絡先に保存する
    func export(card: BusinessCard) async throws {
        try await requestAccess()

        let contact = CNMutableContact()
        contact.givenName  = card.firstName ?? ""
        contact.familyName = card.lastName  ?? ""

        if let company = card.company, !company.isEmpty {
            contact.organizationName = company
        }
        if let department = card.department, !department.isEmpty {
            contact.departmentName = department
        }
        if let title = card.title, !title.isEmpty {
            contact.jobTitle = title
        }
        let phoneList = card.phoneList
        if !phoneList.isEmpty {
            contact.phoneNumbers = phoneList.enumerated().map { index, phone in
                let label = index == 0 ? CNLabelPhoneNumberMain : CNLabelWork
                return CNLabeledValue(label: label,
                                     value: CNPhoneNumber(stringValue: phone))
            }
        }
        if let email = card.email, !email.isEmpty {
            contact.emailAddresses = [
                CNLabeledValue(label: CNLabelWork, value: email as NSString)
            ]
        }
        if let address = card.address, !address.isEmpty {
            let postal = CNMutablePostalAddress()
            postal.street = address
            contact.postalAddresses = [
                CNLabeledValue(label: CNLabelWork, value: postal)
            ]
        }
        if let website = card.website, !website.isEmpty {
            contact.urlAddresses = [
                CNLabeledValue(label: CNLabelWork, value: website as NSString)
            ]
        }
        if let notes = card.notes, !notes.isEmpty {
            contact.note = notes
        }
        if let imageData = card.imageData {
            contact.imageData = imageData
        }

        let request = CNSaveRequest()
        request.add(contact, toContainerWithIdentifier: nil)

        do {
            try store.execute(request)
            AppLogger.contacts.info("連絡先へ保存完了")
        } catch {
            AppLogger.contacts.error("連絡先への保存に失敗: \(error)")
            throw ContactsError.saveFailed(error)
        }
    }

    // MARK: - 連絡先からインポート

    /// iPhone の連絡先を BusinessCard 相当の構造体として読み込む
    func importContacts() async throws -> [ImportedContact] {
        try await requestAccess()

        // CNContactNoteKey は iOS 13+ で com.apple.developer.contacts.notes entitlement が必要なため除外
        // CNContactImageDataKey はインポート時のパフォーマンス低下を避けるため除外
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
        do {
            try store.enumerateContacts(with: request) { contact, _ in
                results.append(ImportedContact(cnContact: contact))
            }
        } catch {
            throw ContactsError.fetchFailed(error)
        }
        return results
    }

    // MARK: - エラー定義

    enum ContactsError: LocalizedError {
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

// MARK: - インポート用の中間データ構造

struct ImportedContact {
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
    let imageData: Data?

    init(cnContact c: CNContact) {
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
        imageData = nil
    }
}
