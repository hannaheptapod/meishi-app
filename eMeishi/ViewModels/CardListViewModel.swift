import Foundation
import CoreData
import Combine
import SwiftUI
import os

// ソートキー（4種）
enum CardSortKey: String, CaseIterable, Identifiable {
    case name      = "名前"
    case company   = "会社名"
    case createdAt = "登録日時"
    case updatedAt = "更新日時"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .name:      return "person.text.rectangle"
        case .company:   return "building.2"
        case .createdAt: return "calendar.badge.plus"
        case .updatedAt: return "calendar.badge.clock"
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
    @Published var allTags: [Tag] = []
    @Published var selectedTagIDs: Set<UUID> = []
    @Published var showFavoritesOnly: Bool = false
    @Published var sortKey: CardSortKey {
        didSet { SettingsStore.shared.sortKey = sortKey.rawValue }
    }
    @Published var sortAscending: Bool {
        didSet { SettingsStore.shared.sortAscending = sortAscending }
    }

    // 検索中かどうか（セクション表示 vs フラット表示の切替に使用）
    var isSearchActive: Bool { !searchText.trimmingCharacters(in: .whitespaces).isEmpty }

    // フィルタが適用されているか
    var isFilterActive: Bool { showFavoritesOnly || !selectedTagIDs.isEmpty }

    // タップでキー選択 or 昇降順トグル
    func toggleSort(key: CardSortKey) {
        if sortKey == key {
            sortAscending.toggle()
        } else {
            sortKey = key
            // デフォルト方向：名前・会社 → 昇順、日時系 → 降順（新しい順）
            sortAscending = (key == .name || key == .company)
        }
        fetchCards()
    }

    private let context: NSManagedObjectContext
    private var cancellables = Set<AnyCancellable>()

    init(context: NSManagedObjectContext? = nil) {
        if let context = context {
            self.context = context
        } else if ProcessInfo.processInfo.arguments.contains("-UITestMode") {
            self.context = PersistenceController.preview.container.viewContext
        } else {
            self.context = PersistenceController.shared.container.viewContext
        }

        // SettingsStore から前回のソート設定を復元
        let settings = SettingsStore.shared
        self.sortKey = CardSortKey(rawValue: settings.sortKey) ?? .createdAt
        self.sortAscending = settings.sortAscending

        fetchCards()
        fetchTags()
        assignInitialSortOrderIfNeeded()

        // 閾値が変わったら重複検出を再実行
        SettingsStore.shared.$duplicateThreshold
            .dropFirst()
            .sink { [weak self] _ in self?.detectDuplicates() }
            .store(in: &cancellables)
    }

    // MARK: - データ取得

    func fetchCards() {
        let request = BusinessCard.fetchRequest()
        let asc = sortAscending
        switch sortKey {
        case .name:
            request.sortDescriptors = [
                NSSortDescriptor(keyPath: \BusinessCard.lastName,  ascending: asc),
                NSSortDescriptor(keyPath: \BusinessCard.firstName, ascending: asc)
            ]
        case .company:
            request.sortDescriptors = [
                NSSortDescriptor(keyPath: \BusinessCard.company,   ascending: asc),
                NSSortDescriptor(keyPath: \BusinessCard.lastName,  ascending: asc)
            ]
        case .createdAt:
            request.sortDescriptors = [NSSortDescriptor(keyPath: \BusinessCard.createdAt, ascending: asc)]
        case .updatedAt:
            request.sortDescriptors = [NSSortDescriptor(keyPath: \BusinessCard.updatedAt, ascending: asc)]
        }
        do {
            var fetched = try context.fetch(request)
            // 名前順・会社名順はふりがな / companySortKey 優先で Swift 側ソート
            if sortKey == .name {
                fetched.sort {
                    let lhs = ($0.lastNameReading?.isEmpty == false ? $0.lastNameReading! : $0.lastName ?? "")
                           + ($0.firstNameReading?.isEmpty == false ? $0.firstNameReading! : $0.firstName ?? "")
                    let rhs = ($1.lastNameReading?.isEmpty == false ? $1.lastNameReading! : $1.lastName ?? "")
                           + ($1.firstNameReading?.isEmpty == false ? $1.firstNameReading! : $1.firstName ?? "")
                    return asc
                        ? lhs.localizedStandardCompare(rhs) == .orderedAscending
                        : lhs.localizedStandardCompare(rhs) == .orderedDescending
                }
            } else if sortKey == .company {
                fetched.sort {
                    let lhs = $0.companySortKey + ($0.lastNameReading ?? $0.lastName ?? "")
                    let rhs = $1.companySortKey + ($1.lastNameReading ?? $1.lastName ?? "")
                    return asc
                        ? lhs.localizedStandardCompare(rhs) == .orderedAscending
                        : lhs.localizedStandardCompare(rhs) == .orderedDescending
                }
            }
            cards = fetched
            detectDuplicates()
            updateFilteredCards()
        } catch {
            AppLogger.persistence.error("名刺の取得に失敗しました: \(error)")
        }
    }

