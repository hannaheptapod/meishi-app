import SwiftUI

// ルートビュー
struct ContentView: View {
    @StateObject private var cardListViewModel = CardListViewModel()
    @StateObject private var navigationState = AppNavigationState()

    var body: some View {
        TabView(selection: $navigationState.selectedTab) {
            Tab("一覧", systemImage: "list.bullet", value: AppTab.cards) {
                NavigationStack(path: $navigationState.cardsPath) {
                    CardListView()
                }
                .toolbar(navigationState.isRootBarHidden ? .hidden : .visible, for: .tabBar)
            }

            Tab("めくる", systemImage: "rectangle.stack", value: AppTab.browse) {
                NavigationStack(path: $navigationState.browsePath) {
                    CardBrowseView()
                }
                .toolbar(navigationState.isRootBarHidden ? .hidden : .visible, for: .tabBar)
            }

            // 標準Tab Barの中央に置くアクション専用項目。
            // 選択されたら一覧へ戻して追加シートを開くため、独立画面は持たない。
            Tab("追加", systemImage: "plus.circle.fill", value: AppTab.add) {
                Color.clear
            }

            Tab("インサイト", systemImage: "chart.xyaxis.line", value: AppTab.insights) {
                NavigationStack(path: $navigationState.insightsPath) {
                    InsightsView()
                }
                .toolbar(navigationState.isRootBarHidden ? .hidden : .visible, for: .tabBar)
            }

            Tab("設定", systemImage: "gearshape", value: AppTab.settings) {
                NavigationStack(path: $navigationState.settingsPath) {
                    SettingsView()
                }
                .toolbar(navigationState.isRootBarHidden ? .hidden : .visible, for: .tabBar)
            }
        }
        .onChange(of: navigationState.selectedTab) { _, tab in
            if tab == .add {
                navigationState.requestCardAddition()
            }
        }
        .background(AppTheme.background.ignoresSafeArea())
        .environmentObject(cardListViewModel)
        .environmentObject(navigationState)
        .onAppear {
            guard ScreenshotMode.isActive else { return }
            switch ScreenshotMode.startScreen {
            case "Insights": navigationState.selectedTab = .insights
            case "Settings": navigationState.selectedTab = .settings
            case "Browse": navigationState.selectedTab = .browse
            default: navigationState.selectedTab = .cards
            }
        }
    }
}
