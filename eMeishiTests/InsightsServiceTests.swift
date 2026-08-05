import Testing
import CoreData
@testable import eMeishi

// MARK: - テスト用ヘルパー（InsightsServiceTests 専用）
// makeTestContext() は TestHelpers.swift の共有版を使用。
// makeCard は InsightsService 固有のパラメータ（createdAt 等）を持つため個別定義。

@MainActor
private func makeCard(
    context: NSManagedObjectContext,
    company: String? = nil,
    department: String? = nil,
    title: String? = nil,
    address: String? = nil,
    email: String? = nil,
    phone: String? = nil,
    isFavorite: Bool = false,
    createdAt: Date = Date()
) -> BusinessCard {
    let card = BusinessCard(context: context)
    card.id = UUID()
    card.lastName = "テスト"
    card.company = company
    card.department = department
    card.title = title
    card.address = address
    card.email = email
    card.phone = phone
    card.isFavorite = isFavorite
    card.createdAt = createdAt
    card.updatedAt = createdAt
    return card
}

// MARK: - 整理アクション

@MainActor
struct InsightsServiceActionCountTests {

    @Test func countsCardsThatNeedOrganization() async throws {
        let context = makeTestContext()
        let oldDate = try #require(Calendar.current.date(byAdding: .day, value: -60, to: Date()))

        let organized = makeCard(
            context: context,
            email: "known@example.com",
            phone: "03-1234-5678",
            isFavorite: true,
            createdAt: oldDate
        )
        let tag = eMeishi.Tag(context: context)
        tag.id = UUID()
        tag.name = "整理済み"
        organized.addToTags(tag)

        _ = makeCard(context: context, createdAt: Date())
        try context.save()

        let insights = try await InsightsService.shared.generateInsights(context: context)
        #expect(insights.untaggedCount == 1)
        #expect(insights.missingContactCount == 1)
        #expect(insights.recentCount == 1)
        #expect(insights.favoriteCount == 1)
    }
}

// MARK: - 総件数

@MainActor
struct InsightsServiceTotalTests {

    @Test func totalCountsAllCards() async throws {
        let context = makeTestContext()
        _ = makeCard(context: context)
        _ = makeCard(context: context)
        _ = makeCard(context: context)
        try context.save()

        let insights = try await InsightsService.shared.generateInsights(context: context)
        #expect(insights.totalCards == 3)
    }

    @Test func totalIsZeroWhenEmpty() async throws {
        let context = makeTestContext()
        let insights = try await InsightsService.shared.generateInsights(context: context)
        #expect(insights.totalCards == 0)
        #expect(insights.companyGroups.isEmpty)
        #expect(insights.areaGroups.isEmpty)
        #expect(insights.monthlyTrend.isEmpty)
    }
}

// MARK: - 会社別集計

@MainActor
struct InsightsServiceCompanyGroupTests {

    @Test func aggregatesByCompanyName() async throws {
        let context = makeTestContext()
        _ = makeCard(context: context, company: "アルファテック")
        _ = makeCard(context: context, company: "アルファテック")
        _ = makeCard(context: context, company: "ベータシステムズ")
        try context.save()

        let insights = try await InsightsService.shared.generateInsights(context: context)
        #expect(insights.companyGroups.count == 2)

        let alpha = insights.companyGroups.first { $0.label == "アルファテック" }
        #expect(alpha?.count == 2)

        let beta = insights.companyGroups.first { $0.label == "ベータシステムズ" }
        #expect(beta?.count == 1)
    }

    @Test func companyGroupsAreSortedByCountDescending() async throws {
        let context = makeTestContext()
        _ = makeCard(context: context, company: "少")
        _ = makeCard(context: context, company: "多")
        _ = makeCard(context: context, company: "多")
        _ = makeCard(context: context, company: "多")
        _ = makeCard(context: context, company: "中")
        _ = makeCard(context: context, company: "中")
        try context.save()

        let insights = try await InsightsService.shared.generateInsights(context: context)
        #expect(insights.companyGroups.map(\.count) == [3, 2, 1])
        #expect(insights.companyGroups.map(\.label) == ["多", "中", "少"])
    }