    // MARK: - お気に入り

    func toggleFavorite(_ card: BusinessCard) {
        card.isFavorite.toggle()
        card.updatedAt = Date()
        save()
    }

    /// 選択中のカードをすべてお気に入りに追加（すでに全てお気に入りなら全解除）
    func toggleBulkFavorite(ids: Set<BusinessCard.ID>) {
        let targets = filteredCards.filter { ids.contains($0.id) }
        let allFavorited = targets.allSatisfy { $0.isFavorite }
        for card in targets {
            card.isFavorite = !allFavorited
            card.updatedAt = Date()
        }
        save()
    }

    // MARK: - タグ管理

    func fetchTags() {
        let request = Tag.fetchRequest()
        request.sortDescriptors = [
            NSSortDescriptor(keyPath: \Tag.sortOrder, ascending: true),
            NSSortDescriptor(keyPath: \Tag.name, ascending: true),
        ]
        do {
            allTags = try context.fetch(request)
        } catch {
            AppLogger.persistence.error("タグの取得に失敗しました: \(error)")
        }
    }

    func createTag(name: String, colorHex: String) {
        let tag = Tag(context: context)
        tag.id = UUID()
        tag.name = name
        tag.colorHex = colorHex
        tag.sortOrder = Int16(allTags.count)
        tag.createdAt = Date()
        do {
            try context.save()
            fetchTags()
        } catch {
            errorMessage = "タグの作成に失敗しました: \(error.localizedDescription)"
        }
    }

    func updateTag(_ tag: Tag, name: String, colorHex: String) {
        tag.name = name
        tag.colorHex = colorHex
        do {
            try context.save()
            fetchTags()
        } catch {
            errorMessage = "タグの更新に失敗しました: \(error.localizedDescription)"
        }
    }

    func deleteTag(_ tag: Tag) {
        context.delete(tag)
        selectedTagIDs.remove(tag.id ?? UUID())
        do {
            try context.save()
            fetchTags()
            updateFilteredCards()
        } catch {
            errorMessage = "タグの削除に失敗しました: \(error.localizedDescription)"
        }
    }

    func moveTag(from source: IndexSet, to destination: Int) {
        var reordered = allTags
        reordered.move(fromOffsets: source, toOffset: destination)
        for (index, tag) in reordered.enumerated() {
            tag.sortOrder = Int16(index)
        }
        save()
        fetchTags()
    }

    /// マイグレーション後の初回起動時に既存タグへ sortOrder を採番
    func assignInitialSortOrderIfNeeded() {
        guard !allTags.isEmpty else { return }
        let allZero = allTags.allSatisfy { $0.sortOrder == 0 }
        guard allZero, allTags.count > 1 else { return }
        for (index, tag) in allTags.enumerated() {
            tag.sortOrder = Int16(index)
        }
        save()
        fetchTags()
    }

