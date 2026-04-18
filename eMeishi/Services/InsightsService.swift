import Foundation
import CoreData
import os
#if canImport(FoundationModels)
import FoundationModels
#endif

// 人脈インサイトサービス
// 名刺データをCoreData集約クエリで分析し、会社別・エリア別・職種別の統計を返す
// 集計部分は LLM 不使用、AI ナラティブ生成は Foundation Models（iOS 26+）を使用
@MainActor
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

    func generateInsights(context: NSManagedObjectContext? = nil) -> Insights {
        var insights = Insights()

        let context = context ?? PersistenceController.shared.container.viewContext
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
    /// - 政令指定都市（横浜市西区など）は市までで止め、区は含めない
    /// - 東京23区は「東京都○○区」まで返す
    private func extractPrefectureCity(_ address: String) -> String {
        // 都道府県パターン（東京都・大阪府・京都府・北海道・各県を網羅）
        let prefPattern = "(北海道|東京都|(?:大阪|京都)府|.{2,3}県)"

        guard let prefRegex = try? NSRegularExpression(pattern: prefPattern),
              let prefMatch = prefRegex.firstMatch(in: address,
                                                   range: NSRange(address.startIndex..., in: address)),
              let prefRange = Range(prefMatch.range(at: 1), in: address) else {
            return ""
        }
        let prefecture = String(address[prefRange])
        let rest = String(address[prefRange.upperBound...])

        // 市を優先して抽出（「横浜市西区」の場合は「横浜市」で止める）
        if let cityRegex = try? NSRegularExpression(pattern: "^.{1,5}市"),
           let cityMatch = cityRegex.firstMatch(in: rest,
                                                range: NSRange(rest.startIndex..., in: rest)),
           let cityRange = Range(cityMatch.range, in: rest) {
            return prefecture + String(rest[cityRange])
        }

        // 市がない場合は区（東京23区など）を抽出
        if let wardRegex = try? NSRegularExpression(pattern: "^.{1,5}区"),
           let wardMatch = wardRegex.firstMatch(in: rest,
                                                range: NSRange(rest.startIndex..., in: rest)),
           let wardRange = Range(wardMatch.range, in: rest) {
            return prefecture + String(rest[wardRange])
        }

        // 町・村にも対応
        if let townRegex = try? NSRegularExpression(pattern: "^.{1,5}[町村]"),
           let townMatch = townRegex.firstMatch(in: rest,
                                                range: NSRange(rest.startIndex..., in: rest)),
           let townRange = Range(townMatch.range, in: rest) {
            return prefecture + String(rest[townRange])
        }

        return prefecture
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

    // MARK: - AI ナラティブ（Pro 機能）

    enum NarrativeError: Error {
        case unavailable
        case generationFailed
    }

    /// 集計結果を AI が読み解いた短い解説文を返す。
    /// Foundation Models（iOS 26+ かつ Apple Intelligence 有効）が必要。
    func generateNarrative(insights: Insights) async throws -> String {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            guard case .available = SystemLanguageModel.default.availability else {
                throw NarrativeError.unavailable
            }
            let summary = buildSummaryForLLM(insights)
            let instructions = """
                あなたは名刺管理アプリのアナリストです。
                ユーザーの名刺集計データを 3〜4 文の日本語で簡潔に読み解いてください。
                以下の観点を盛り込みます:
                  1. 人脈の偏り（業界・エリア・職種のうち目立つ傾向）
                  2. 直近の動向（月別推移から見える変化）
                  3. 次のアクション提案（どの層に再アプローチすべきか）
                出力は敬体（です・ます調）。番号付き箇条書き禁止。装飾記号禁止。
                """
            let session = LanguageModelSession(instructions: instructions)
            let options = GenerationOptions(temperature: 0.5)
            do {
                let response = try await session.respond(to: summary, options: options)
                let text = String(describing: response.content)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { throw NarrativeError.generationFailed }
                return text
            } catch {
                throw NarrativeError.generationFailed
            }
        }
        #endif
        throw NarrativeError.unavailable
    }

    /// LLM 入力用の集計サマリ（数値だけ・冗長な装飾なし）
    private func buildSummaryForLLM(_ insights: Insights) -> String {
        var lines: [String] = []
        lines.append("総名刺数: \(insights.totalCards)枚")
        if !insights.companyGroups.isEmpty {
            let top = insights.companyGroups.prefix(5)
                .map { "\($0.label)(\($0.count))" }.joined(separator: ", ")
            lines.append("会社別 上位: \(top)")
        }
        if !insights.areaGroups.isEmpty {
            let top = insights.areaGroups.prefix(5)
                .map { "\($0.label)(\($0.count))" }.joined(separator: ", ")
            lines.append("エリア別 上位: \(top)")
        }
        if !insights.roleCategoryGroups.isEmpty {
            let top = insights.roleCategoryGroups.prefix(5)
                .map { "\($0.label)(\($0.count))" }.joined(separator: ", ")
            lines.append("職種別 上位: \(top)")
        }
        if !insights.monthlyTrend.isEmpty {
            let recent = insights.monthlyTrend.prefix(6)
                .map { "\($0.label):\($0.count)" }.joined(separator: ", ")
            lines.append("月別推移（直近）: \(recent)")
        }
        return lines.joined(separator: "\n")
    }
}
