import SwiftUI

// 人脈インサイト画面
// 名刺データの自動集計結果を表示する（会社別・エリア別・職種別・月別推移）
struct InsightsView: View {

    @State private var insights: InsightsService.Insights?
    @State private var narrative: String? = nil
    @State private var isGeneratingNarrative = false
    @State private var narrativeError: String? = nil
    @State private var isShowingPaywall = false
    @EnvironmentObject private var entitlementStore: EntitlementStore

    var body: some View {
        List {
            if let insights = insights {
                aiNarrativeSection(insights: insights)
                // 概要
                Section {
                    HStack {
                        Text("登録名刺数")
                        Spacer()
                        Text("\(insights.totalCards)枚")
                            .fontWeight(.semibold)
                    }
                }

                // 会社別
                if !insights.companyGroups.isEmpty {
                    Section("会社別") {
                        ForEach(insights.companyGroups.prefix(15)) { group in
                            HStack {
                                Text(group.label)
                                    .lineLimit(1)
                                Spacer()
                                Text("\(group.count)人")
                                    .foregroundStyle(.secondary)
                            }
                        }
                        if insights.companyGroups.count > 15 {
                            Text("他 \(insights.companyGroups.count - 15)社")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                // エリア別
                if !insights.areaGroups.isEmpty {
                    Section("エリア別") {
                        ForEach(insights.areaGroups.prefix(10)) { group in
                            HStack {
                                Text(group.label)
                                Spacer()
                                Text("\(group.count)人")
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                // 職種カテゴリ別
                if !insights.roleCategoryGroups.isEmpty {
                    Section("職種カテゴリ別") {
                        ForEach(insights.roleCategoryGroups) { group in
                            HStack {
                                Text(group.label)
                                Spacer()
                                barIndicator(count: group.count, total: insights.totalCards)
                                Text("\(group.count)人")
                                    .foregroundStyle(.secondary)
                                    .frame(width: 40, alignment: .trailing)
                            }
                        }
                    }
                }

                // 月別推移
                if !insights.monthlyTrend.isEmpty {
                    Section("月別推移") {
                        ForEach(insights.monthlyTrend.prefix(12)) { month in
                            HStack {
                                Text(month.label)
                                Spacer()
                                barIndicator(count: month.count, total: insights.monthlyTrend.map(\.count).max() ?? 1)
                                Text("\(month.count)枚")
                                    .foregroundStyle(.secondary)
                                    .frame(width: 40, alignment: .trailing)
                            }
                        }
                    }
                }
            } else {
                ProgressView("集計中...")
            }
        }
        .navigationTitle("インサイト")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            insights = InsightsService.shared.generateInsights()
        }
        .sheet(isPresented: $isShowingPaywall) {
            PaywallView(context: .insightsNarrative)
                .environmentObject(entitlementStore)
        }
    }

    // MARK: - AI ナラティブ（Pro 機能）

    @ViewBuilder
    private func aiNarrativeSection(insights: InsightsService.Insights) -> some View {
        Section("AI で読み解く") {
            if let narrative {
                Text(narrative)
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                Button {
                    Task { await generateNarrative(insights: insights) }
                } label: {
                    Label("もう一度生成", systemImage: "arrow.clockwise")
                        .font(.caption)
                }
                .disabled(isGeneratingNarrative)
            } else if isGeneratingNarrative {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("AI が読み解いています...")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            } else if let narrativeError {
                Text(narrativeError)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Button {
                    if entitlementStore.hasAccess {
                        Task { await generateNarrative(insights: insights) }
                    } else {
                        isShowingPaywall = true
                    }
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "sparkles")
                            .foregroundStyle(.tint)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("AI に集計を読み解いてもらう")
                                .font(.subheadline.bold())
                                .foregroundStyle(.primary)
                            Text(entitlementStore.hasAccess
                                 ? "次にアプローチすべき層を AI が提案します"
                                 : "eMeishi Pro でご利用いただけます")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .foregroundStyle(.secondary)
                            .font(.caption)
                    }
                }
            }
        }
    }

    private func generateNarrative(insights: InsightsService.Insights) async {
        isGeneratingNarrative = true
        narrativeError = nil
        defer { isGeneratingNarrative = false }
        do {
            narrative = try await InsightsService.shared.generateNarrative(insights: insights)
        } catch InsightsService.NarrativeError.unavailable {
            narrativeError = "AI 解釈はこの端末では利用できません。Apple Intelligence 対応端末（iPhone 15 Pro 以降など）でご利用ください。"
        } catch {
            narrativeError = "AI 解釈の生成に失敗しました。しばらくしてから再試行してください。"
        }
    }

    // MARK: - バーインジケーター

    private func barIndicator(count: Int, total: Int) -> some View {
        let ratio = total > 0 ? Double(count) / Double(total) : 0
        return GeometryReader { geo in
            RoundedRectangle(cornerRadius: 2)
                .fill(.tint.opacity(0.3))
                .frame(width: max(4, geo.size.width * ratio), height: geo.size.height)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .frame(width: 60, height: 14)
    }
}