    func toggleTagFilter(_ tag: Tag) {
        guard let id = tag.id else { return }
        if selectedTagIDs.contains(id) {
            selectedTagIDs.remove(id)
        } else {
            selectedTagIDs.insert(id)
        }
        updateFilteredCards()
    }

    func toggleFavoritesFilter() {
        showFavoritesOnly.toggle()
        updateFilteredCards()
    }

    // MARK: - 検索フィルタ

    private func updateFilteredCards() {
        var result = cards

        // お気に入りフィルタ
        if showFavoritesOnly {
            result = result.filter { $0.isFavorite }
        }

        // タグフィルタ（選択されたタグすべてを持つカードのみ）
        if !selectedTagIDs.isEmpty {
            result = result.filter { card in
                let cardTagIDs = Set((card.tags as? Set<Tag> ?? []).compactMap { $0.id })
                return selectedTagIDs.isSubset(of: cardTagIDs)
            }
        }

        // テキスト検索
        let q = searchText.trimmingCharacters(in: .whitespaces)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        if !q.isEmpty {
            result = result.filter { card in
                func match(_ s: String?) -> Bool {
                    s?.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
                        .contains(q) ?? false
                }
                return match(card.fullName)
                    || match(card.fullNameReading)
                    || match(card.company)
                    || match(card.companyReading)
                    || match(card.title)
                    || match(card.email)
                    || match(card.phone)
                    || match(card.address)
            }
        }
        filteredCards = result
        updateGroupedCards()
    }

    // MARK: - セクション分けグループ化（CardGroupingService に委譲）

    private func updateGroupedCards() {
        guard !isSearchActive else {
            groupedCards = []
            return
        }
        let source = isFilterActive ? filteredCards : cards
        switch sortKey {
        case .name:
            groupedCards = CardGroupingService.groupByName(source, ascending: sortAscending)
        case .company:
            groupedCards = CardGroupingService.groupByCompany(source, ascending: sortAscending)
        case .createdAt:
            groupedCards = CardGroupingService.groupByDate(source, dateOf: { $0.createdAt }, ascending: sortAscending)
        case .updatedAt:
            groupedCards = CardGroupingService.groupByDate(source, dateOf: { $0.updatedAt }, ascending: sortAscending)
        }
    }

    // MARK: - 一括操作（選択モード）

    func selectedCards(from ids: Set<BusinessCard.ID>) -> [BusinessCard] {
        cards.filter { ids.contains($0.id) }
    }

    func exportSelectedCSV(ids: Set<BusinessCard.ID>) {
        performExport(selectedCards(from: ids), label: "CSVエクスポート",
                      export: ExportService.shared.exportCSV)
    }

    func exportSelectedVCard(ids: Set<BusinessCard.ID>) {
        performExport(selectedCards(from: ids), label: "vCardエクスポート",
                      export: ExportService.shared.exportVCard)
    }

    func addTagToCards(tag: Tag, ids: Set<BusinessCard.ID>) {
        let selected = selectedCards(from: ids)
        for card in selected {
            card.addToTags(tag)
            card.updatedAt = Date()
        }
        save()
    }

    func removeTagFromCards(tag: Tag, ids: Set<BusinessCard.ID>) {
        let selected = selectedCards(from: ids)
        for card in selected {
            card.removeFromTags(tag)
            card.updatedAt = Date()
        }
        save()
    }

    /// カード単体のタグトグル（コンテキストメニュー用）
    func toggleTag(_ tag: Tag, on card: BusinessCard) {
        let cardTags = card.tags as? Set<Tag> ?? []
        if cardTags.contains(tag) {
            card.removeFromTags(tag)
        } else {
            card.addToTags(tag)
        }
        card.updatedAt = Date()
        save()
    }

    // MARK: - 重複検出

