import Combine
import CoreData
import SwiftUI

// ルートビュー
struct ContentView: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.managedObjectContext) private var viewContext
    @EnvironmentObject private var entitlementStore: EntitlementStore
    @StateObject private var cardListViewModel = CardListViewModel()
    @StateObject private var navigationState = AppNavigationState()
    @State private var addButtonSize = CGSize(width: 58, height: 58)

    var body: some View {
        TabView(selection: $navigationState.selectedTab) {
            Tab(value: AppTab.cards) {
                cardsRoot
            } label: {
                Label("名刺", systemImage: "person.text.rectangle")
                    .accessibilityIdentifier("cardsRootTab")
            }

            Tab(value: AppTab.insights) {
                NavigationStack(path: $navigationState.insightsPath) {
                    InsightsView()
                }
            } label: {
                Label("インサイト", systemImage: "chart.xyaxis.line")
                    .accessibilityIdentifier("insightsRootTab")
            }

        }
        .tabViewStyle(.tabBarOnly)
        .tint(AppTheme.brandOrange)
        .background(AppTheme.background.ignoresSafeArea())
        .background {
            if horizontalSizeClass != .regular {
                SystemTabBarAddButtonHost(
                    isVisible: shouldShowRootAddButton,
                    action: navigationState.requestCardAddition
                )
                .frame(width: 0, height: 0)
            }
        }
        .cardAdditionFlow()
        .environmentObject(cardListViewModel)
        .environmentObject(navigationState)
        .overlay {
            ZStack {
                if horizontalSizeClass == .regular && shouldShowRootAddButton {
                    rootAddButtonOverlay
                }
                if navigationState.isCardListBackgroundInteractionBlocked {
                    Color.clear
                        .ignoresSafeArea()
                        .contentShape(Rectangle())
                        .onTapGesture { }
                        .accessibilityHidden(true)
                }
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
            // Core Data通知の発行元queueに依存せず、Navigation状態の更新は
            // 必ずMain RunLoop上で行う。
            .receive(on: RunLoop.main)
        ) { notification in
            clearDeletedSplitSelectionIfNeeded(notification)
        }
    }

    private var cardsRoot: some View {
        Group {
            if horizontalSizeClass == .regular {
                regularCardsRoot
            } else {
                compactCardsRoot
            }
        }
        .toolbar(rootTabBarVisibility, for: .tabBar)
    }

    private var compactCardsRoot: some View {
        searchableCardsRoot(
            NavigationStack {
                CardListView(usesSidebarLayout: false)
                    .navigationDestination(item: activeCardsRouteBinding) { route in
                        cardRouteContent(route)
                    }
            }
        )
    }

    private var regularCardsRoot: some View {
        NavigationSplitView {
            searchableCardsRoot(
                CardListView(usesSidebarLayout: true)
            )
            .toolbar(removing: .sidebarToggle)
            .navigationSplitViewColumnWidth(min: 330, ideal: 380, max: 440)
        } detail: {
            NavigationStack {
                splitDetailContent
            }
        }
        .navigationSplitViewStyle(.balanced)
    }

    private func searchableCardsRoot<Content: View>(_ content: Content) -> some View {
        content
        .searchable(
            text: $cardListViewModel.searchText,
            placement: .navigationBarDrawer(displayMode: .always),
            prompt: "キーワード・自然な言葉で検索"
        )
        .searchSuggestions {
            cardSearchSuggestions
        }
        .onSubmit(of: .search, submitCardSearch)
    }

    private var activeCardsRouteBinding: Binding<CardListRoute?> {
        Binding(
            get: { navigationState.activeCardsRoute },
            set: { route in
                guard route == nil else { return }
                navigationState.returnToCardsRoot()
            }
        )
    }

    @ViewBuilder
    private var cardSearchSuggestions: some View {
        if !navigationState.isRootChromeSuppressed,
           cardListViewModel.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if !cardListViewModel.recentSearches.isEmpty {
                Section("最近の検索") {
                    ForEach(cardListViewModel.recentSearches, id: \.self) { query in
                        cardSearchSuggestion(query, systemImage: "clock.arrow.circlepath")
                    }
                    Button("検索履歴を消去", systemImage: "trash") {
                        cardListViewModel.clearRecentSearches()
                    }
                }
            }
            Section("自然な言葉で検索") {
                cardSearchSuggestion("今月追加した名刺", systemImage: "sparkles")
                cardSearchSuggestion("お気に入りの営業担当", systemImage: "sparkles")
            }
            if !cardListViewModel.companySearchSuggestions.isEmpty {
                Section("会社") {
                    ForEach(cardListViewModel.companySearchSuggestions, id: \.self) { company in
                        cardSearchSuggestion(company, systemImage: "building.2")
                    }
                }
            }
            if !cardListViewModel.tagSearchSuggestions.isEmpty {
                Section("タグ") {
                    ForEach(cardListViewModel.tagSearchSuggestions, id: \.self) { tag in
                        cardSearchSuggestion(tag, systemImage: "tag")
                    }
                }
            }
        }
    }

    private func cardSearchSuggestion(_ text: String, systemImage: String) -> some View {
        Button {
            cardListViewModel.applySearchSuggestion(text)
        } label: {
            Label(text, systemImage: systemImage)
        }
        .searchCompletion(text)
    }

    private func submitCardSearch() {
        guard !navigationState.isRootChromeSuppressed,
              cardListViewModel.isSearchActive else { return }
        if entitlementStore.hasAccess {
            cardListViewModel.submitUnifiedSearch()
        } else if cardListViewModel.filteredCardItems.isEmpty {
            navigationState.requestAISearchPaywall()
        }
    }

    @ViewBuilder
    private var splitDetailContent: some View {
        if let route = navigationState.activeCardsRoute {
            cardRouteContent(route)
        } else {
            ContentUnavailableView(
                "名刺を選択",
                systemImage: "person.text.rectangle",
                description: Text("一覧から名刺を選ぶと詳細を表示します。")
            )
            .background(AppTheme.background.ignoresSafeArea())
        }
    }

    @ViewBuilder
    private func cardRouteContent(_ route: CardListRoute) -> some View {
        switch route {
        case .settings:
            SettingsView()
        case .duplicates:
            DuplicateListView(pairs: $cardListViewModel.duplicatePairs, onMerge: {
                cardListViewModel.fetchCards()
                cardListViewModel.detectDuplicates()
            })
        case .detail(let objectURI):
            if let item = cardListViewModel.listItem(for: objectURI) {
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
        }
    }

    private var rootTabBarVisibility: Visibility {
        navigationState.shouldHideRootTabBar(
            isCompactWidth: horizontalSizeClass != .regular
        ) ? .hidden : .visible
    }

    /// 追加はTabの選択肢ではなく、右端に独立した標準Glass Buttonとして置く。
    private var rootAddButtonOverlay: some View {
        GeometryReader { proxy in
            Button {
                navigationState.requestCardAddition()
            } label: {
                Image(systemName: "plus")
                    .font(.title2.weight(.medium))
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.glassProminent)
            .buttonBorderShape(.circle)
            .tint(AppTheme.brandOrange)
            .accessibilityLabel("名刺を追加")
            .accessibilityIdentifier("cardAddButton")
            .onGeometryChange(for: CGSize.self) { buttonProxy in
                buttonProxy.size
            } action: { size in
                guard size.width > 0, size.height > 0 else { return }
                addButtonSize = size
            }
            .position(
                x: proxy.size.width - AppTheme.Spacing.large - addButtonSize.width / 2,
                y: addButtonCenterY(in: proxy)
            )
        }
    }

    private func addButtonCenterY(in proxy: GeometryProxy) -> CGFloat {
        return proxy.size.height
            - proxy.safeAreaInsets.bottom
            - addButtonSize.height / 2
            - AppTheme.Spacing.large
    }

    private var shouldShowRootAddButton: Bool {
        guard !navigationState.isRootChromeSuppressed else { return false }
        switch navigationState.selectedTab {
        case .cards:
            // iPhoneの詳細遷移では隠すが、iPadの2カラムでは詳細表示中も
            // 一覧側のルート操作として追加ボタンを維持する。
            return horizontalSizeClass == .regular
                || navigationState.activeCardsRoute == nil
        case .insights:
            return navigationState.insightsPath.isEmpty
        }
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
