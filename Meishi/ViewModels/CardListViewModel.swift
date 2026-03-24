import Foundation
import CoreData
import Combine

// 名刺一覧画面のViewModel
class CardListViewModel: ObservableObject {

    @Published var cards: [BusinessCard] = []
    @Published var duplicatePairs: [DuplicatePair] = []

    private let context: NSManagedObjectContext
    private let checker = DuplicateChecker()

    init(context: NSManagedObjectContext = PersistenceController.shared.container.viewContext) {
        self.context = context
        fetchCards()
    }

    // MARK: - データ取得

    func fetchCards() {
        let request = BusinessCard.fetchRequest()
        request.sortDescriptors = [NSSortDescriptor(keyPath: \BusinessCard.createdAt, ascending: false)]
        do {
            cards = try context.fetch(request)
            detectDuplicates()
        } catch {
            print("名刺の取得に失敗しました: \(error)")
        }
    }

    // MARK: - 重複検出

    func detectDuplicates() {
        duplicatePairs = checker.findDuplicates(in: cards)
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