    func detectDuplicates() {
        let checker = DuplicateChecker(threshold: SettingsStore.shared.duplicateThreshold)
        // 即時: ルールベースで表示
        duplicatePairs = checker.findDuplicates(in: cards)
        // 非同期: AI二次判定でボーダーライン候補を追加
        let snapshot = cards
        Task { @MainActor in
            let enhanced = await checker.findDuplicatesWithAI(in: snapshot)
            // カードが差し替えられていたら反映しない
            guard snapshot.count == self.cards.count else { return }
            self.duplicatePairs = enhanced
        }
    }

    // MARK: - エクスポート

    func exportCSV() {
        performExport(cards, label: "CSVエクスポート",
                      export: ExportService.shared.exportCSV)
    }

    func exportVCard() {
        performExport(cards, label: "vCardエクスポート",
                      export: ExportService.shared.exportVCard)
    }

    private func performExport(_ cards: [BusinessCard], label: String,
                               export: ([CardExportDTO]) throws -> URL) {
        guard !cards.isEmpty else { return }
        let dtos = cards.map { $0.toExportDTO() }
        do {
            exportItem = ExportItem(url: try export(dtos))
        } catch {
            errorMessage = "\(label)に失敗しました: \(error.localizedDescription)"
        }
    }

    // MARK: - コンテキストメニューアクション

    func shareVCard(card: BusinessCard) {
        performExport([card], label: "vCardの生成",
                      export: ExportService.shared.exportVCard)
    }

