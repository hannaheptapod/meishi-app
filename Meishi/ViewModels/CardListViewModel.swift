import Foundation
import CoreData
import Combine

// 名刺一覧のソート順
enum CardSortOrder: String, CaseIterable, Identifiable {
    case newestFirst      = "登録が新しい順"
    case oldestFirst      = "登録が古い順"
    case nameAscending    = "名前順"
    case companyAscending = "会社名順"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .newestFirst:      return "clock.arrow.counterclockwise"
        case .oldestFirst:      return "clock"
        case .nameAscending:    return "person.text.rectangle"
        case .companyAscending: return "building.2"
        }
    }
}

// 名刺一覧画面のViewModel
class CardListViewModel: ObservableObject {

    @Published var cards: [BusinessCard] = []
    @Published var duplicatePairs: [DuplicatePair] = []
    @Published var sortOrder: CardSortOrder = .newestFirst {
        didSet { fetchCards() }
    }

    private let context: NSManagedObjectContext
    private var cancellables = Set<AnyCancellable>()

    init(context: NSManagedObjectContext = PersistenceController.shared.container.viewContext) {
        self.context = context
        fetchCards()

        // 閾値が変わったら重複検出を再実行
        SettingsStore.shared.$duplicateThreshold
            .dropFirst()
            .sink { [weak self] _ in self?.detectDuplicates() }
            .store(in: &cancellables)
    }

    // MARK: - データ取得

    func fetchCards() {
        let request = BusinessCard.fetchRequest()
        switch sortOrder {
        case .newestFirst:
            request.sortDescriptors = [NSSortDescriptor(keyPath: \BusinessCard.createdAt, ascending: false)]
        case .oldestFirst:
            request.sortDescriptors = [NSSortDescriptor(keyPath: \BusinessCard.createdAt, ascending: true)]
        case .nameAscending:
            request.sortDescriptors = [
                NSSortDescriptor(keyPath: \BusinessCard.lastName,  ascending: true),
                NSSortDescriptor(keyPath: \BusinessCard.firstName, ascending: true)
            ]
        case .companyAscending:
            request.sortDescriptors = [
                NSSortDescriptor(keyPath: \BusinessCard.company,   ascending: true),
                NSSortDescriptor(keyPath: \BusinessCard.lastName,  ascending: true)
            ]
        }
        do {
            cards = try context.fetch(request)
            detectDuplicates()
        } catch {
            print("名刺の取得に失敗しました: \(error)")
        }
    }

    // MARK: - 重複検出

    func detectDuplicates() {
        let checker = DuplicateChecker(threshold: SettingsStore.shared.duplicateThreshold)
        duplicatePairs = checker.findDuplicates(in: cards)
    }

    // MARK: - 削除

    func deleteCards(_ cardsToDelete: [BusinessCard]) {
        cardsToDelete.forEach { context.delete($0) }
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
