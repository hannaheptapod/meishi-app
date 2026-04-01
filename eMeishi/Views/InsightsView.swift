import SwiftUI

// 人脈インサイト画面
// 名刺データの自動集計結果を表示する（会社別・エリア別・職種別・月別推移）
struct InsightsView: View {

    @State private var insights: InsightsService.Insights?
    @Environment(\.managedObjectContext) private var context

    var body: some View {
        List {
            if let insights = insights {
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
            insights = InsightsService.shared.generateInsights(context: context)
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
