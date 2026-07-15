import Charts
import SwiftUI

/// 名刺データの集計とAI解釈を、単一ScrollView内の安定したセクションで表示する。
struct InsightsView: View {
    @State private var insights: InsightsService.Insights?
    @State private var narrative: String?
    @State private var isGeneratingNarrative = false
    @State private var narrativeError: String?
    @State private var isShowingPaywall = false

    @EnvironmentObject private var entitlementStore: EntitlementStore
    @EnvironmentObject private var navigationState: AppNavigationState
    @Environment(\.managedObjectContext) private var managedObjectContext

    var body: some View {
        ScrollView {
            if let insights {
                LazyVStack(spacing: AppTheme.Spacing.large) {
                    summarySection(insights)
                        .id("summary")

                    organizeSection(insights)
                        .id("organize")

                    if !insights.monthlyTrend.isEmpty {
                        monthlySection(insights)
                            .id("monthly-trend")
                    }

                    aiNarrativeCard(insights: insights)
                        .id("ai-narrative")

                    if !insights.companyGroups.isEmpty {
                        companySection(insights)
                            .id("companies")
                    }

                    if !insights.areaGroups.isEmpty {
                        areaSection(insights)
                            .id("areas")
                    }

                    if !insights.roleCategoryGroups.isEmpty {
                        roleSection(insights)
                            .id("role-categories")
                    }
                }
                .frame(maxWidth: AppTheme.contentMaximumWidth)
                .padding(.horizontal, AppTheme.Spacing.large)
                .padding(.vertical, AppTheme.Spacing.xLarge)
                .frame(maxWidth: .infinity)
            } else {
                ProgressView("集計中...")
                    .frame(maxWidth: .infinity)
                    .padding(.top, 80)
            }
        }
        .background(AppTheme.background.ignoresSafeArea())
        .accessibilityIdentifier("insightsScrollView")
        .navigationTitle("インサイト")
        .navigationBarTitleDisplayMode(.large)
        .task {
            guard insights == nil else { return }
            insights = InsightsService.shared.generateInsights(context: managedObjectContext)
        }
        .sheet(isPresented: $isShowingPaywall) {
            PaywallView(context: .insightsNarrative)
                .environmentObject(entitlementStore)
        }
    }