    func saveToContacts(card: BusinessCard) {
        let dto = card.toExportDTO()
        Task { @MainActor in
            do {
                try await ContactsService.shared.export(card: dto)
            } catch {
                errorMessage = error.localizedDescription
            }
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

    // MARK: - デバッグ用

#if DEBUG
    func seedSampleData() {
        let cal = Calendar.current
        let now = Date()

        typealias Entry = (
            lastName: String, lastNameReading: String,
            firstName: String, firstNameReading: String,
            company: String, companyReading: String,
            department: String, title: String,
            email: String, phone: String, address: String, website: String,
            daysAgo: Int
        )

        let entries: [Entry] = [
            // ── 今日（5件）────────────────────────────
            ("山田", "やまだ",   "太郎",   "たろう",       "株式会社アルファテック",           "あるふぁてっく",
             "営業部",           "営業部長",                 "yamada@alphatech.co.jp",    "03-1234-5678", "東京都渋谷区道玄坂1-2-3",             "https://alphatech.co.jp",    0),
            ("佐藤", "さとう",   "花子",   "はなこ",       "ベータシステムズ株式会社",         "べーたしすてむず",
             "開発部",           "シニアエンジニア",         "sato@betasys.co.jp",        "06-2345-6789", "大阪府大阪市北区梅田2-3-4",           "https://betasys.co.jp",      0),
            ("鈴木", "すずき",   "一郎",   "いちろう",     "ガンマ商事株式会社",               "がんましょうじ",
             "経営企画室",       "代表取締役社長",           "suzuki@gamma-trading.jp",   "052-345-6789", "愛知県名古屋市中区栄3-4-5",           "https://gamma-trading.jp",   0),
            ("田中", "たなか",   "美咲",   "みさき",       "デルタデザイン合同会社",           "でるたでざいん",
             "クリエイティブ部", "UIデザイナー",             "tanaka@delta-design.com",   "011-456-7890", "北海道札幌市中央区大通西1-2",         "https://delta-design.com",   0),
            ("高橋", "たかはし", "健司",   "けんじ",       "イプシロン医療株式会社",           "いぷしろんいりょう",
             "医療情報部",       "システム課長",             "takahashi@epsilon-med.jp",  "092-567-8901", "福岡県福岡市博多区博多駅前1-1-1",     "https://epsilon-med.jp",     0),

            // ── 今週（10件）──────────────────────────
            ("伊藤", "いとう",   "真由",   "まゆ",         "ゼータファイナンス株式会社",       "ぜーたふぁいなんす",
             "財務部",           "主任",                     "ito@zeta-finance.co.jp",    "03-2345-6789", "東京都千代田区丸の内1-5-6",           "https://zeta-finance.co.jp", 2),
            ("渡辺", "わたなべ", "拓也",   "たくや",       "エータ教育株式会社",               "えーたきょういく",
             "コンテンツ部",     "コンテンツディレクター",   "watanabe@eta-edu.jp",       "045-678-9012", "神奈川県横浜市西区みなとみらい2-3",   "https://eta-edu.jp",         2),
            ("中村", "なかむら", "さくら", "さくら",       "シータ建設株式会社",               "しーたけんせつ",
             "設計部",           "一級建築士",               "nakamura@theta-const.co.jp","022-789-0123", "宮城県仙台市青葉区一番町4-5-6",       "https://theta-const.co.jp",  3),
            ("小林", "こばやし", "剛",     "つよし",       "イオタ物流株式会社",               "いおたぶつりゅう",
             "物流管理部",       "部長",                     "kobayashi@iota-logi.jp",    "082-890-1234", "広島県広島市中区紙屋町1-3-5",         "https://iota-logi.jp",       3),
            ("加藤", "かとう",   "奈々",   "なな",         "カッパ出版株式会社",               "かっぱしゅっぱん",
             "編集部",           "編集長",                   "kato@kappa-pub.co.jp",      "03-3456-7890", "東京都文京区本郷3-7-8",               "https://kappa-pub.co.jp",    4),
            ("松本", "まつもと", "浩二",   "こうじ",       "ラムダコンサルティング株式会社",   "らむだこんさるてぃんぐ",
             "戦略部",           "シニアコンサルタント",     "matsumoto@lambda-cons.jp",  "03-4567-8901", "東京都港区赤坂2-4-6",                 "https://lambda-cons.jp",     4),
            ("井上", "いのうえ", "千恵",   "ちえ",         "ミューインシュアランス株式会社",   "みゅーいんしゅあらんす",
             "損害保険部",       "営業課長",                 "inoue@mu-insurance.co.jp",  "06-3456-7890", "大阪府大阪市中央区本町3-5-7",         "https://mu-insurance.co.jp", 4),
            ("木村", "きむら",   "亮",     "りょう",       "ニューメディア株式会社",           "にゅーめでぃあ",
             "広告部",           "クリエイティブディレクター","kimura@nu-media.co.jp",    "03-5678-9012", "東京都新宿区西新宿6-7-8",             "https://nu-media.co.jp",     5),
            ("林",   "はやし",   "明美",   "あけみ",       "クシー食品株式会社",               "くしーしょくひん",
             "商品開発部",       "研究員",                   "hayashi@xi-foods.co.jp",    "054-901-2345", "静岡県静岡市葵区追手町1-2",           "https://xi-foods.co.jp",     5),
            ("清水", "しみず",   "大輔",   "だいすけ",     "オミクロンソフト株式会社",         "おみくろんそふと",
             "開発2部",          "テックリード",             "shimizu@omicron-soft.jp",   "03-6789-0123", "東京都品川区大崎1-8-9",               "https://omicron-soft.jp",    5),

            // ── 今月（15件）──────────────────────────
            ("山口", "やまぐち", "恵子",   "けいこ",       "パイコンサルタンツ株式会社",       "ぱいこんさるたんつ",
             "人事部",           "人事部長",                 "yamaguchi@pi-consult.co.jp","03-7890-1234", "東京都千代田区霞が関3-1-2",           "https://pi-consult.co.jp",   8),
            ("斎藤", "さいとう", "直樹",   "なおき",       "ローエナジー株式会社",             "ろーえなじー",
             "技術部",           "技術部長",                 "saito@rho-energy.jp",       "011-234-5678", "北海道札幌市豊平区月寒東1-1-1",       "https://rho-energy.jp",      9),
            ("松田", "まつだ",   "由美",   "ゆみ",         "シグマアパレル株式会社",           "しぐまあぱれる",
             "デザイン部",       "パタンナー",               "matsuda@sigma-apparel.jp",  "06-4567-8901", "大阪府大阪市浪速区難波中2-3-4",       "https://sigma-apparel.jp",   10),
            ("藤田", "ふじた",   "正人",   "まさと",       "タウリクス株式会社",               "たうりくす",
             "製品部",           "プロダクトマネージャー",   "fujita@taurix.co.jp",       "03-8901-2345", "東京都台東区上野7-8-9",               "https://taurix.co.jp",       11),
            ("岡田", "おかだ",   "麻衣",   "まい",         "ウプシロン保険有限会社",           "うぷしろんほけん",
             "総務部",           "総務課長",                 "okada@upsilon-ins.jp",      "052-678-9012", "愛知県名古屋市東区葵1-5-7",           "https://upsilon-ins.jp",     12),
            ("後藤", "ごとう",   "博",     "ひろし",       "ファイテック株式会社",             "ふぁいてっく",
             "品質管理部",       "QAエンジニア",             "goto@phitech.co.jp",        "075-345-6789", "京都府京都市下京区四条通1-2-3",       "https://phitech.co.jp",      12),
            ("村田", "むらた",   "友美",   "ともみ",       "カイアドバンス株式会社",           "かいあどばんす",
             "マーケティング部", "マーケティングマネージャー","murata@chi-advance.jp",    "03-9012-3456", "東京都墨田区押上1-1-2",               "https://chi-advance.jp",     13),
            ("坂本", "さかもと", "哲也",   "てつや",       "プサイテクノロジー株式会社",       "ぷさいてくのろじー",
             "AI研究部",         "主任研究員",               "sakamoto@psi-tech.co.jp",   "06-5678-9012", "大阪府吹田市江坂町1-2-3",             "https://psi-tech.co.jp",     14),
            ("橋本", "はしもと", "百合子", "ゆりこ",       "オメガリテール株式会社",           "おめがりてーる",
             "店舗開発部",       "エリアマネージャー",       "hashimoto@omega-retail.jp", "098-456-7890", "沖縄県那覇市久茂地1-3-5",             "https://omega-retail.jp",    15),
            ("石田", "いしだ",   "修",     "おさむ",       "アルゴリズム株式会社",             "あるごりずむ",
             "データ分析部",     "データサイエンティスト",   "ishida@algorithm.co.jp",    "03-0123-4567", "東京都中野区中野4-5-6",               "https://algorithm.co.jp",    16),
            ("藤井", "ふじい",   "香織",   "かおり",       "バイオサイエンス株式会社",         "ばいおさいえんす",
             "研究開発部",       "研究員",                   "fujii@bioscience.co.jp",    "078-567-8901", "兵庫県神戸市中央区三宮町2-4-6",       "https://bioscience.co.jp",   17),
            ("前田", "まえだ",   "慎一",   "しんいち",     "クラウドネット株式会社",           "くらうどねっと",
             "インフラ部",       "インフラエンジニア",       "maeda@cloudnet.jp",         "03-1357-2468", "東京都豊島区池袋2-3-4",               "https://cloudnet.jp",        18),
            ("小川", "おがわ",   "雅子",   "まさこ",       "デジタルウェーブ合同会社",         "でじたるうぇーぶ",
             "事業開発部",       "ビジネスデベロッパー",     "ogawa@digitalwave.co.jp",   "06-6789-0123", "大阪府堺市堺区市之町東1-2",           "https://digitalwave.co.jp",  19),
            ("池田", "いけだ",   "俊",     "しゅん",       "エコソリューションズ株式会社",     "えこそりゅーしょんず",
             "環境部",           "環境コンサルタント",       "ikeda@eco-solutions.jp",    "082-234-5678", "広島県広島市南区宇品海岸3-1-2",       "https://eco-solutions.jp",   20),
            ("西村", "にしむら", "綾",     "あや",         "グローバルリンク株式会社",         "ぐろーばるりんく",
             "国際事業部",       "海外営業マネージャー",     "nishimura@globallink.co.jp","03-2468-1357", "東京都江東区木場3-4-5",               "https://globallink.co.jp",   20),

            // ── 3ヶ月以内（10件）─────────────────────
            ("岡本", "おかもと", "裕之",   "ひろゆき",     "サイバーロジック株式会社",         "さいばーろじっく",
             "セキュリティ部",   "セキュリティエンジニア",   "okamoto@cyberlogic.co.jp",  "03-3579-2468", "東京都新宿区四谷1-2-3",               "https://cyberlogic.co.jp",   40),
            ("吉田", "よしだ",   "典子",   "のりこ",       "スマートホーム有限会社",           "すまーとほーむ",
             "製品部",           "IoTエンジニア",            "yoshida@smarthome.jp",      "052-890-1234", "愛知県名古屋市千種区今池3-5-7",       "https://smarthome.jp",       45),
            ("山本", "やまもと", "誠",     "まこと",       "フィンテックジャパン株式会社",     "ふぃんてっくじゃぱん",
             "決済サービス部",   "プロジェクトマネージャー", "yamamoto@fintechjp.co.jp",  "03-4680-1357", "東京都中央区日本橋室町1-5-6",         "https://fintechjp.co.jp",    50),
            ("中島", "なかじま", "瑠衣",   "るい",         "ヘルスケアテック株式会社",         "へるすけあてっく",
             "臨床開発部",       "臨床開発マネージャー",     "nakajima@healthtech.jp",    "06-7890-1234", "大阪府大阪市此花区桜島1-1-1",         "https://healthtech.jp",      55),
            ("野口", "のぐち",   "徹",     "とおる",       "モビリティソリューション株式会社", "もびりてぃそりゅーしょん",
             "EV開発部",         "シニアエンジニア",         "noguchi@mobility-sol.co.jp","045-901-2345", "神奈川県横浜市鶴見区鶴見中央2-3",     "https://mobility-sol.co.jp", 55),
            ("原田", "はらだ",   "美穂",   "みほ",         "エドテックラボ合同会社",           "えどてっくらぼ",
             "教育コンテンツ部", "カリキュラムデザイナー",   "harada@edtechlab.jp",       "03-5791-2468", "東京都世田谷区三軒茶屋2-4-6",         "https://edtechlab.jp",       60),
            ("川口", "かわぐち", "雄大",   "ゆうだい",     "スペースベンチャー株式会社",       "すぺーすべんちゃー",
             "宇宙開発部",       "宇宙機エンジニア",         "kawaguchi@spaceventure.jp", "029-234-5678", "茨城県つくば市研究学園5-6-7",         "https://spaceventure.jp",    60),
            ("村上", "むらかみ", "朋子",   "ともこ",       "アグリテック株式会社",             "あぐりてっく",
             "農業DX部",         "農業ICTコンサルタント",    "murakami@agritech.co.jp",   "011-567-8901", "北海道帯広市西2条南5-1",              "https://agritech.co.jp",     65),
            ("横山", "よこやま", "智也",   "ともや",       "ソーシャルインパクト株式会社",     "そーしゃるいんぱくと",
             "事業推進部",       "事業推進マネージャー",     "yokoyama@socialimpact.jp",  "06-8901-2345", "大阪府大阪市西区靱本町1-2-3",         "https://socialimpact.jp",    68),
            ("石川", "いしかわ", "えみ",   "えみ",         "クリエイティブスタジオ有限会社",   "くりえいてぃぶすたじお",
             "映像制作部",       "ビデオプロデューサー",     "ishikawa@cstudio.co.jp",    "03-6802-4689", "東京都杉並区阿佐ヶ谷北3-5-7",         "https://cstudio.co.jp",      70),

            // ── それ以前（10件）──────────────────────
            ("三浦", "みうら",   "伸介",   "しんすけ",     "レガシーシステムズ株式会社",       "れがしーしすてむず",
             "システム部",       "IT部長",                   "miura@legacysys.co.jp",     "03-7913-5791", "東京都大田区蒲田4-5-6",               "https://legacysys.co.jp",   100),
            ("西田", "にしだ",   "久美子", "くみこ",       "パシフィックトレード株式会社",     "ぱしふぃっくとれーど",
             "貿易部",           "貿易事務マネージャー",     "nishida@pacific-trade.jp",  "06-9012-3456", "大阪府大阪市港区弁天1-3-5",           "https://pacific-trade.jp",  110),
            ("菊池", "きくち",   "大樹",   "だいき",       "ノーザンソフト株式会社",           "のーざんそふと",
             "開発部",           "フルスタックエンジニア",   "kikuchi@northernsoft.co.jp","011-678-9012", "北海道函館市若松町2-4",               "https://northernsoft.co.jp", 120),
            ("長谷川","はせがわ", "遥",    "はるか",       "センチュリー不動産株式会社",       "せんちゅりーふどうさん",
             "賃貸管理部",       "管理課長",                 "hasegawa@century-re.jp",    "03-8024-6802", "東京都港区麻布十番1-2-3",             "https://century-re.jp",     130),
            ("福田", "ふくだ",   "義雄",   "よしお",       "ウエスタンフード株式会社",         "うえすたんふーど",
             "生産管理部",       "工場長",                   "fukuda@western-food.co.jp", "086-345-6789", "岡山県岡山市北区奉還町1-5-7",         "https://western-food.co.jp", 140),
            ("近藤", "こんどう", "恵",     "めぐみ",       "メトロポリスバンク株式会社",       "めとろぽりすばんく",
             "法人営業部",       "上席営業部長",             "kondo@metropolis-bk.co.jp", "03-9135-7913", "東京都千代田区大手町2-6-8",           "https://metropolis-bk.co.jp",150),
            ("土屋", "つちや",   "宗一郎", "そういちろう", "スターライトエンタメ株式会社",     "すたーらいとえんため",
             "コンテンツ制作部", "プロデューサー",           "tsuchiya@starlight-ent.jp", "03-0246-8024", "東京都渋谷区神南1-4-6",               "https://starlight-ent.jp",  160),
            ("浜田", "はまだ",   "貴子",   "たかこ",       "ノードネットワーク株式会社",       "のーどねっとわーく",
             "ネットワーク部",   "ネットワークアーキテクト", "hamada@nodenet.co.jp",      "06-0123-4567", "大阪府大阪市都島区都島本通1-2-3",     "https://nodenet.co.jp",     170),
            ("桑原", "くわはら", "亮太",   "りょうた",     "テラバイトストレージ株式会社",     "てらばいとすとれーじ",
             "ストレージ部",     "ストレージエンジニア",     "kuwahara@terabyte-st.co.jp","03-1358-2469", "東京都江戸川区西葛西6-7-8",           "https://terabyte-st.co.jp", 180),
            ("矢野", "やの",     "裕子",   "ゆうこ",       "グリーンビルディング合同会社",     "ぐりーんびるでぃんぐ",
             "環境設計部",       "環境建築家",               "yano@greenbuild.jp",        "03-2469-3580", "東京都目黒区自由が丘1-2-3",           "https://greenbuild.jp",     200),
        ]

        for entry in entries {
            let card = BusinessCard(context: context)
            card.id               = UUID()
            card.lastName         = entry.lastName
            card.lastNameReading  = entry.lastNameReading
            card.firstName        = entry.firstName
            card.firstNameReading = entry.firstNameReading
            card.company          = entry.company
            card.companyReading   = entry.companyReading
            card.department       = entry.department
            card.title            = entry.title
            card.email            = entry.email
            card.phone            = entry.phone
            card.address          = entry.address
            card.website          = entry.website
            let date = cal.date(byAdding: .day, value: -entry.daysAgo, to: now) ?? now
            card.createdAt        = date
            card.updatedAt        = date
        }
        save()
    }
#endif
}