    @Test func blankCompaniesAreExcluded() async throws {
        let context = makeTestContext()
        _ = makeCard(context: context, company: nil)
        _ = makeCard(context: context, company: "")
        _ = makeCard(context: context, company: "   ")
        _ = makeCard(context: context, company: "アルファ")
        try context.save()

        let insights = try await InsightsService.shared.generateInsights(context: context)
        #expect(insights.companyGroups.count == 1)
        #expect(insights.companyGroups.first?.label == "アルファ")
    }
}

// MARK: - エリア別集計

@MainActor
struct InsightsServiceAreaGroupTests {

    @Test func extractsTokyoWard() async throws {
        let context = makeTestContext()
        _ = makeCard(context: context, address: "東京都渋谷区道玄坂1-2-3")
        _ = makeCard(context: context, address: "東京都新宿区西新宿6-7-8")
        try context.save()

        let insights = try await InsightsService.shared.generateInsights(context: context)
        let labels = Set(insights.areaGroups.map(\.label))
        #expect(labels.contains("東京都渋谷区"))
        #expect(labels.contains("東京都新宿区"))
    }

    @Test func extractsPrefectureCity() async throws {
        let context = makeTestContext()
        _ = makeCard(context: context, address: "神奈川県横浜市西区みなとみらい2-3")
        _ = makeCard(context: context, address: "北海道札幌市中央区大通西1-2")
        try context.save()

        let insights = try await InsightsService.shared.generateInsights(context: context)
        let labels = Set(insights.areaGroups.map(\.label))
        #expect(labels.contains("神奈川県横浜市"))
        #expect(labels.contains("北海道札幌市"))
    }

    @Test func emptyAddressIsSkipped() async throws {
        let context = makeTestContext()
        _ = makeCard(context: context, address: nil)
        _ = makeCard(context: context, address: "")
        _ = makeCard(context: context, address: "東京都渋谷区1-1")
        try context.save()

        let insights = try await InsightsService.shared.generateInsights(context: context)
        #expect(insights.areaGroups.count == 1)
    }
}

// MARK: - 職種カテゴリ別集計

@MainActor
struct InsightsServiceRoleCategoryTests {

    @Test func engineerCategoryCaptured() async throws {
        let context = makeTestContext()
        _ = makeCard(context: context, department: "開発部", title: "エンジニア")
        _ = makeCard(context: context, department: nil, title: "シニアエンジニア")
        try context.save()

        let insights = try await InsightsService.shared.generateInsights(context: context)
        let engineer = insights.roleCategoryGroups.first { $0.label == "エンジニア・技術" }
        #expect(engineer?.count == 2)
    }

    @Test func executiveCategoryCaptured() async throws {
        let context = makeTestContext()
        _ = makeCard(context: context, title: "代表取締役社長")
        _ = makeCard(context: context, title: "CEO")
        try context.save()

        let insights = try await InsightsService.shared.generateInsights(context: context)
        let exec = insights.roleCategoryGroups.first { $0.label == "経営・役員" }
        #expect(exec?.count == 2)
    }

    @Test func unknownCategoryFallsThroughToOther() async throws {
        let context = makeTestContext()
        _ = makeCard(context: context, department: "戦略研究室", title: "シニアフェロー")
        try context.save()

        let insights = try await InsightsService.shared.generateInsights(context: context)
        // "戦略" が含まれるので企画・戦略カテゴリに入るはず
        let planning = insights.roleCategoryGroups.first { $0.label == "企画・戦略" }
        #expect(planning?.count == 1)
    }

    @Test func emptyRoleIsUnclassified() async throws {
        let context = makeTestContext()
        _ = makeCard(context: context, department: nil, title: nil)
        _ = makeCard(context: context, department: "", title: "")
        try context.save()

        let insights = try await InsightsService.shared.generateInsights(context: context)
        let unclassified = insights.roleCategoryGroups.first { $0.label == "未分類" }
        #expect(unclassified?.count == 2)
    }
}

