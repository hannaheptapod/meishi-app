import CoreData
import Foundation

struct DuplicateMergeSelection: Equatable {
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

    init(cardA: BusinessCard, cardB: BusinessCard) {
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
