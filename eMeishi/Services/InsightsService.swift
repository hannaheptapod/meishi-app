import Foundation
import CoreData
import os
#if canImport(FoundationModels)
import FoundationModels
#endif

/// CoreData の管理オブジェクトを actor 境界の外へ持ち出さないための不変スナップショット。
nonisolated struct InsightsCardSnapshot: Equatable, Sendable {
    let company: String
    let department: String
    let title: String
    let address: String
    let createdAt: Date?
    let hasEmail: Bool
    let hasPhone: Bool
    let hasTags: Bool
    let isFavorite: Bool
}

/// 永続ストアから集計入力を読み出す処理を MainActor から分離する。
/// タグrelationshipも同じprivate queue内で評価し、管理オブジェクトはactor外へ返さない。
actor InsightsSnapshotLoader {
    func load(
        coordinatorReference: PersistentStoreCoordinatorReference
    ) async throws -> [InsightsCardSnapshot] {
        try Task.checkCancellation()

        let context = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
        context.persistentStoreCoordinator = coordinatorReference.coordinator
        context.undoManager = nil

        let snapshots: [InsightsCardSnapshot] = try await context.perform {
            try Task.checkCancellation()

            // CoreData生成型はtargetのdefault isolationによりMainActor推論されるため、
            // private contextではNSManagedObjectとして読み、値をこのqueue内で完結させる。
            let request = NSFetchRequest<NSManagedObject>(entityName: "BusinessCard")
            request.fetchBatchSize = 100
            request.relationshipKeyPathsForPrefetching = ["tags"]
            let cards = try context.fetch(request)

            var result: [InsightsCardSnapshot] = []
            result.reserveCapacity(cards.count)
            for (index, card) in cards.enumerated() {
                if index.isMultiple(of: 64) {
                    try Task.checkCancellation()
                }
                result.append(
                    InsightsCardSnapshot(
                        company: card.value(forKey: "company") as? String ?? "",
                        department: card.value(forKey: "department") as? String ?? "",
                        title: card.value(forKey: "title") as? String ?? "",
                        address: card.value(forKey: "address") as? String ?? "",
                        createdAt: card.value(forKey: "createdAt") as? Date,
                        hasEmail: !((card.value(forKey: "email") as? String)?
                            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true),
                        hasPhone: !((card.value(forKey: "phone") as? String)?
                            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true),
                        hasTags: ((card.value(forKey: "tags") as? NSSet)?.count ?? 0) > 0,
                        isFavorite: card.value(forKey: "isFavorite") as? Bool ?? false
                    )
                )
            }
            return result
        }

        try Task.checkCancellation()
        return snapshots
    }
}

/// 非同期集計のうち、最後に開始した要求だけを画面へ反映するための世代管理。
nonisolated struct InsightsGenerationGate: Equatable, Sendable {
    private(set) var currentID: UUID?

    mutating func begin() -> UUID {
        let id = UUID()
        currentID = id
        return id
    }

    func accepts(_ id: UUID) -> Bool {
        currentID == id
    }

    mutating func cancel() {
        currentID = nil
    }
}

