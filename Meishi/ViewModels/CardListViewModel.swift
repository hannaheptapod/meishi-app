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

// セクション（グループ）単位
struct CardSection: Identifiable {
    let id: String
    let title: String
    let cards: [BusinessCard]
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
    @Published var groupedCards: [CardSection] = []
    @Published var sortOrder: CardSortOrder = .newestFirst {
        didSet { fetchCards() }
    }

    // 検索中かどうか（セクション表示 vs フラット表示の切替に使用）
    var isSearchActive: Bool { !searchText.trimmingCharacters(in: .whitespaces).isEmpty }

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
            updateFilteredCards()
        } catch {
            print("名刺の取得に失敗しました: \(error)")
        }
    }

    // MARK: - 検索フィルタ

    private func updateFilteredCards() {
        let q = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        if q.isEmpty {
            filteredCards = cards
        } else {
            filteredCards = cards.filter { card in
                card.fullName.lowercased().contains(q)
                || (card.company?.lowercased().contains(q) ?? false)
                || (card.title?.lowercased().contains(q) ?? false)
                || (card.email?.lowercased().contains(q) ?? false)
            }
        }
        updateGroupedCards()
    }

    // MARK: - セクション分けグループ化

    private func updateGroupedCards() {
        guard !isSearchActive else {
            groupedCards = []
            return
        }
        switch sortOrder {
        case .nameAscending:
            groupedCards = groupByName(cards)
        case .companyAscending:
            groupedCards = groupByCompany(cards)
        case .newestFirst, .oldestFirst:
            groupedCards = groupByDate(cards)
        }
    }

    // かな行・アルファベットのセクション順序（表示順を固定）
    private static let kanaSectionOrder: [String] = [
        "あ行", "か行", "さ行", "た行", "な行", "は行", "ま行", "や行", "ら行", "わ行"
    ]
    private static let alphabetOrder: [String] = (UInt8(ascii: "A")...UInt8(ascii: "Z")).map { String(bytes: [$0], encoding: .utf8)! }
    private static let sectionOrder: [String] = kanaSectionOrder + alphabetOrder + ["その他"]

    // 先頭文字からセクションキーを返す（日本語かな行・アルファベット・その他）
    private func sectionKey(for text: String) -> String {
        guard let first = text.unicodeScalars.first else { return "その他" }
        var scalar = first.value

        // カタカナ → ひらがなに変換（U+30A1–U+30F6 → U+3041–U+3096）
        if scalar >= 0x30A1 && scalar <= 0x30F6 {
            scalar -= 0x60
        }

        // ひらがな行判定
        if scalar >= 0x3041 && scalar <= 0x3093 {
            switch scalar {
            case 0x3041...0x304A: return "あ行"
            case 0x304B...0x3053: return "か行"
            case 0x3055...0x305B: return "さ行"
            case 0x305F...0x3069: return "た行"
            case 0x306A...0x306E: return "な行"
            case 0x306F...0x307B: return "は行"
            case 0x307E...0x3082: return "ま行"
            case 0x3084...0x3088: return "や行"
            case 0x3089...0x308D: return "ら行"
            case 0x308F...0x3093: return "わ行"
            default: return "その他"
            }
        }

        // アルファベット
        if (scalar >= 0x41 && scalar <= 0x5A) || (scalar >= 0x61 && scalar <= 0x7A) {
            return String(Character(UnicodeScalar(scalar < 0x61 ? scalar : scalar - 0x20)!)).uppercased()
        }

        return "その他"
    }

    // 名前順グループ化
    private func groupByName(_ cards: [BusinessCard]) -> [CardSection] {
        var buckets: [String: [BusinessCard]] = [:]
        for card in cards {
            let name = (card.lastName?.isEmpty == false ? card.lastName! : card.firstName) ?? ""
            let key = name.isEmpty ? "その他" : sectionKey(for: name)
            buckets[key, default: []].append(card)
        }
        return Self.sectionOrder
            .filter { buckets[$0] != nil }
            .map { CardSection(id: $0, title: $0, cards: buckets[$0]!) }
    }

    // 会社名順グループ化（会社名なしは末尾）
    private func groupByCompany(_ cards: [BusinessCard]) -> [CardSection] {
        let noCompanyKey = "（会社名なし）"
        var buckets: [String: [BusinessCard]] = [:]
        for card in cards {
            let co = card.company ?? ""
            let key = co.isEmpty ? noCompanyKey : sectionKey(for: co)
            buckets[key, default: []].append(card)
        }
        var sections = Self.sectionOrder
            .filter { buckets[$0] != nil }
            .map { CardSection(id: $0, title: $0, cards: buckets[$0]!) }
        if let noCoCards = buckets[noCompanyKey] {
            sections.append(CardSection(id: noCompanyKey, title: noCompanyKey, cards: noCoCards))
        }
        return sections
    }

    // 日時順グループ化
    private func groupByDate(_ cards: [BusinessCard]) -> [CardSection] {
        let cal = Calendar.current
        let now = Date()
        let startOfToday   = cal.startOfDay(for: now)
        let startOfWeek    = cal.dateInterval(of: .weekOfYear, for: now)?.start ?? startOfToday
        let startOfMonth   = cal.dateInterval(of: .month, for: now)?.start ?? startOfToday
        let threeMonthsAgo = cal.date(byAdding: .month, value: -3, to: startOfMonth) ?? startOfToday

        let bucketDefs: [(key: String, predicate: (Date) -> Bool)] = [
            ("今日",      { $0 >= startOfToday }),
            ("今週",      { $0 >= startOfWeek && $0 < startOfToday }),
            ("今月",      { $0 >= startOfMonth && $0 < startOfWeek }),
            ("3ヶ月以内", { $0 >= threeMonthsAgo && $0 < startOfMonth }),
            ("それ以前",  { $0 < threeMonthsAgo }),
        ]

        var buckets: [String: [BusinessCard]] = [:]
        for card in cards {
            let date = card.createdAt ?? .distantPast
            let key = bucketDefs.first(where: { $0.predicate(date) })?.key ?? "それ以前"
            buckets[key, default: []].append(card)
        }
        return bucketDefs
            .map { $0.key }
            .filter { buckets[$0] != nil }
            .map { CardSection(id: $0, title: $0, cards: buckets[$0]!) }
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