// MARK: - 月別推移

@MainActor
struct InsightsServiceMonthlyTrendTests {

    @Test func groupsByYearMonth() async throws {
        let context = makeTestContext()
        let cal = Calendar(identifier: .gregorian)

        let jan = try #require(cal.date(from: DateComponents(year: 2026, month: 1, day: 15)))
        let feb = try #require(cal.date(from: DateComponents(year: 2026, month: 2, day: 3)))

        _ = makeCard(context: context, createdAt: jan)
        _ = makeCard(context: context, createdAt: jan)
        _ = makeCard(context: context, createdAt: feb)
        try context.save()

        let insights = try await InsightsService.shared.generateInsights(context: context)
        let janEntry = insights.monthlyTrend.first { $0.yearMonth == "2026-01" }
        let febEntry = insights.monthlyTrend.first { $0.yearMonth == "2026-02" }
        #expect(janEntry?.count == 2)
        #expect(febEntry?.count == 1)
    }

    @Test func sortedByYearMonthDescending() async throws {
        let context = makeTestContext()
        let cal = Calendar(identifier: .gregorian)
        let jan = try #require(cal.date(from: DateComponents(year: 2026, month: 1, day: 1)))
        let dec = try #require(cal.date(from: DateComponents(year: 2025, month: 12, day: 1)))
        let feb = try #require(cal.date(from: DateComponents(year: 2026, month: 2, day: 1)))

        _ = makeCard(context: context, createdAt: jan)
        _ = makeCard(context: context, createdAt: dec)
        _ = makeCard(context: context, createdAt: feb)
        try context.save()

        let insights = try await InsightsService.shared.generateInsights(context: context)
        #expect(insights.monthlyTrend.map(\.yearMonth) == ["2026-02", "2026-01", "2025-12"])
    }

    @Test func cardsWithoutCreatedAtAreSkipped() async throws {
        let context = makeTestContext()
        let card = makeCard(context: context)
        card.createdAt = nil
        _ = makeCard(context: context, createdAt: Date())
        try context.save()

        let insights = try await InsightsService.shared.generateInsights(context: context)
        let totalMonthly = insights.monthlyTrend.reduce(0) { $0 + $1.count }
        #expect(totalMonthly == 1)
    }

    @Test func identifiersAreStableForSameDimensions() async throws {
        let context = makeTestContext()
        _ = makeCard(context: context, company: "アルファ", createdAt: Date())
        try context.save()

        let first = try await InsightsService.shared.generateInsights(context: context)
        let second = try await InsightsService.shared.generateInsights(context: context)

        #expect(first.companyGroups.first?.id == second.companyGroups.first?.id)
        #expect(first.monthlyTrend.first?.id == second.monthlyTrend.first?.id)
        #expect(first.monthlyTrend.first?.id == first.monthlyTrend.first?.yearMonth)
    }

    @Test func currentMonthAndPreviousMonthDeltaAreCalculated() async throws {
        let context = makeTestContext()
        let calendar = Calendar.current
        let now = Date()
        let previous = try #require(calendar.date(byAdding: .month, value: -1, to: now))

        _ = makeCard(context: context, createdAt: now)
        _ = makeCard(context: context, createdAt: now)
        _ = makeCard(context: context, createdAt: previous)
        try context.save()

        let insights = try await InsightsService.shared.generateInsights(context: context)
        #expect(insights.currentMonthCount == 2)
        #expect(insights.previousMonthCount == 1)
        #expect(insights.previousMonthDelta == 1)
    }
}

// MARK: - 並行集計・世代管理

