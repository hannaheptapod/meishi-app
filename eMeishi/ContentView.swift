import SwiftUI

// ルートビュー
struct ContentView: View {
    @StateObject private var cardListViewModel = CardListViewModel()
    @StateObject private var navigationState = AppNavigationState()

    var body: some View {
        TabView(selection: $navigationState.selectedTab) {
            NavigationStack(path: $navigationState.cardsPath) {
                CardListView()
            }
            .tabItem { Label("名刺", systemImage: "person.2") }
            .tag(AppTab.cards)

            NavigationStack(path: $navigationState.insightsPath) {
                InsightsView()
            }
            .tabItem { Label("インサイト", systemImage: "chart.xyaxis.line") }
            .tag(AppTab.insights)

            NavigationStack(path: $navigationState.settingsPath) {
                SettingsView()
            }
            .tabItem { Label("設定", systemImage: "gearshape") }
            .tag(AppTab.settings)
        }
        .tint(AppTheme.brandOrange)
        .background(AppTheme.background.ignoresSafeArea())
        .environmentObject(cardListViewModel)
        .environmentObject(navigationState)
        .onAppear {
            guard ScreenshotMode.isActive else { return }
            switch ScreenshotMode.startScreen {
            case "Insights": navigationState.selectedTab = .insights
            case "Settings": navigationState.selectedTab = .settings
            default: navigationState.selectedTab = .cards
            }
        }
    }
}
