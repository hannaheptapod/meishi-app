import CoreData
import Foundation

/// 詳細・ピーク表示で使うタグの値スナップショット。
/// View の body から Core Data relationship を評価しないために使用する。
nonisolated struct CardDetailTagSnapshot: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let colorHex: String
}

nonisolated enum CardDetailContactKind: String, Equatable, Sendable {
    case phone
    case email
    case address
    case website
}

/// 詳細画面の1行分を、リンク先まで確定した値として保持する。
nonisolated struct CardDetailContactSnapshot: Identifiable, Equatable, Sendable {
    let id: String
    let kind: CardDetailContactKind
    let title: String
    let value: String
    let systemImage: String
    let destination: URL?
}

/// 1枚の名刺について、詳細・ピークの描画に必要な値を一度だけ確定する。
/// 編集などで管理オブジェクトが変わった場合は、画面側が明示的に再生成する。
nonisolated struct CardDetailDisplaySnapshot: Equatable, Sendable {
    let objectURI: URL
    let initials: String
    let fullNameReading: String
    let displayName: String
    let company: String
    let affiliation: String
    let notes: String
    let createdAt: Date?
    let isFavorite: Bool
    let contacts: [CardDetailContactSnapshot]
    let previewContacts: [CardDetailContactSnapshot]
    let tags: [CardDetailTagSnapshot]

    /// private contextで取得した値型から詳細表示を構成する。
    /// 画面遷移時にMainActor上でCore Data faultを解決しないための主経路。
    init(
        objectURI: URL,
        lastName: String,
        lastNameReading: String,
        firstName: String,
        firstNameReading: String,
        company: String,
        department: String,
        title: String,
        phone: String,
        email: String,
        address: String,
        website: String,
        notes: String,
        createdAt: Date?,
        isFavorite: Bool,
        tags: [CardDetailTagSnapshot]
    ) {
        self.objectURI = objectURI

        let trimmedLastName = lastName.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedFirstName = firstName.trimmingCharacters(in: .whitespacesAndNewlines)
        initials = String(trimmedLastName.prefix(1)) + String(trimmedFirstName.prefix(1))

        fullNameReading = [lastNameReading, firstNameReading]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        let fullName = [trimmedLastName, trimmedFirstName]
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        displayName = fullName.isEmpty ? "（名前なし）" : fullName
        self.company = company.trimmingCharacters(in: .whitespacesAndNewlines)
        affiliation = [department, title]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
        self.notes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        self.createdAt = createdAt
        self.isFavorite = isFavorite
        self.tags = tags

        let phoneNumbers = phone.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        var contactValues = phoneNumbers.enumerated().map { index, number in
            CardDetailContactSnapshot(
                id: "phone-\(index)-\(number)",
                kind: .phone,
                title: "電話",
                value: number,
                systemImage: "phone.fill",
                destination: Self.telephoneURL(number)
            )
        }
        if let email = Self.nonEmpty(email) {
            contactValues.append(Self.emailContact(email))
        }
        if let address = Self.nonEmpty(address) {
            contactValues.append(Self.addressContact(address))
        }
        if let website = Self.nonEmpty(website) {
            contactValues.append(Self.websiteContact(website))
        }
        contacts = contactValues
        previewContacts = Array(
            contactValues.lazy
                .filter { $0.kind == .phone || $0.kind == .email }
                .prefix(2)
        )
    }

    @MainActor
    init(card: BusinessCard) {
        self.init(
            objectURI: card.objectID.uriRepresentation(),
            lastName: card.lastName ?? "",
            lastNameReading: card.lastNameReading ?? "",
            firstName: card.firstName ?? "",
            firstNameReading: card.firstNameReading ?? "",
            company: card.company ?? "",
            department: card.department ?? "",
            title: card.title ?? "",
            phone: card.phone ?? "",
            email: card.email ?? "",
            address: card.address ?? "",
            website: card.website ?? "",
            notes: card.notes ?? "",
            createdAt: card.createdAt,
            isFavorite: card.isFavorite,
            tags: card.tagArray.map { tag in
                CardDetailTagSnapshot(
                    id: tag.objectID.uriRepresentation().absoluteString,
                    name: tag.tagName,
                    colorHex: tag.colorHex ?? "#007AFF"
                )
            }
        )
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return nil }
        return value
    }

    private static func telephoneURL(_ phone: String) -> URL? {
        let digits = phone.filter { $0.isNumber || $0 == "+" }
        guard !digits.isEmpty else { return nil }
        var components = URLComponents()
        components.scheme = "tel"
        components.path = digits
        return components.url
    }

    private static func emailURL(_ email: String) -> URL? {
        var components = URLComponents()
        components.scheme = "mailto"
        components.path = email
        return components.url
    }

    private static func mapURL(_ address: String) -> URL? {
        var components = URLComponents(string: "maps://")
        components?.queryItems = [URLQueryItem(name: "q", value: address)]
        return components?.url
    }

    private static func emailContact(_ email: String) -> CardDetailContactSnapshot {
        CardDetailContactSnapshot(
            id: "email-\(email)",
            kind: .email,
            title: "メール",
            value: email,
            systemImage: "envelope.fill",
            destination: emailURL(email)
        )
    }

    private static func addressContact(_ address: String) -> CardDetailContactSnapshot {
        CardDetailContactSnapshot(
            id: "address-\(address)",
            kind: .address,
            title: "住所",
            value: address,
            systemImage: "arrow.triangle.turn.up.right.diamond.fill",
            destination: mapURL(address)
        )
    }

    private static func websiteContact(_ website: String) -> CardDetailContactSnapshot {
        CardDetailContactSnapshot(
            id: "website-\(website)",
            kind: .website,
            title: "Webサイト",
            value: website,
            systemImage: "safari.fill",
            destination: ExternalURLNormalizer.websiteURL(from: website)
        )
    }

    func settingFavorite(_ isFavorite: Bool) -> CardDetailDisplaySnapshot {
        CardDetailDisplaySnapshot(
            objectURI: objectURI,
            initials: initials,
            fullNameReading: fullNameReading,
            displayName: displayName,
            company: company,
            affiliation: affiliation,
            notes: notes,
            createdAt: createdAt,
            isFavorite: isFavorite,
            contacts: contacts,
            previewContacts: previewContacts,
            tags: tags
        )
    }

    private init(
        objectURI: URL,
        initials: String,
        fullNameReading: String,
        displayName: String,
        company: String,
        affiliation: String,
        notes: String,
        createdAt: Date?,
        isFavorite: Bool,
        contacts: [CardDetailContactSnapshot],
        previewContacts: [CardDetailContactSnapshot],
        tags: [CardDetailTagSnapshot]
    ) {
        self.objectURI = objectURI
        self.initials = initials
        self.fullNameReading = fullNameReading
        self.displayName = displayName
        self.company = company
        self.affiliation = affiliation
        self.notes = notes
        self.createdAt = createdAt
        self.isFavorite = isFavorite
        self.contacts = contacts
        self.previewContacts = previewContacts
        self.tags = tags
    }
}
