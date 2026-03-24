import Foundation
import CoreData
import Combine

// 名刺の新規作成・編集フォームのViewModel
class CardFormViewModel: ObservableObject {

    @Published var name: String = ""
    @Published var company: String = ""
    @Published var title: String = ""
    @Published var email: String = ""
    @Published var phone: String = ""
    @Published var address: String = ""
    @Published var website: String = ""
    @Published var notes: String = ""

    // 編集中かどうかを外部から確認できるように公開
    var isEditing: Bool { card != nil }

    private let context: NSManagedObjectContext
    private var card: BusinessCard?

    // MARK: - 初期化（新規作成）

    init(context: NSManagedObjectContext = PersistenceController.shared.container.viewContext) {
        self.context = context
    }

    // MARK: - 初期化（既存カードの編集）

    init(card: BusinessCard,
         context: NSManagedObjectContext = PersistenceController.shared.container.viewContext) {
        self.card = card
        self.context = context
        // 既存の値をフォームフィールドに反映
        name    = card.name    ?? ""
        company = card.company ?? ""
        title   = card.title   ?? ""
        email   = card.email   ?? ""
        phone   = card.phone   ?? ""
        address = card.address ?? ""
        website = card.website ?? ""
        notes   = card.notes   ?? ""
    }

    // MARK: - 保存

    func save() {
        // 既存カードがあれば上書き、なければ新規作成
        let target = card ?? {
            let newCard = BusinessCard(context: context)
            newCard.id = UUID()
            newCard.createdAt = Date()
            return newCard
        }()

        target.name    = name.trimmingCharacters(in: .whitespacesAndNewlines)
        target.company = company.trimmingCharacters(in: .whitespacesAndNewlines)
        target.title   = title.trimmingCharacters(in: .whitespacesAndNewlines)
        target.email   = email.trimmingCharacters(in: .whitespacesAndNewlines)
        target.phone   = phone.trimmingCharacters(in: .whitespacesAndNewlines)
        target.address = address.trimmingCharacters(in: .whitespacesAndNewlines)
        target.website = website.trimmingCharacters(in: .whitespacesAndNewlines)
        target.notes   = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        target.updatedAt = Date()

        do {
            try context.save()
        } catch {
            print("名刺の保存に失敗しました: \(error)")
        }
    }
}
