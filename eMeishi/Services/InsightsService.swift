import Foundation
import CoreData

// 人脈インサイトサービス
// 名刺データをCoreData集約クエリで分析し、会社別・エリア別・職種別の統計を返す
// LLM不使用・純粋なデータ集計
class InsightsService {

    static let shared = InsightsService()

    // MARK: - データ構造

    struct Insights {
        var companyGroups: [GroupCount] = []
        var areaGroups: [GroupCount] = []
        var roleCategoryGroups: [GroupCount] = []
        var monthlyTrend: [MonthCount] = []
        var totalCards: Int = 0
    }

    struct GroupCount: Identifiable {
        let id = UUID()
        let label: String
        let count: Int
    }

    struct MonthCount: Identifiable {
        let id = UUID()
        let label: String
        let yearMonth: String
        let count: Int
    }

    // MARK: - 公開API

    func generateInsights(context: NSManagedObjectContext) -> Insights {
        var insights = Insights()

        let request = BusinessCard.fetchRequest()
        guard let cards = try? context.fetch(request) else { return insights }

        insights.totalCards = cards.count
        insights.companyGroups = groupByCompany(cards)
        insights.areaGroups = groupByArea(cards)
        insights.roleCategoryGroups = groupByRoleCategory(cards)
        insights.monthlyTrend = groupByMonth(cards)

        return insights
    }

    // MARK: - 会社別集計

    private func groupByCompany(_ cards: [BusinessCard]) -> [GroupCount] {
        var counts: [String: Int] = [:]
        for card in cards {
            let company = card.company?.trimmingCharacters(in: .whitespaces) ?? ""
            guard !company.isEmpty else { continue }
            counts[company, default: 0] += 1
        }
        return counts.map { GroupCount(label: $0.key, count: $0.value) }
            .sorted { $0.count > $1.count }
    }

    // MARK: - エリア別集計

    private func groupByArea(_ cards: [BusinessCard]) -> [GroupCount] {
        var counts: [String: Int] = [:]
        for card in cards {
            guard let address = card.address, !address.isEmpty else { continue }
            let area = extractPrefectureCity(address)
            guard !area.isEmpty else { continue }
            counts[area, default: 0] += 1
        }
        return counts.map { GroupCount(label: $0.key, count: $0.value) }
            .sorted { $0.count > $1.count }
    }

    /// 住所から都道府県+市区を抽出
    private func extractPrefectureCity(_ address: String) -> String {
        // 都道府県パターン
        let prefPattern = "(北海道|(?:東京|京都|大阪)府|.{2,3}県)"
        // 市区町村パターン
        let cityPattern = "(.{1,5}(?:市|区|町|村))"

        var result = ""
        if let prefRegex = try? NSRegularExpression(pattern: prefPattern),
           let match = prefRegex.firstMatch(in: address, range: NSRange(address.startIndex..., in: address)),
           let range = Range(match.range(at: 1), in: address) {
            result = String(address[range])
        }

        if let cityRegex = try? NSRegularExpression(pattern: prefPattern + cityPattern),
           let match = cityRegex.firstMatch(in: address, range: NSRange(address.startIndex..., in: address)),
           match.numberOfRanges >= 3,
           let range = Range(match.range(at: 2), in: address) {
            result += String(address[range])
        }

        return result
    }

    // MARK: - 職種カテゴリ別集計

    private func groupByRoleCategory(_ cards: [BusinessCard]) -> [GroupCount] {
        var counts: [String: Int] = [:]
        for card in cards {
            let category = categorizeRole(title: card.title, department: card.department)
            counts[category, default: 0] += 1
        }
        return counts.map { GroupCount(label: $0.key, count: $0.value) }
            .sorted { $0.count > $1.count }
    }

    /// 役職・部署キーワードから職種カテゴリを判定
    private func categorizeRole(title: String?, department: String?) -> String {
        let combined = ((title ?? "") + " " + (department ?? "")).lowercased()
        if combined.isEmpty || combined.trimmingCharacters(in: .whitespaces).isEmpty {
            return "未分類"
        }

        let categories: [(String, [String])] = [
            ("エンジニア・技術", ["エンジニア", "engineer", "開発", "技術", "プログラマ", "システム", "テック", "tech", "cto", "se ", "開発部", "devops", "インフラ", "サーバ"]),
            ("経営・役員", ["代表", "社長", "ceo", "取締役", "役員", "chairman", "理事", "オーナー", "founder", "経営"]),
            ("営業・販売", ["営業", "sales", "販売", "セールス", "商事", "渉外", "アカウント"]),
            ("マーケティング・広報", ["マーケ", "marketing", "広報", "pr ", "ブランド", "広告", "宣伝"]),
            ("デザイン・クリエイティブ", ["デザイン", "design", "クリエイティブ", "アート", "ux ", "ui "]),
            ("管理職", ["部長", "課長", "マネージャ", "manager", "リーダー", "leader", "統括", "室長", "主幹"]),
            ("人事・総務", ["人事", "hr ", "採用", "総務", "労務", "人材"]),
            ("財務・経理", ["財務", "経理", "会計", "finance", "cfo", "ファイナンス"]),
            ("企画・戦略", ["企画", "戦略", "プランナー", "planner", "事業開発"]),
            ("コンサルタント", ["コンサル", "consul", "アドバイザ", "advisor"]),
            ("医療・研究", ["医師", "doctor", "研究", "教授", "准教授", "博士", "研究員"]),
            ("法務", ["法務", "弁護士", "lawyer", "法律", "コンプライアンス"]),
        ]

        for (category, keywords) in categories {
            if keywords.contains(where: { combined.contains($0) }) {
                return category
            }
        }
        return "その他"
    }

    // MARK: - 月別推移

    private func groupByMonth(_ cards: [BusinessCard]) -> [MonthCount] {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM"

        let displayFormatter = DateFormatter()
        displayFormatter.dateFormat = "yyyy年M月"

        var counts: [String: (display: String, count: Int)] = [:]
        for card in cards {
            guard let date = card.createdAt else { continue }
            let key = formatter.string(from: date)
            let display = displayFormatter.string(from: date)
            counts[key, default: (display, 0)].count += 1
        }
        return counts.map { MonthCount(label: $0.value.display, yearMonth: $0.key, count: $0.value.count) }
            .sorted { $0.yearMonth > $1.yearMonth }
    }
}
