import CoreData
import SwiftUI

// ルートビュー
struct ContentView: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.managedObjectContext) private var viewContext
    @StateObject private var cardListViewModel = CardListViewModel()
    @StateObject private var navigationState = AppNavigationState()

    /// 追加は画面を持つタブではなく、標準Tab Bar上のpinnedアクションとして扱う。
    /// 選択値へ反映せず、現在のタブと各NavigationPathをそのまま維持する。
    private enum RootTabSelection: Hashable {
        case cards
        case insights
        case add
    }

    var body: some View {
        TabView(selection: rootTabSelection) {
            Tab(value: RootTabSelection.cards) {
                cardsRoot
            } label: {
                Label("名刺", systemImage: "person.text.rectangle")
                    .accessibilityIdentifier("cardsRootTab")
            }

            Tab(value: RootTabSelection.insights) {
                NavigationStack(path: $navigationState.insightsPath) {
                    InsightsView()
                }
            } label: {
                Label("インサイト", systemImage: "chart.xyaxis.line")
                    .accessibilityIdentifier("insightsRootTab")
            }

            Tab(value: RootTabSelection.add) {
                Color.clear
            } label: {
                Label("追加", systemImage: "plus")
                    .foregroundStyle(AppTheme.brandOrange)
                    .accessibilityIdentifier("cardAddButton")
            }
            .tabPlacement(.pinned)
        }
        .tabViewStyle(.tabBarOnly)
        .tint(AppTheme.brandOrange)
        // Tab Barのvisibilityはルートだけが所有する。遷移元と遷移先が別々に
        // 指定すると、popの途中でどちらの指定を採用するかが変わり表示が遅れる。
        .toolbar(rootTabBarVisibility, for: .tabBar)
        .background(AppTheme.background.ignoresSafeArea())
        .cardAdditionFlow()
        .environmentObject(cardListViewModel)
        .environmentObject(navigationState)
        .overlay {
            if navigationState.isCardListBackgroundInteractionBlocked {
                Color.clear
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture { }
                    .accessibilityHidden(true)
            }
        }
        .onAppear {
            clearStaleSplitSelectionIfNeeded()
            guard ScreenshotMode.isActive else { return }
            switch ScreenshotMode.startScreen {
            case "Insights": navigationState.selectedTab = .insights
            case "Settings": navigationState.showSettings()
            default: navigationState.selectedTab = .cards
            }
        }
        .onReceive(
            NotificationCenter.default.publisher(
                for: .NSManagedObjectContextObjectsDidChange,
                object: viewContext
            )
        ) { notification in
            clearDeletedSplitSelectionIfNeeded(notification)
        }
    }

    private var cardsRoot: some View {
        NavigationSplitView(preferredCompactColumn: preferredCompactColumnBinding) {
            NavigationStack {
                CardListView(
                    usesSidebarLayout: horizontalSizeClass == .regular
                )
            }
            .toolbar(removing: .sidebarToggle)
            .navigationSplitViewColumnWidth(min: 330, ideal: 380, max: 440)
        } detail: {
            NavigationStack {
                splitDetailContent
            }
        }
        .navigationSplitViewStyle(.balanced)
    }

    @ViewBuilder
    private var splitDetailContent: some View {
        switch navigationState.activeCardsRoute {
        case .settings:
            SettingsView()
        case .duplicates:
            DuplicateListView(pairs: $cardListViewModel.duplicatePairs, onMerge: {
                cardListViewModel.fetchCards()
                cardListViewModel.detectDuplicates()
            })
        case .detail:
            if let objectURI = navigationState.selectedCardURI,
               let item = cardListViewModel.listItem(for: objectURI) {
                CardDetailView(item: item)
            } else if !cardListViewModel.isListDisplayReady {
                ProgressView("名刺を読み込み中")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(AppTheme.background.ignoresSafeArea())
            } else {
                ContentUnavailableView(
                    "名刺を表示できません",
                    systemImage: "exclamationmark.triangle"
                )
                .background(AppTheme.background.ignoresSafeArea())
            }
        case nil:
            ContentUnavailableView(
                "名刺を選択",
                systemImage: "person.text.rectangle",
                description: Text("一覧から名刺を選ぶと詳細を表示します。")
            )
            .background(AppTheme.background.ignoresSafeArea())
        }
    }

    /// NavigationSplitViewの列構造は幅変更時も作り直さない。
    /// compactでルートがある間だけ詳細列を前面に出し、戻る操作で共通ルートを消去する。
    private var preferredCompactColumnBinding: Binding<NavigationSplitViewColumn> {
        Binding(
            get: {
                navigationState.activeCardsRoute == nil ? .sidebar : .detail
            },
            set: { column in
                guard horizontalSizeClass != .regular,
                      column == .sidebar else { return }
                navigationState.returnToCardsRoot()
            }
        )
    }

    private var rootTabSelection: Binding<RootTabSelection> {
        Binding(
            get: {
                switch navigationState.selectedTab {
                case .cards: .cards
                case .insights: .insights
                }
            },
            set: { selection in
                switch selection {
                case .cards:
                    navigationState.selectedTab = .cards
                case .insights:
                    navigationState.selectedTab = .insights
                case .add:
                    navigationState.requestCardAddition()
                }
            }
        )
    }

    private var rootTabBarVisibility: Visibility {
        navigationState.shouldHideRootTabBar(
            isCompactWidth: horizontalSizeClass != .regular
        ) ? .hidden : .visible
    }

    private func clearStaleSplitSelectionIfNeeded() {
        guard cardListViewModel.isListDisplayReady,
              let objectURI = navigationState.selectedCardURI,
              cardListViewModel.listItem(for: objectURI) == nil else { return }
        navigationState.clearSelectedCardRoute()
    }

    /// 通常の属性更新では選択中カードを再解決しない。削除・invalidateだけを
    /// object IDで照合し、編集保存中の通知でNavigation状態を揺らさない。
    private func clearDeletedSplitSelectionIfNeeded(_ notification: Notification) {
        guard let selectedURI = navigationState.selectedCardURI,
              let selectedID = viewContext.persistentStoreCoordinator?
                .managedObjectID(forURIRepresentation: selectedURI),
              let userInfo = notification.userInfo else { return }

        if (userInfo[NSInvalidatedAllObjectsKey] as? Bool) == true {
            navigationState.clearSelectedCardRoute()
            return
        }

        let removedObjects = [NSDeletedObjectsKey, NSInvalidatedObjectsKey]
            .reduce(into: Set<NSManagedObjectID>()) { result, key in
                let objects = userInfo[key] as? Set<NSManagedObject> ?? []
                result.formUnion(objects.map(\.objectID))
            }
        if removedObjects.contains(selectedID) {
            navigationState.clearSelectedCardRoute()
        }
    }
}
