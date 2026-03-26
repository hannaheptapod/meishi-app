import Foundation
import CoreData
import Combine

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
    @Published var sortKey: CardSortKey = .createdAt
    @Published var sortAscending: Bool = false  // 登録日時は降順（新しい順）がデフォルト

    // 検索中かどうか（セクション表示 vs フラット表示の切替に使用）
    var isSearchActive: Bool { !searchText.trimmingCharacters(in: .whitespaces).isEmpty }

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
            print("名刺の取得に失敗しました: \(error)")
        }
    }

    // MARK: - 検索フィルタ

    private func updateFilteredCards() {
        let q = searchText.trimmingCharacters(in: .whitespaces)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        if q.isEmpty {
            filteredCards = cards
        } else {
            filteredCards = cards.filter { card in
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
        updateGroupedCards()
    }

    // MARK: - セクション分けグループ化

    private func updateGroupedCards() {
        guard !isSearchActive else {
            groupedCards = []
            return
        }
        switch sortKey {
        case .name:
            groupedCards = groupByName(cards, ascending: sortAscending)
        case .company:
            groupedCards = groupByCompany(cards, ascending: sortAscending)
        case .createdAt:
            groupedCards = groupByDate(cards, dateOf: { $0.createdAt }, ascending: sortAscending)
        case .updatedAt:
            groupedCards = groupByDate(cards, dateOf: { $0.updatedAt }, ascending: sortAscending)
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

    // 名前順グループ化（ascending で昇降順を切り替え）
    private func groupByName(_ cards: [BusinessCard], ascending: Bool) -> [CardSection] {
        var buckets: [String: [BusinessCard]] = [:]
        for card in cards {
            // ふりがながあればそちらを使ってセクション分類（ない場合は漢字）
            let reading = card.lastNameReading?.trimmingCharacters(in: .whitespaces) ?? ""
            let name = reading.isEmpty
                ? (card.lastName?.isEmpty == false ? card.lastName! : card.firstName) ?? ""
                : reading
            let key = name.isEmpty ? "その他" : sectionKey(for: name)
            buckets[key, default: []].append(card)
        }
        let order = ascending ? Self.sectionOrder : Self.sectionOrder.reversed()
        return order
            .filter { buckets[$0] != nil }
            .map { CardSection(id: $0, title: $0, cards: buckets[$0]!) }
    }

    // 会社名順グループ化（会社名なしは常に末尾）
    private func groupByCompany(_ cards: [BusinessCard], ascending: Bool) -> [CardSection] {
        let noCompanyKey = "（会社名なし）"
        var buckets: [String: [BusinessCard]] = [:]
        for card in cards {
            // companySortKey（法人格除去・読み優先）でセクション分類
            let sortKey = card.companySortKey
            let key = sortKey.isEmpty ? noCompanyKey : sectionKey(for: sortKey)
            buckets[key, default: []].append(card)
        }
        let order = ascending ? Self.sectionOrder : Self.sectionOrder.reversed()
        var sections = order
            .filter { buckets[$0] != nil }
            .map { CardSection(id: $0, title: $0, cards: buckets[$0]!) }
        if let noCoCards = buckets[noCompanyKey] {
            sections.append(CardSection(id: noCompanyKey, title: noCompanyKey, cards: noCoCards))
        }
        return sections
    }

    // 日時順グループ化（dateOf で createdAt / updatedAt を切り替え、ascending で昇降）
    private func groupByDate(_ cards: [BusinessCard],
                             dateOf: (BusinessCard) -> Date?,
                             ascending: Bool) -> [CardSection] {
        let cal = Calendar.current
        let now = Date()
        let startOfToday   = cal.startOfDay(for: now)
        let startOfWeek    = cal.dateInterval(of: .weekOfYear, for: now)?.start ?? startOfToday
        let startOfMonth   = cal.dateInterval(of: .month, for: now)?.start ?? startOfToday
        let threeMonthsAgo = cal.date(byAdding: .month, value: -3, to: startOfMonth) ?? startOfToday

        // 降順（新しい順）で定義し、昇順時は逆順で使う
        let bucketDefs: [(key: String, predicate: (Date) -> Bool)] = [
            ("今日",      { $0 >= startOfToday }),
            ("今週",      { $0 >= startOfWeek && $0 < startOfToday }),
            ("今月",      { $0 >= startOfMonth && $0 < startOfWeek }),
            ("3ヶ月以内", { $0 >= threeMonthsAgo && $0 < startOfMonth }),
            ("それ以前",  { $0 < threeMonthsAgo }),
        ]

        var buckets: [String: [BusinessCard]] = [:]
        for card in cards {
            let date = dateOf(card) ?? .distantPast
            let key = bucketDefs.first(where: { $0.predicate(date) })?.key ?? "それ以前"
            buckets[key, default: []].append(card)
        }
        let keys = ascending ? bucketDefs.map { $0.key }.reversed() : bucketDefs.map { $0.key }
        return keys
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
            // ── 今日 ───────────────────────────────────
            ("山田", "やまだ", "太郎", "たろう",   "株式会社テックビジョン",   "てっくびじょん",
             "営業部",         "営業部長",           "yamada@techvision.co.jp",    "03-1234-5678", "東京都渋谷区道玄坂1-2-3",         "https://techvision.co.jp",   0),
            ("佐藤", "さとう", "花子", "はなこ",   "グローバル商事株式会社",   "ぐろーばるしょうじ",
             "開発部",         "シニアエンジニア",   "sato@global-shoji.co.jp",    "06-2345-6789", "大阪府大阪市北区梅田2-3-4",       "https://global-shoji.co.jp", 0),

            // ── 今週 ───────────────────────────────────
            ("鈴木", "すずき", "一郎", "いちろう", "有限会社クリエイティブラボ", "くりえいてぃぶらぼ",
             "企画室",         "プロデューサー",     "suzuki@creative-lab.jp",     "090-9876-5432","愛知県名古屋市中区栄3-4-5",       "https://creative-lab.jp",   3),
            ("田中", "たなか", "由美", "ゆみ",     "株式会社テックビジョン",   "てっくびじょん",
             "マーケティング部","ディレクター",      "tanaka@techvision.co.jp",    "03-1234-1111", "東京都千代田区丸の内1-5-6",       "https://techvision.co.jp",   4),
            ("中村", "なかむら","剛",  "つよし",   "グローバル商事株式会社",   "ぐろーばるしょうじ",
             "経理部",         "取締役CFO",          "nakamura@global-shoji.co.jp","06-2345-9999", "大阪府大阪市中央区本町3-5-7",     "https://global-shoji.co.jp", 5),

            // ── 今月 ───────────────────────────────────
            ("高橋", "たかはし","健司", "けんじ",  "アルファテック株式会社",   "あるふぁてっく",
             "医療情報部",     "システム課長",       "takahashi@alphatech.co.jp",  "092-567-8901", "福岡県福岡市博多区博多駅前1-1-1", "https://alphatech.co.jp",   10),
            ("伊藤", "いとう", "真由", "まゆ",     "ゼータファイナンス株式会社", "ぜーたふぁいなんす",
             "財務部",         "主任",               "ito@zeta-finance.co.jp",     "03-2345-6789", "東京都千代田区霞が関3-1-2",       "https://zeta-finance.co.jp", 12),
            ("渡辺", "わたなべ","拓也", "たくや",  "ベータシステムズ株式会社", "べーたしすてむず",
             "コンテンツ部",   "コンテンツディレクター","watanabe@betasys.co.jp",   "045-678-9012", "神奈川県横浜市西区みなとみらい2-3","https://betasys.co.jp",     15),
            ("小林", "こばやし","剛",  "つよし",   "イオタ物流株式会社",       "いおたぶつりゅう",
             "物流管理部",     "部長",               "kobayashi@iota-logi.jp",     "082-890-1234", "広島県広島市中区紙屋町1-3-5",     "https://iota-logi.jp",      18),

            // ── 3ヶ月以内 ──────────────────────────────
            ("加藤", "かとう", "奈々", "なな",     "カッパ出版株式会社",       "かっぱしゅっぱん",
             "編集部",         "編集長",             "kato@kappa-pub.co.jp",       "03-3456-7890", "東京都文京区本郷3-7-8",           "https://kappa-pub.co.jp",   40),
            ("松本", "まつもと","浩二","こうじ",   "ラムダコンサルティング株式会社","らむだこんさるてぃんぐ",
             "戦略部",         "シニアコンサルタント","matsumoto@lambda-cons.jp",  "03-4567-8901", "東京都港区赤坂2-4-6",             "https://lambda-cons.jp",    50),
            ("井上", "いのうえ","千恵","ちえ",     "ミューインシュアランス株式会社","みゅーいんしゅあらんす",
             "損害保険部",     "営業課長",           "inoue@mu-insurance.co.jp",   "06-3456-7890", "大阪府大阪市北区梅田3-5-7",       "https://mu-insurance.co.jp", 60),
            ("木村", "きむら", "亮",   "りょう",   "ニューメディア株式会社",   "にゅーめでぃあ",
             "広告部",         "クリエイティブディレクター","kimura@nu-media.co.jp","03-5678-9012","東京都新宿区西新宿6-7-8",         "https://nu-media.co.jp",    70),

            // ── それ以前 ──────────────────────────────
            ("林",   "はやし", "明美", "あけみ",   "クシー食品株式会社",       "くしーしょくひん",
             "商品開発部",     "研究員",             "hayashi@xi-foods.co.jp",     "054-901-2345", "静岡県静岡市葵区追手町1-2",       "https://xi-foods.co.jp",   100),
            ("清水", "しみず", "大輔", "だいすけ", "オミクロンソフト株式会社", "おみくろんそふと",
             "開発部",         "テックリード",       "shimizu@omicron-soft.jp",    "03-6789-0123", "東京都品川区大崎1-8-9",           "https://omicron-soft.jp",  130),
            ("長谷川","はせがわ","遥", "はるか",   "センチュリー不動産株式会社","せんちゅりーふどうさん",
             "賃貸管理部",     "管理課長",           "hasegawa@century-re.jp",     "03-8024-6802", "東京都港区麻布十番1-2-3",         "https://century-re.jp",    180),
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