struct InsightsAggregationConcurrencyTests {
    @Test func sendableSnapshotMatchesExternalFiltersWithoutManagedObjects() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
        let now = try #require(calendar.date(from: DateComponents(
            year: 2026,
            month: 7,
            day: 15
        )))
        let snapshot = InsightsCardSnapshot(
            company: "Example Alpha",
            department: "開発部",
            title: "エンジニア",
            address: "東京都例示区1-1",
            createdAt: now,
            hasEmail: true,
            hasPhone: false,
            hasTags: false,
            isFavorite: true
        )

        #expect(InsightsAggregationRules.matches(
            snapshot,
            filter: .area("東京都例示区"),
            now: now,
            calendar: calendar
        ))
        #expect(InsightsAggregationRules.matches(
            snapshot,
            filter: .role("エンジニア・技術"),
            now: now,
            calendar: calendar
        ))
        #expect(InsightsAggregationRules.matches(
            snapshot,
            filter: .untagged,
            now: now,
            calendar: calendar
        ))
        #expect(!InsightsAggregationRules.matches(
            snapshot,
            filter: .missingContact,
            now: now,
            calendar: calendar
        ))
    }

    @Test func workerAggregatesSendableSnapshots() async throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
        let now = try #require(calendar.date(from: DateComponents(
            year: 2026,
            month: 7,
            day: 15
        )))
        let previousMonth = try #require(calendar.date(byAdding: .month, value: -1, to: now))
        let snapshots = [
            InsightsCardSnapshot(
                company: "Example Alpha",
                department: "開発部",
                title: "エンジニア",
                address: "東京都例示区1-1",
                createdAt: now,
                hasEmail: true,
                hasPhone: false,
                hasTags: true,
                isFavorite: true
            ),
            InsightsCardSnapshot(
                company: "Example Alpha",
                department: "営業部",
                title: "営業",
                address: "東京都例示区2-2",
                createdAt: previousMonth,
                hasEmail: false,
                hasPhone: false,
                hasTags: false,
                isFavorite: false
            ),
        ]

        let insights = try await InsightsAggregationWorker().generate(
            snapshots: snapshots,
            now: now,
            calendar: calendar
        )

        #expect(insights.totalCards == 2)
        #expect(insights.companyGroups.first?.count == 2)
        #expect(insights.currentMonthCount == 1)
        #expect(insights.previousMonthCount == 1)
        #expect(insights.untaggedCount == 1)
        #expect(insights.missingContactCount == 1)
        #expect(insights.favoriteCount == 1)
    }

    @Test func generationGateAcceptsOnlyLatestRequest() {
        var gate = InsightsGenerationGate()
        let first = gate.begin()
        let second = gate.begin()

        #expect(!gate.accepts(first))
        #expect(gate.accepts(second))

        gate.cancel()
        #expect(!gate.accepts(second))
    }
}

@MainActor
struct InsightsSnapshotLoaderTests {
    @Test func loaderBuildsSnapshotsIncludingPrefetchedTags() async throws {
        let context = makeTestContext()
        let taggedCard = makeCard(
            context: context,
            company: "例示株式会社",
            email: "sample@example.com"
        )
        let tag = eMeishi.Tag(context: context)
        tag.id = UUID()
        tag.name = "架空タグ"
        taggedCard.addToTags(tag)
        _ = makeCard(context: context, company: "架空合同会社")
        try context.save()

        let coordinator = try #require(context.persistentStoreCoordinator)
        let snapshots = try await InsightsSnapshotLoader().load(
            coordinatorReference: PersistentStoreCoordinatorReference(coordinator: coordinator)
        )

        #expect(snapshots.count == 2)
        let taggedSnapshot = try #require(snapshots.first { $0.company == "例示株式会社" })
        #expect(taggedSnapshot.hasTags)
        #expect(taggedSnapshot.hasEmail)
        let untaggedSnapshot = try #require(snapshots.first { $0.company == "架空合同会社" })
        #expect(!untaggedSnapshot.hasTags)
    }

    @Test func servicePropagatesCancellationError() async throws {
        let context = makeTestContext()

        let task = Task {
            withUnsafeCurrentTask { currentTask in
                currentTask?.cancel()
            }
            return try await InsightsService.shared.generateInsights(context: context)
        }

        do {
            _ = try await task.value
            Issue.record("キャンセル済み集計が成功として完了しました")
        } catch is CancellationError {
            // 期待どおり、空配列へ変換せず呼出し元へ伝播する。
        } catch {
            Issue.record("CancellationError以外が返されました: \(error)")
        }
    }
}
