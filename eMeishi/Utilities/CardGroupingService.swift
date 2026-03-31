import Foundation

// カード一覧のセクション分けグルーピングロジック
enum CardGroupingService {

    // かな行・アルファベットのセクション順序（表示順を固定）
    private static let kanaSectionOrder: [String] = [
        "あ行", "か行", "さ行", "た行", "な行", "は行", "ま行", "や行", "ら行", "わ行"
    ]
    private static let alphabetOrder: [String] = (UInt8(ascii: "A")...UInt8(ascii: "Z")).map { String(bytes: [$0], encoding: .utf8)! }
    static let sectionOrder: [String] = kanaSectionOrder + alphabetOrder + ["その他"]

    // 先頭文字からセクションキーを返す（日本語かな行・アルファベット・その他）
    static func sectionKey(for text: String) -> String {
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

    // 50音・アルファベット順の共通グループ化ロジック
    private static func groupBySection(_ cards: [BusinessCard], ascending: Bool,
                                       keyExtractor: (BusinessCard) -> String,
                                       trailingKey: String? = nil) -> [CardSection] {
        var buckets: [String: [BusinessCard]] = [:]
        for card in cards {
            let raw = keyExtractor(card)
            let key = raw.isEmpty ? (trailingKey ?? "その他") : sectionKey(for: raw)
            buckets[key, default: []].append(card)
        }
        let order = ascending ? sectionOrder : sectionOrder.reversed()
        var sections = order
            .filter { buckets[$0] != nil }
            .map { CardSection(id: $0, title: $0, cards: buckets[$0]!) }
        if let tk = trailingKey, let trailing = buckets[tk] {
            sections.append(CardSection(id: tk, title: tk, cards: trailing))
        }
        return sections
    }

    // 名前順グループ化
    static func groupByName(_ cards: [BusinessCard], ascending: Bool) -> [CardSection] {
        groupBySection(cards, ascending: ascending) { card in
            let reading = card.lastNameReading?.trimmingCharacters(in: .whitespaces) ?? ""
            return reading.isEmpty
                ? (card.lastName?.isEmpty == false ? card.lastName! : card.firstName) ?? ""
                : reading
        }
    }

    // 会社名順グループ化（会社名なしは常に末尾）
    static func groupByCompany(_ cards: [BusinessCard], ascending: Bool) -> [CardSection] {
        groupBySection(cards, ascending: ascending,
                       keyExtractor: { $0.companySortKey },
                       trailingKey: "（会社名なし）")
    }

    // 日時順グループ化
    static func groupByDate(_ cards: [BusinessCard],
                            dateOf: (BusinessCard) -> Date?,
                            ascending: Bool) -> [CardSection] {
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
            let date = dateOf(card) ?? .distantPast
            let key = bucketDefs.first(where: { $0.predicate(date) })?.key ?? "それ以前"
            buckets[key, default: []].append(card)
        }
        let keys = ascending ? bucketDefs.map { $0.key }.reversed() : bucketDefs.map { $0.key }
        return keys
            .filter { buckets[$0] != nil }
            .map { CardSection(id: $0, title: $0, cards: buckets[$0]!) }
    }
}
