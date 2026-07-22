import Charts
import CoreData
import SwiftUI

/// 名刺データの集計とAI解釈を、単一ScrollView内の安定したセクションで表示する。
struct InsightsView: View {
    @State private var insights: InsightsService.Insights?
    @State private var insightsError: String?
    @State private var insightsReloadRequestID = UUID()
    @State private var narrative: String?
    @State private var isGeneratingNarrative = false
    @State private var narrativeError: String?
    @State private var isShowingPaywall = false
    @State private var narrativeTask: Task<Void, Never>?
    @State private var narrativeGenerationID: UUID?
    @State private var insightsGenerationGate = InsightsGenerationGate()
    @State private var selectedMonthKey: String?
    @State private var loadedCardRevision: Int?

    @EnvironmentObject private var entitlementStore: EntitlementStore
    @EnvironmentObject private var navigationState: AppNavigationState
    @EnvironmentObject private var cardListViewModel: CardListViewModel
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
            } else if let insightsError {
                InlineErrorView(message: insightsError) {
                    insightsReloadRequestID = UUID()
                }
                .frame(maxWidth: AppTheme.contentMaximumWidth)
                .padding(.horizontal, AppTheme.Spacing.large)
                .padding(.top, AppTheme.Spacing.xLarge)
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
        .task(id: InsightsReloadRequest(
            cardRevision: cardListViewModel.cardsContentRevision,
            requestID: insightsReloadRequestID
        )) {
            await reloadInsights(for: cardListViewModel.cardsContentRevision)
        }
        .onDisappear {
            insightsGenerationGate.cancel()
            cancelNarrativeGeneration()
        }
        .sheet(isPresented: $isShowingPaywall) {
            PaywallView(context: .insightsNarrative)
                .environmentObject(entitlementStore)
        }
    }

    private func reloadInsights(for revision: Int) async {
        guard loadedCardRevision != revision else { return }
        cancelNarrativeGeneration()
        let generationID = insightsGenerationGate.begin()
        insightsError = nil
        do {
            let generated = try await InsightsService.shared.generateInsights(context: managedObjectContext)
            guard !Task.isCancelled,
                  insightsGenerationGate.accepts(generationID),
                  revision == cardListViewModel.cardsContentRevision else { return }

            insights = generated
            narrative = nil
            narrativeError = nil
            loadedCardRevision = revision
        } catch is CancellationError {
            return
        } catch {
            guard insightsGenerationGate.accepts(generationID),
                  revision == cardListViewModel.cardsContentRevision else { return }
            insights = nil
            insightsError = "集計データを読み込めませんでした。"
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
        ContentSection("次に整理する名刺") {
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
        let months = Array(insights.monthlyTrend.prefix(12).reversed())
        let selectedMonth = months.first { $0.yearMonth == selectedMonthKey }
        return ContentSection("月別推移") {
            Text(monthlySummary(insights))
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Chart(months) { month in
                LineMark(
                    x: .value("年月", month.yearMonth),
                    y: .value("名刺数", month.count)
                )
                .foregroundStyle(AppTheme.monthlyBlue)
                .interpolationMethod(.linear)
                PointMark(
                    x: .value("年月", month.yearMonth),
                    y: .value("名刺数", month.count)
                )
                .foregroundStyle(AppTheme.monthlyBlue)

                if selectedMonthKey == month.yearMonth {
                    RuleMark(x: .value("選択月", month.yearMonth))
                        .foregroundStyle(.secondary.opacity(0.55))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                        .annotation(position: .top, overflowResolution: .init(x: .fit, y: .disabled)) {
                            Text("\(month.count)枚")
                                .font(.caption.weight(.semibold))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 5)
                                .background(AppTheme.auxiliarySurface, in: .capsule)
                        }
                }
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
            .chartXSelection(value: $selectedMonthKey)
            .frame(height: 220)
            .accessibilityLabel("月別の名刺登録数")
            .sensoryFeedback(.selection, trigger: selectedMonthKey)

            if let selectedMonth {
                Divider()
                HStack(spacing: AppTheme.Spacing.medium) {
                    VStack(alignment: .leading, spacing: AppTheme.Spacing.xSmall) {
                        Text(selectedMonth.label)
                            .font(.subheadline.weight(.semibold))
                        Text("選択した月の名刺")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button {
                        navigationState.showCards(filteredBy: .month(selectedMonth.yearMonth))
                    } label: {
                        HStack(spacing: 3) {
                            Text("\(selectedMonth.count)枚")
                                .foregroundStyle(AppTheme.brandOrange)
                            Text("を見る")
                                .foregroundStyle(.primary)
                        }
                        .font(.subheadline.weight(.semibold))
                    }
                    .buttonStyle(.plain)
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    private func monthlySummary(_ insights: InsightsService.Insights) -> String {
        if insights.previousMonthDelta == 0 {
            return "今月は\(insights.currentMonthCount)枚。前月と同じ件数です。"
        }
        let comparison = insights.previousMonthDelta > 0 ? "多い" : "少ない"
        return "今月は\(insights.currentMonthCount)枚。前月より\(abs(insights.previousMonthDelta))枚\(comparison)です。"
    }

    private func companySection(_ insights: InsightsService.Insights) -> some View {
        let groups = Array(insights.companyGroups.prefix(8))
        return ContentSection("会社別") {
            Chart(groups) { group in
                BarMark(
                    x: .value("人数", group.count),
                    y: .value("会社", group.label)
                )
                .foregroundStyle(AppTheme.companyBlueGray)
                .cornerRadius(4)
            }
            .frame(height: CGFloat(max(180, groups.count * 34)))
            .accessibilityLabel("会社別の名刺数")

            Divider()

            ForEach(Array(groups.prefix(5))) { group in
                destinationRow(
                    title: group.label,
                    countText: "\(group.count)人",
                    countColor: AppTheme.brandOrange
                ) {
                    navigationState.showCards(filteredBy: .company(group.label))
                }
            }
        }
    }

    private func areaSection(_ insights: InsightsService.Insights) -> some View {
        ContentSection("エリア別") {
            ForEach(Array(insights.areaGroups.prefix(10))) { group in
                destinationRow(
                    title: group.label,
                    countText: "\(group.count)人",
                    countColor: AppTheme.brandOrange
                ) {
                    navigationState.showCards(filteredBy: .area(group.label))
                }
            }
        }
    }

    private func roleSection(_ insights: InsightsService.Insights) -> some View {
        let groups = Array(insights.roleCategoryGroups.prefix(8))
        let domain = groups.map(\.label)
        let range = groups.indices.map { AppTheme.categoryColors[$0 % AppTheme.categoryColors.count] }
        return ContentSection("職種カテゴリ別") {
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
            .accessibilityLabel("職種カテゴリ別の名刺数")

            Divider()

            ForEach(Array(groups.prefix(5))) { group in
                destinationRow(
                    title: group.label,
                    countText: "\(group.count)人",
                    countColor: AppTheme.brandOrange
                ) {
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
        .buttonStyle(InsightDestinationButtonStyle())
        .disabled(count == 0)
        .accessibilityIdentifier("insightAction_\(systemImage)")
    }

    private func destinationRow(
        title: String,
        countText: String,
        countColor: Color = .secondary,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack {
                Text(title)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Spacer()
                HStack(spacing: 3) {
                    Text(countText)
                        .foregroundStyle(countColor)
                    Text("を見る")
                        .foregroundStyle(.primary)
                }
                .font(.subheadline.weight(.medium))
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(InsightDestinationButtonStyle())
    }

    @ViewBuilder
    private func aiNarrativeCard(insights: InsightsService.Insights) -> some View {
        ContentSection("AIで読み解く", style: .accent) {
            if let narrative {
                Text(narrative)
                    .font(.subheadline)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button {
                    startNarrativeGeneration(insights: insights)
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
                    startNarrativeGeneration(insights: insights)
                } label: {
                    Label("再試行", systemImage: "arrow.clockwise")
                }
            } else {
                Button {
                    startNarrativeGeneration(insights: insights)
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

    private func startNarrativeGeneration(insights: InsightsService.Insights) {
        guard entitlementStore.hasAccess else {
            isShowingPaywall = true
            return
        }

        narrativeTask?.cancel()
        let generationID = UUID()
        let revision = cardListViewModel.cardsContentRevision
        narrativeGenerationID = generationID
        narrativeTask = Task {
            await generateNarrative(
                insights: insights,
                generationID: generationID,
                revision: revision
            )
        }
    }

    private func generateNarrative(
        insights: InsightsService.Insights,
        generationID: UUID,
        revision: Int
    ) async {
        isGeneratingNarrative = true
        narrative = nil
        narrativeError = nil
        defer {
            if narrativeGenerationID == generationID {
                isGeneratingNarrative = false
                narrativeTask = nil
            }
        }
        do {
            let generated = try await InsightsService.shared.generateNarrative(insights: insights)
            guard !Task.isCancelled,
                  narrativeGenerationID == generationID,
                  revision == cardListViewModel.cardsContentRevision else { return }
            narrative = generated
        } catch is CancellationError {
            return
        } catch InsightsService.NarrativeError.unavailable {
            guard narrativeGenerationID == generationID,
                  revision == cardListViewModel.cardsContentRevision else { return }
            narrativeError = "AI解釈はこの端末では利用できません。対応するAIモデルを設定してから再試行してください。"
        } catch {
            guard !Task.isCancelled,
                  narrativeGenerationID == generationID,
                  revision == cardListViewModel.cardsContentRevision else { return }
            narrativeError = "AI解釈の生成に失敗しました。しばらくしてから再試行してください。"
        }
    }

    private func cancelNarrativeGeneration() {
        narrativeTask?.cancel()
        narrativeTask = nil
        narrativeGenerationID = nil
        isGeneratingNarrative = false
    }

}

private struct InsightsReloadRequest: Hashable {
    let cardRevision: Int
    let requestID: UUID
}

private struct InsightDestinationButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(AppTheme.auxiliarySurface)
                    .padding(.horizontal, -AppTheme.Spacing.small)
                    .opacity(configuration.isPressed ? 1 : 0)
            }
            .opacity(configuration.isPressed ? 0.82 : 1)
            .animation(
                reduceMotion ? nil : .easeOut(duration: 0.12),
                value: configuration.isPressed
            )
    }
}
