import SwiftUI

/// 名刺データの集計とAI解釈を、単一ScrollView内の安定したセクションで表示する。
struct InsightsView: View {
    @State private var insights: InsightsService.Insights?
    @State private var narrative: String?
    @State private var isGeneratingNarrative = false
    @State private var narrativeError: String?
    @State private var isShowingPaywall = false
    @EnvironmentObject private var entitlementStore: EntitlementStore
    @Environment(\.managedObjectContext) private var managedObjectContext

    var body: some View {
        ScrollView {
            if let insights {
                LazyVStack(spacing: 16) {
                    aiNarrativeCard(insights: insights)
                        .id("ai-narrative")

                    insightCard(title: "概要") {
                        metricRow(label: "登録名刺数", value: "\(insights.totalCards)枚")
                    }
                    .id("summary")

                    if !insights.companyGroups.isEmpty {
                        insightCard(title: "会社別") {
                            ForEach(Array(insights.companyGroups.prefix(15))) { group in
                                rankedRow(
                                    label: group.label,
                                    count: group.count,
                                    total: insights.totalCards,
                                    unit: "人",
                                    color: AppTheme.companyBlueGray
                                )
                            }
                            if insights.companyGroups.count > 15 {
                                Text("他 \(insights.companyGroups.count - 15)社")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .id("companies")
                    }

                    if !insights.areaGroups.isEmpty {
                        insightCard(title: "エリア別") {
                            ForEach(Array(insights.areaGroups.prefix(10))) { group in
                                metricRow(label: group.label, value: "\(group.count)人")
                            }
                        }
                        .id("areas")
                    }

                    if !insights.roleCategoryGroups.isEmpty {
                        insightCard(title: "職種カテゴリ別") {
                            ForEach(Array(insights.roleCategoryGroups.enumerated()), id: \.element.id) { index, group in
                                rankedRow(
                                    label: group.label,
                                    count: group.count,
                                    total: insights.totalCards,
                                    unit: "人",
                                    color: AppTheme.categoryColors[index % AppTheme.categoryColors.count]
                                )
                            }
                        }
                        .id("role-categories")
                    }

                    if !insights.monthlyTrend.isEmpty {
                        insightCard(title: "月別推移") {
                            let maximum = insights.monthlyTrend.map(\.count).max() ?? 1
                            ForEach(Array(insights.monthlyTrend.prefix(12))) { month in
                                rankedRow(
                                    label: month.label,
                                    count: month.count,
                                    total: maximum,
                                    unit: "枚",
                                    color: AppTheme.monthlyBlue
                                )
                            }
                        }
                        .id("monthly-trend")
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
            } else {
                ProgressView("集計中...")
                    .frame(maxWidth: .infinity)
                    .padding(.top, 80)
            }
        }
        .background(Color(uiColor: .systemGroupedBackground).ignoresSafeArea())
        .accessibilityIdentifier("insightsScrollView")
        .navigationTitle("インサイト")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            guard insights == nil else { return }
            insights = InsightsService.shared.generateInsights(context: managedObjectContext)
        }
        .sheet(isPresented: $isShowingPaywall) {
            PaywallView(context: .insightsNarrative)
                .environmentObject(entitlementStore)
        }
    }

    @ViewBuilder
    private func aiNarrativeCard(insights: InsightsService.Insights) -> some View {
        insightCard(title: "AIで読み解く") {
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
                HStack(spacing: 8) {
                    ProgressView()
                    Text("AIが読み解いています...")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else if let narrativeError {
                Text(narrativeError)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button {
                    Task { await generateNarrative(insights: insights) }
                } label: {
                    Label("再試行", systemImage: "arrow.clockwise")
                }
            } else {
                Button {
                    Task { await generateNarrative(insights: insights) }
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "sparkles")
                            .foregroundStyle(AppTheme.brandOrange)
                        VStack(alignment: .leading, spacing: 2) {
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
                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func generateNarrative(insights: InsightsService.Insights) async {
        // 生成・再生成・失敗後の再試行のすべてで、直前のPro権限を再確認する。
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
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.headline)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(
            Color(uiColor: .secondarySystemGroupedBackground),
            in: .rect(cornerRadius: 18, style: .continuous)
        )
    }

    private func metricRow(label: String, value: String) -> some View {
        HStack {
            Text(label).lineLimit(1)
            Spacer()
            Text(value)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)
        }
    }

    private func rankedRow(
        label: String,
        count: Int,
        total: Int,
        unit: String,
        color: Color
    ) -> some View {
        let ratio = total > 0 ? min(1, Double(count) / Double(total)) : 0
        return HStack(spacing: 10) {
            Text(label)
                .lineLimit(1)
            Spacer(minLength: 8)
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.12))
                Capsule().fill(color.opacity(0.72)).frame(width: max(4, 72 * ratio))
            }
            .frame(width: 72, height: 8)
            Text("\(count)\(unit)")
                .foregroundStyle(.secondary)
                .frame(width: 48, alignment: .trailing)
        }
    }
}
