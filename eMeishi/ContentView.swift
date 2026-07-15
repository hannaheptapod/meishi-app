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
                .toolbar(.hidden, for: .tabBar)
            }

            Tab("めくる", systemImage: "rectangle.stack", value: AppTab.browse) {
                NavigationStack(path: $navigationState.browsePath) {
                    CardBrowseView()
                }
                .toolbar(.hidden, for: .tabBar)
            }

            Tab("インサイト", systemImage: "chart.xyaxis.line", value: AppTab.insights) {
                NavigationStack(path: $navigationState.insightsPath) {
                    InsightsView()
                }
                .toolbar(.hidden, for: .tabBar)
            }

            Tab("設定", systemImage: "gearshape", value: AppTab.settings) {
                NavigationStack(path: $navigationState.settingsPath) {
                    SettingsView()
                }
                .toolbar(.hidden, for: .tabBar)
            }
        }
        .toolbar(.hidden, for: .tabBar)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if !navigationState.isRootBarHidden {
                AppRootBar(
                    selection: $navigationState.selectedTab,
                    onAdd: navigationState.requestCardAddition
                )
                .padding(.horizontal, AppTheme.Spacing.large)
                .padding(.bottom, AppTheme.Spacing.small)
                .transition(.move(edge: .bottom).combined(with: .opacity))
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

private struct AppRootBar: View {
    @Binding var selection: AppTab
    let onAdd: () -> Void

    var body: some View {
        GlassEffectContainer(spacing: AppTheme.Spacing.small) {
            HStack(spacing: AppTheme.Spacing.xSmall) {
                tabButton(.cards, title: "一覧", systemImage: "list.bullet")
                tabButton(.browse, title: "めくる", systemImage: "rectangle.stack")

                Button(action: onAdd) {
                    Image(systemName: "plus")
                        .font(.title3.weight(.semibold))
                        .frame(width: 34, height: 34)
                }
                .buttonStyle(.glassProminent)
                .buttonBorderShape(.circle)
                .tint(AppTheme.brandOrange)
                .accessibilityLabel("名刺を追加")
                .accessibilityIdentifier("addButton")

                tabButton(.insights, title: "インサイト", systemImage: "chart.xyaxis.line")
                tabButton(.settings, title: "設定", systemImage: "gearshape")
            }
            .padding(6)
            .glassEffect(.regular, in: .capsule)
        }
        .frame(maxWidth: 560)
        .frame(maxWidth: .infinity)
    }

    private func tabButton(_ tab: AppTab, title: String, systemImage: String) -> some View {
        Button {
            selection = tab
        } label: {
            VStack(spacing: 2) {
                Image(systemName: systemImage)
                    .font(.body.weight(selection == tab ? .semibold : .regular))
                Text(title)
                    .font(.caption2.weight(selection == tab ? .semibold : .regular))
                    .lineLimit(1)
            }
            .foregroundStyle(selection == tab ? AppTheme.brandOrange : Color.secondary)
            .frame(maxWidth: .infinity, minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("appTab_\(title)")
        .accessibilityAddTraits(selection == tab ? .isSelected : [])
    }
}