/// 集計と一覧フィルターで共通利用する、副作用のない分類規則。
nonisolated enum InsightsAggregationRules {
    /// 住所フィルターとインサイト集計のたびに正規表現を再生成しない。
    /// `NSRegularExpression` は生成コストが高いため、不変インスタンスを全要求で共有する。
    private static let prefectureRegex = try? NSRegularExpression(
        pattern: "(北海道|東京都|(?:大阪|京都)府|.{2,3}県)"
    )
    private static let municipalityRegexes = ["^.{1,5}市", "^.{1,5}区", "^.{1,5}[町村]"]
        .compactMap { try? NSRegularExpression(pattern: $0) }

    static func area(from address: String) -> String {
        guard let prefectureRegex,
              let prefMatch = prefectureRegex.firstMatch(
                in: address,
                range: NSRange(address.startIndex..., in: address)
              ),
              let prefRange = Range(prefMatch.range(at: 1), in: address) else {
            return ""
        }

        let prefecture = String(address[prefRange])
        let rest = String(address[prefRange.upperBound...])
        for regex in municipalityRegexes {
            guard let match = regex.firstMatch(
                    in: rest,
                    range: NSRange(rest.startIndex..., in: rest)
                  ),
                  let range = Range(match.range, in: rest) else {
                continue
            }
            return prefecture + String(rest[range])
        }
        return prefecture
    }

    static func roleCategory(title: String, department: String) -> String {
        let combined = (title + " " + department).lowercased()
        if combined.trimmingCharacters(in: .whitespaces).isEmpty {
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

    static func yearMonth(for date: Date, calendar: Calendar) -> String {
        let components = calendar.dateComponents([.year, .month], from: date)
        return String(format: "%04d-%02d", components.year ?? 0, components.month ?? 0)
    }

    static func monthLabel(for date: Date, calendar: Calendar) -> String {
        let components = calendar.dateComponents([.year, .month], from: date)
        return "\(components.year ?? 0)年\(components.month ?? 0)月"
    }

    /// CoreData オブジェクトを actor 境界へ渡さずに一覧とインサイトで同一条件を使う。
    static func matches(
        _ snapshot: InsightsCardSnapshot,
        filter: CardListExternalFilter,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> Bool {
        switch filter {
        case .company(let company):
            return snapshot.company.localizedCaseInsensitiveCompare(company) == .orderedSame
        case .area(let area):
            return self.area(from: snapshot.address) == area
        case .role(let role):
            return roleCategory(title: snapshot.title, department: snapshot.department) == role
        case .month(let yearMonth):
            guard let createdAt = snapshot.createdAt else { return false }
            return self.yearMonth(for: createdAt, calendar: calendar) == yearMonth
        case .untagged:
            return !snapshot.hasTags
        case .missingContact:
            return !snapshot.hasPhone && !snapshot.hasEmail
        case .recent(let days):
            guard let createdAt = snapshot.createdAt,
                  let cutoff = calendar.date(byAdding: .day, value: -days, to: now) else {
                return false
            }
            return createdAt >= cutoff
        case .favorite:
            return snapshot.isFavorite
        }
    }
}

/// Regex・ソート・複数回の走査を MainActor から分離して直列化する集計ワーカー。
actor InsightsAggregationWorker {
    func generate(
        snapshots: [InsightsCardSnapshot],
        now: Date,
        calendar: Calendar = .current
    ) throws -> InsightsService.Insights {
        try Task.checkCancellation()
        var insights = InsightsService.Insights()
        insights.totalCards = snapshots.count
        insights.companyGroups = try groupByCompany(snapshots)
        insights.areaGroups = try groupByArea(snapshots)
        insights.roleCategoryGroups = try groupByRoleCategory(snapshots)
        insights.monthlyTrend = try groupByMonth(snapshots, calendar: calendar)
        let recentCutoff = calendar.date(byAdding: .day, value: -30, to: now) ?? .distantPast
        for (index, snapshot) in snapshots.enumerated() {
            if index.isMultiple(of: 128) {
                try Task.checkCancellation()
            }
            if !snapshot.hasTags { insights.untaggedCount += 1 }
            if !snapshot.hasPhone && !snapshot.hasEmail { insights.missingContactCount += 1 }
            if (snapshot.createdAt ?? .distantPast) >= recentCutoff { insights.recentCount += 1 }
            if snapshot.isFavorite { insights.favoriteCount += 1 }
        }

        let currentMonth = InsightsAggregationRules.yearMonth(for: now, calendar: calendar)
        let previousDate = calendar.date(byAdding: .month, value: -1, to: now) ?? now
        let previousMonth = InsightsAggregationRules.yearMonth(for: previousDate, calendar: calendar)
        insights.currentMonthCount = insights.monthlyTrend.first {
            $0.yearMonth == currentMonth
        }?.count ?? 0
        insights.previousMonthCount = insights.monthlyTrend.first {
            $0.yearMonth == previousMonth
        }?.count ?? 0
        try Task.checkCancellation()
        return insights
    }

    private func groupByCompany(_ snapshots: [InsightsCardSnapshot]) throws -> [InsightsService.GroupCount] {
        var counts: [String: Int] = [:]
        for (index, snapshot) in snapshots.enumerated() {
            if index.isMultiple(of: 128) {
                try Task.checkCancellation()
            }
            let company = snapshot.company.trimmingCharacters(in: .whitespaces)
            guard !company.isEmpty else { continue }
            counts[company, default: 0] += 1
        }
        return counts.map { InsightsService.GroupCount(label: $0.key, count: $0.value) }
            .sorted { lhs, rhs in
                lhs.count == rhs.count ? lhs.label < rhs.label : lhs.count > rhs.count
            }
    }

    private func groupByArea(_ snapshots: [InsightsCardSnapshot]) throws -> [InsightsService.GroupCount] {
        var counts: [String: Int] = [:]
        for (index, snapshot) in snapshots.enumerated() {
            if index.isMultiple(of: 128) {
                try Task.checkCancellation()
            }
            let area = InsightsAggregationRules.area(from: snapshot.address)
            guard !area.isEmpty else { continue }
            counts[area, default: 0] += 1
        }
        return counts.map { InsightsService.GroupCount(label: $0.key, count: $0.value) }
            .sorted { lhs, rhs in
                lhs.count == rhs.count ? lhs.label < rhs.label : lhs.count > rhs.count
            }
    }

    private func groupByRoleCategory(_ snapshots: [InsightsCardSnapshot]) throws -> [InsightsService.GroupCount] {
        var counts: [String: Int] = [:]
        for (index, snapshot) in snapshots.enumerated() {
            if index.isMultiple(of: 128) {
                try Task.checkCancellation()
            }
            let category = InsightsAggregationRules.roleCategory(
                title: snapshot.title,
                department: snapshot.department
            )
            counts[category, default: 0] += 1
        }
        return counts.map { InsightsService.GroupCount(label: $0.key, count: $0.value) }
            .sorted { lhs, rhs in
                lhs.count == rhs.count ? lhs.label < rhs.label : lhs.count > rhs.count
            }
    }

    private func groupByMonth(
        _ snapshots: [InsightsCardSnapshot],
        calendar: Calendar
    ) throws -> [InsightsService.MonthCount] {
        var counts: [String: (display: String, count: Int)] = [:]
        for (index, snapshot) in snapshots.enumerated() {
            if index.isMultiple(of: 128) {
                try Task.checkCancellation()
            }
            guard let date = snapshot.createdAt else { continue }
            let key = InsightsAggregationRules.yearMonth(for: date, calendar: calendar)
            let display = InsightsAggregationRules.monthLabel(for: date, calendar: calendar)
            counts[key, default: (display, 0)].count += 1
        }
        return counts.map {
            InsightsService.MonthCount(
                label: $0.value.display,
                yearMonth: $0.key,
                count: $0.value.count
            )
        }
        .sorted { $0.yearMonth > $1.yearMonth }
    }
}

// 人脈インサイトサービス
// private contextで名刺を値型へ変換し、会社別・エリア別・職種別の統計を返す
// 集計部分は LLM 不使用、AI ナラティブ生成は Foundation Models（iOS 26+）を使用
@MainActor
class InsightsService {

    static let shared = InsightsService()
    private let snapshotLoader = InsightsSnapshotLoader()
    private let aggregationWorker = InsightsAggregationWorker()

    // MARK: - データ構造

    nonisolated struct Insights: Equatable, Sendable {
        var companyGroups: [GroupCount] = []
        var areaGroups: [GroupCount] = []
        var roleCategoryGroups: [GroupCount] = []
        var monthlyTrend: [MonthCount] = []
        var totalCards: Int = 0
        var currentMonthCount: Int = 0
        var previousMonthCount: Int = 0
        var untaggedCount: Int = 0
        var missingContactCount: Int = 0
        var recentCount: Int = 0
        var favoriteCount: Int = 0

        var previousMonthDelta: Int {
            currentMonthCount - previousMonthCount
        }
    }

    nonisolated struct GroupCount: Identifiable, Equatable, Sendable {
        let label: String
        let count: Int
        var id: String { label }
    }

    nonisolated struct MonthCount: Identifiable, Equatable, Sendable {
        let label: String
        let yearMonth: String
        let count: Int
        var id: String { yearMonth }
    }

    // MARK: - 公開API

    func generateInsights(
        context: NSManagedObjectContext? = nil,
        now: Date = Date()
    ) async throws -> Insights {
        let context = context ?? PersistenceController.shared.container.viewContext
        guard let coordinator = context.persistentStoreCoordinator else {
            throw CocoaError(.persistentStoreOperation)
        }
        let snapshots = try await snapshotLoader.load(
            coordinatorReference: PersistentStoreCoordinatorReference(coordinator: coordinator)
        )
        try Task.checkCancellation()
        return try await aggregationWorker.generate(snapshots: snapshots, now: now)
    }

    func matches(_ card: BusinessCard, filter: CardListExternalFilter) -> Bool {
        let snapshot = InsightsCardSnapshot(
            company: card.company ?? "",
            department: card.department ?? "",
            title: card.title ?? "",
            address: card.address ?? "",
            createdAt: card.createdAt,
            hasEmail: !(card.email?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true),
            hasPhone: !card.phoneList.isEmpty,
            hasTags: !card.tagArray.isEmpty,
            isFavorite: card.isFavorite
        )
        return InsightsAggregationRules.matches(snapshot, filter: filter)
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
