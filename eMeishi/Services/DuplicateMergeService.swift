import CoreData
import Foundation

/// 重複統合画面が保持する不変の表示値。
/// `NSManagedObject` を View の State に保持せず、実行直前に ID から再解決できるようにする。
nonisolated struct DuplicateMergeCardSnapshot: Equatable, Sendable {
    let objectURI: String
    let lastName: String
    let lastNameReading: String
    let firstName: String
    let firstNameReading: String
    let company: String
    let companyReading: String
    let department: String
    let title: String
    let phone: String
    let email: String
    let address: String
    let website: String
    let notes: String
    let createdAt: Date?
    let updatedAt: Date?

    @MainActor
    init(card: BusinessCard) {
        objectURI = card.objectID.uriRepresentation().absoluteString
        lastName = card.lastName ?? ""
        lastNameReading = card.lastNameReading ?? ""
        firstName = card.firstName ?? ""
        firstNameReading = card.firstNameReading ?? ""
        company = card.company ?? ""
        companyReading = card.companyReading ?? ""
        department = card.department ?? ""
        title = card.title ?? ""
        phone = card.phone ?? ""
        email = card.email ?? ""
        address = card.address ?? ""
        website = card.website ?? ""
        notes = card.notes ?? ""
        createdAt = card.createdAt
        updatedAt = card.updatedAt
    }

    var fullName: String {
        let last = lastName.trimmingCharacters(in: .whitespaces)
        let first = firstName.trimmingCharacters(in: .whitespaces)
        return [last, first].filter { !$0.isEmpty }.joined(separator: " ")
    }

    var phoneList: [String] {
        phone.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// 表示後に統合対象が編集されていないことを確認する。
    @MainActor
    func matchesCurrentValues(of card: BusinessCard) -> Bool {
        !card.isDeleted
            && lastName == (card.lastName ?? "")
            && lastNameReading == (card.lastNameReading ?? "")
            && firstName == (card.firstName ?? "")
            && firstNameReading == (card.firstNameReading ?? "")
            && company == (card.company ?? "")
            && companyReading == (card.companyReading ?? "")
            && department == (card.department ?? "")
            && title == (card.title ?? "")
            && phone == (card.phone ?? "")
            && email == (card.email ?? "")
            && address == (card.address ?? "")
            && website == (card.website ?? "")
            && notes == (card.notes ?? "")
            && updatedAt == card.updatedAt
    }
}

/// シートを開く前に確定した重複統合画面の入力。
/// 表示開始後の`.task`でCore Dataを解決しないため、最初のフレームから
/// 本文とツールバーを同時に描画できる。
nonisolated struct DuplicateMergeRequest: Identifiable, Sendable {
    let pair: DuplicatePair
    let cardA: DuplicateMergeCardSnapshot?
    let cardB: DuplicateMergeCardSnapshot?

    var id: String { "\(pair.cardAIDURI)-\(pair.cardBIDURI)" }
}

nonisolated struct DuplicateMergeSelection: Equatable {
    enum Source: Equatable {
        case a
        case b
    }

    var name: Source = .a
    var company: Source = .a
    var department: Source = .a
    var title: Source = .a
    var phone: Source = .a
    var email: Source = .a
    var address: Source = .a
    var website: Source = .a
    var notes: Source = .a

    init() {}

    @MainActor
    init(cardA: BusinessCard, cardB: BusinessCard) {
        self.init(
            cardA: DuplicateMergeCardSnapshot(card: cardA),
            cardB: DuplicateMergeCardSnapshot(card: cardB)
        )
    }

    init(cardA: DuplicateMergeCardSnapshot, cardB: DuplicateMergeCardSnapshot) {
        name = Self.preferredSource(cardA.fullName, cardB.fullName)
        company = Self.preferredSource(cardA.company, cardB.company)
        department = Self.preferredSource(cardA.department, cardB.department)
        title = Self.preferredSource(cardA.title, cardB.title)
        phone = Self.preferredSource(cardA.phone, cardB.phone)
        email = Self.preferredSource(cardA.email, cardB.email)
        address = Self.preferredSource(cardA.address, cardB.address)
        website = Self.preferredSource(cardA.website, cardB.website)
        notes = Self.preferredSource(cardA.notes, cardB.notes)
    }

    private static func preferredSource(_ valueA: String?, _ valueB: String?) -> Source {
        let aIsEmpty = valueA?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true
        let bIsEmpty = valueB?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true
        return aIsEmpty && !bIsEmpty ? .b : .a
    }
}

/// 重複統合のデータ変更と保存をViewから分離し、同じ実装を単体テストできるようにする。
@MainActor
enum DuplicateMergeService {
    enum MergeError: LocalizedError {
        case invalidCards

        var errorDescription: String? {
            "統合対象の名刺が見つかりません。"
        }
    }

    static func merge(
        cardA: BusinessCard,
        cardB: BusinessCard,
        selection: DuplicateMergeSelection,
        in context: NSManagedObjectContext
    ) throws {
        do {
            try apply(cardA: cardA, cardB: cardB, selection: selection, in: context)
            try context.save()
        } catch {
            context.rollback()
            throw error
        }
    }

    /// 保存前の統合操作。単体テストと、将来のプレビュー生成で再利用する。
    static func apply(
        cardA: BusinessCard,
        cardB: BusinessCard,
        selection: DuplicateMergeSelection,
        in context: NSManagedObjectContext
    ) throws {
        guard !cardA.isDeleted,
              !cardB.isDeleted,
              cardA.managedObjectContext === context,
              cardB.managedObjectContext === context else {
            throw MergeError.invalidCards
        }

        if selection.name == .b {
            cardA.lastName = cardB.lastName ?? ""
            cardA.lastNameReading = cardB.lastNameReading ?? ""
            cardA.firstName = cardB.firstName ?? ""
            cardA.firstNameReading = cardB.firstNameReading ?? ""
        }
        if selection.company == .b {
            cardA.company = cardB.company ?? ""
            cardA.companyReading = cardB.companyReading ?? ""
        }
        cardA.department = selection.department == .a ? (cardA.department ?? "") : (cardB.department ?? "")
        cardA.title = selection.title == .a ? (cardA.title ?? "") : (cardB.title ?? "")
        cardA.phone = selection.phone == .a ? (cardA.phone ?? "") : (cardB.phone ?? "")
        cardA.email = selection.email == .a ? (cardA.email ?? "") : (cardB.email ?? "")
        cardA.address = selection.address == .a ? (cardA.address ?? "") : (cardB.address ?? "")
        cardA.website = selection.website == .a ? (cardA.website ?? "") : (cardB.website ?? "")
        cardA.notes = selection.notes == .a ? (cardA.notes ?? "") : (cardB.notes ?? "")
        if cardA.imageData == nil {
            cardA.imageData = cardB.imageData
        }

        if let tags = cardB.tags as? Set<Tag> {
            for tag in tags {
                cardA.addToTags(tag)
            }
        }

        cardA.updatedAt = Date()
        context.delete(cardB)
    }
}