    private func summarySection(_ insights: InsightsService.Insights) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), spacing: AppTheme.Spacing.medium)], spacing: AppTheme.Spacing.medium) {
            MetricBlock(title: "総名刺数", value: "\(insights.totalCards)", detail: "枚")
            MetricBlock(title: "今月", value: "\(insights.currentMonthCount)", detail: "枚")
            MetricBlock(
                title: "前月差",
                value: insights.previousMonthDelta == 0
                    ? "±0"
                    : String(format: "%+d", insights.previousMonthDelta),
                detail: "前月 \(insights.previousMonthCount)枚"
            )
        }
    }

    private func organizeSection(_ insights: InsightsService.Insights) -> some View {
        insightCard(title: "次に整理する名刺") {
            Text("集計を見るだけでなく、整理が必要な名刺へ直接移動できます。")
                .font(.caption)
                .foregroundStyle(.secondary)

            organizeAction(
                title: "タグが付いていない",
                count: insights.untaggedCount,
                systemImage: "tag.slash",
                filter: .untagged
            )
            organizeAction(
                title: "電話・メールがない",
                count: insights.missingContactCount,
                systemImage: "person.crop.circle.badge.exclamationmark",
                filter: .missingContact
            )
            organizeAction(
                title: "30日以内に追加",
                count: insights.recentCount,
                systemImage: "clock",
                filter: .recent(days: 30)
            )
            organizeAction(
                title: "お気に入り",
                count: insights.favoriteCount,
                systemImage: "star",
                filter: .favorite
            )
        }
    }

    private func monthlySection(_ insights: InsightsService.Insights) -> some View {
        insightCard(title: "月別推移") {
            Chart(Array(insights.monthlyTrend.prefix(12).reversed())) { month in
                LineMark(
                    x: .value("年月", month.yearMonth),
                    y: .value("名刺数", month.count)
                )
                .foregroundStyle(AppTheme.monthlyBlue)
                .interpolationMethod(.catmullRom)
                PointMark(
                    x: .value("年月", month.yearMonth),
                    y: .value("名刺数", month.count)
                )
                .foregroundStyle(AppTheme.monthlyBlue)
            }
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 6)) { value in
                    AxisGridLine()
                    AxisValueLabel {
                        if let key = value.as(String.self) {
                            Text(key.dropFirst(5))
                        }
                    }
                }
            }
            .frame(height: 220)

            Divider()

            ForEach(Array(insights.monthlyTrend.prefix(6))) { month in
                destinationRow(
                    title: month.label,
                    countText: "\(month.count)枚を見る"
                ) {
                    navigationState.showCards(filteredBy: .month(month.yearMonth))
                }
            }
        }
    }

    private func companySection(_ insights: InsightsService.Insights) -> some View {
        let groups = Array(insights.companyGroups.prefix(8))
        return insightCard(title: "会社別") {
            Chart(groups) { group in
                BarMark(
                    x: .value("人数", group.count),
                    y: .value("会社", group.label)
                )
                .foregroundStyle(AppTheme.companyBlueGray)
                .cornerRadius(4)
            }
            .frame(height: CGFloat(max(180, groups.count * 34)))

            Divider()

            ForEach(Array(groups.prefix(5))) { group in
                destinationRow(title: group.label, countText: "\(group.count)人を見る") {
                    navigationState.showCards(filteredBy: .company(group.label))
                }
            }
        }
    }

    private func areaSection(_ insights: InsightsService.Insights) -> some View {
        insightCard(title: "エリア別") {
            ForEach(Array(insights.areaGroups.prefix(10))) { group in
                destinationRow(title: group.label, countText: "\(group.count)人を見る") {
                    navigationState.showCards(filteredBy: .area(group.label))
                }
            }
        }
    }

    private func roleSection(_ insights: InsightsService.Insights) -> some View {
        let groups = Array(insights.roleCategoryGroups.prefix(8))
        let domain = groups.map(\.label)
        let range = groups.indices.map { AppTheme.categoryColors[$0 % AppTheme.categoryColors.count] }
        return insightCard(title: "職種カテゴリ別") {
            Chart(groups) { group in
                BarMark(
                    x: .value("人数", group.count),
                    y: .value("職種", group.label)
                )
                .foregroundStyle(by: .value("職種", group.label))
                .cornerRadius(4)
            }
            .chartForegroundStyleScale(domain: domain, range: range)
            .chartLegend(.hidden)
            .frame(height: CGFloat(max(180, groups.count * 34)))

            Divider()

            ForEach(Array(groups.prefix(5))) { group in
                destinationRow(title: group.label, countText: "\(group.count)人を見る") {
                    navigationState.showCards(filteredBy: .role(group.label))
                }
            }
        }
    }

    private func organizeAction(
        title: String,
        count: Int,
        systemImage: String,
        filter: CardListExternalFilter
    ) -> some View {
        Button {
            navigationState.showCards(filteredBy: filter)
        } label: {
            HStack(spacing: AppTheme.Spacing.medium) {
                Image(systemName: systemImage)
                    .frame(width: 24)
                    .foregroundStyle(.secondary)
                Text(title)
                    .foregroundStyle(.primary)
                Spacer()
                Text("\(count)件を見る")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(count == 0)
        .accessibilityIdentifier("insightAction_\(systemImage)")
    }

    private func destinationRow(
        title: String,
        countText: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack {
                Text(title)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Spacer()
                Text(countText)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
            }
            .frame(minHeight: 40)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func aiNarrativeCard(insights: InsightsService.Insights) -> some View {
        insightCard(title: "AIで読み解く", accent: true) {
            if let narrative {
                Text(narrative)
                    .font(.subheadline)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button {
                    Task { await generateNarrative(insights: insights) }
                } label: {
                    Label("もう一度生成", systemImage: "arrow.clockwise")
                }
                .disabled(isGeneratingNarrative)
            } else if isGeneratingNarrative {
                HStack(spacing: AppTheme.Spacing.small) {
                    ProgressView()
                    Text("AIが読み解いています...")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            } else if let narrativeError {
                Text(narrativeError)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button {
                    Task { await generateNarrative(insights: insights) }
                } label: {
                    Label("再試行", systemImage: "arrow.clockwise")
                }
            } else {
                Button {
                    Task { await generateNarrative(insights: insights) }
                } label: {
                    HStack(spacing: AppTheme.Spacing.medium) {
                        Image(systemName: "sparkles")
                            .foregroundStyle(AppTheme.brandOrange)
                        VStack(alignment: .leading, spacing: AppTheme.Spacing.xSmall) {
                            Text("AIに集計を読み解いてもらう")
                                .font(.subheadline.bold())
                                .foregroundStyle(.primary)
                            Text(entitlementStore.hasAccess
                                 ? "次にアプローチすべき層をAIが提案します"
                                 : "eMeishi Proでご利用いただけます")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func generateNarrative(insights: InsightsService.Insights) async {
        guard entitlementStore.hasAccess else {
            isShowingPaywall = true
            return
        }
        guard !isGeneratingNarrative else { return }
        isGeneratingNarrative = true
        narrative = nil
        narrativeError = nil
        defer { isGeneratingNarrative = false }
        do {
            narrative = try await InsightsService.shared.generateNarrative(insights: insights)
        } catch InsightsService.NarrativeError.unavailable {
            narrativeError = "AI解釈はこの端末では利用できません。対応するAIモデルを設定してから再試行してください。"
        } catch {
            narrativeError = "AI解釈の生成に失敗しました。しばらくしてから再試行してください。"
        }
    }

    private func insightCard<Content: View>(
        title: String,
        accent: Bool = false,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.medium) {
            Text(title)
                .font(.headline)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(AppTheme.Spacing.large)
        .background(
            accent ? AppTheme.brandOrange.opacity(0.08) : AppTheme.contentSurface,
            in: .rect(cornerRadius: AppTheme.contentCornerRadius, style: .continuous)
        )
    }
}
