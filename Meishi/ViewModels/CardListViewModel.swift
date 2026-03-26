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
        case .newestFirst:      return "arrow.down.circle"
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
    @Published var exportItem: ExportItem? = nil
    @Published var errorMessage: String? = nil
    @Published var isImporting = false
    @Published var importResultMessage: String? = nil
    @Published var searchText: String = "" {
        didSet { updateFilteredCards() }
    }
    @Published var filteredCards: [BusinessCard] = []
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
            // ふりがなが設定されていればそちらで、なければ漢字名でソート（Swift 側で実施）
            request.sortDescriptors = [
                NSSortDescriptor(keyPath: \BusinessCard.lastName,  ascending: true),
                NSSortDescriptor(keyPath: \BusinessCard.firstName, ascending: true)
            ]
        case .companyAscending:
            // companySortKey（法人格除去・読み優先）は Swift 側でソート
            request.sortDescriptors = [
                NSSortDescriptor(keyPath: \BusinessCard.company,  ascending: true),
                NSSortDescriptor(keyPath: \BusinessCard.lastName, ascending: true)
            ]
        }
        do {
            var fetched = try context.fetch(request)
            // 名前順・会社名順はふりがな / companySortKey 優先で Swift 側ソート
            if sortOrder == .nameAscending {
                fetched.sort {
                    let lhs = ($0.lastNameReading?.isEmpty == false ? $0.lastNameReading! : $0.lastName ?? "")
                           + ($0.firstNameReading?.isEmpty == false ? $0.firstNameReading! : $0.firstName ?? "")
                    let rhs = ($1.lastNameReading?.isEmpty == false ? $1.lastNameReading! : $1.lastName ?? "")
                           + ($1.firstNameReading?.isEmpty == false ? $1.firstNameReading! : $1.firstName ?? "")
                    return lhs.localizedStandardCompare(rhs) == .orderedAscending
                }
            } else if sortOrder == .companyAscending {
                fetched.sort {
                    let lhs = $0.companySortKey + ($0.lastNameReading ?? $0.lastName ?? "")
                    let rhs = $1.companySortKey + ($1.lastNameReading ?? $1.lastName ?? "")
                    return lhs.localizedStandardCompare(rhs) == .orderedAscending
                }
            }
            cards = fetched
            detectDuplicates()
            updateFilteredCards()
        } catch {
            print("名刺の取得に失敗しました: \(error)")
        }
    }

    // MARK: - 検索フィルタ

    private func updateFilteredCards() {
        let q = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { filteredCards = cards; return }
        filteredCards = cards.filter { card in
            card.fullName.lowercased().contains(q)
            || card.fullNameReading.lowercased().contains(q)
            || (card.company?.lowercased().contains(q) ?? false)
            || (card.companyReading?.lowercased().contains(q) ?? false)
            || (card.title?.lowercased().contains(q) ?? false)
            || (card.email?.lowercased().contains(q) ?? false)
        }
    }

    // MARK: - 重複検出

    func detectDuplicates() {
        let checker = DuplicateChecker(threshold: SettingsStore.shared.duplicateThreshold)
        duplicatePairs = checker.findDuplicates(in: cards)
    }

    // MARK: - エクスポート

    func exportCSV() {
        do {
            exportItem = ExportItem(url: try ExportService.shared.exportCSV(from: cards))
        } catch {
            errorMessage = "CSVエクスポートに失敗しました: \(error.localizedDescription)"
        }
    }

    func exportVCard() {
        do {
            exportItem = ExportItem(url: try ExportService.shared.exportVCard(from: cards))
        } catch {
            errorMessage = "vCardエクスポートに失敗しました: \(error.localizedDescription)"
        }
    }

    // MARK: - 連絡先からインポート

    func importFromContacts() {
        guard !isImporting else { return }
        isImporting = true
        Task { @MainActor in
            defer { isImporting = false }
            do {
                let contacts = try await ContactsService.shared.importContacts()
                var count = 0
                for contact in contacts {
                    // 名前・会社・電話・メールがすべて空のエントリはスキップ
                    let hasName = !contact.lastName.isEmpty || !contact.firstName.isEmpty
                    let hasInfo = !contact.company.isEmpty || !contact.phone.isEmpty || !contact.email.isEmpty
                    guard hasName || hasInfo else { continue }

                    let card = BusinessCard(context: context)
                    card.id         = UUID()
                    card.lastName   = contact.lastName.isEmpty ? nil : contact.lastName
                    card.firstName  = contact.firstName.isEmpty ? nil : contact.firstName
                    card.company    = contact.company.isEmpty ? nil : contact.company
                    card.department = contact.department.isEmpty ? nil : contact.department
                    card.title      = contact.title.isEmpty ? nil : contact.title
                    card.phone      = contact.phone.isEmpty ? nil : contact.phone
                    card.email      = contact.email.isEmpty ? nil : contact.email
                    card.address    = contact.address.isEmpty ? nil : contact.address
                    card.website    = contact.website.isEmpty ? nil : contact.website
                    card.notes      = contact.notes.isEmpty ? nil : contact.notes
                    card.imageData  = contact.imageData
                    card.createdAt  = Date()
                    card.updatedAt  = Date()
                    count += 1
                }
                try context.save()
                fetchCards()
                importResultMessage = "\(count)件の連絡先をインポートしました"
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    // MARK: - 削除

    func deleteCards(_ cardsToDelete: [BusinessCard]) {
        cardsToDelete.forEach { context.delete($0) }
        save()
    }

    // MARK: - 全削除

    func deleteAllCards() {
        let request = BusinessCard.fetchRequest()
        do {
            let all = try context.fetch(request)
            all.forEach { context.delete($0) }
            try context.save()
            fetchCards()
        } catch {
            errorMessage = "削除に失敗しました: \(error.localizedDescription)"
        }
    }

    // MARK: - 保存

    private func save() {
        do {
            try context.save()
            fetchCards()
        } catch {
            errorMessage = "保存に失敗しました: \(error.localizedDescription)"
        }
    }
}
