import Foundation
import CoreData
import Combine

// 名刺一覧画面のViewModel
class CardListViewModel: ObservableObject {

    @Published var cards: [BusinessCard] = []

    private let context: NSManagedObjectContext

    init(context: NSManagedObjectContext = PersistenceController.shared.container.viewContext) {
        self.context = context
        fetchCards()
    }

    // MARK: - データ取得

    func fetchCards() {
        let request = BusinessCard.fetchRequest()
        // 登録日の新しい順に並べる
        request.sortDescriptors = [NSSortDescriptor(keyPath: \BusinessCard.createdAt, ascending: false)]
        do {
            cards = try context.fetch(request)
        } catch {
            print("名刺の取得に失敗しました: \(error)")
        }
    }

    // MARK: - 削除

    func deleteCards(at offsets: IndexSet) {
        offsets.forEach { index in
            context.delete(cards[index])
        }
        save()
    }

    // MARK: - 保存

    private func save() {
        do {
            try context.save()
            fetchCards()
        } catch {
            print("保存に失敗しました: \(error)")
        }
    }
}
