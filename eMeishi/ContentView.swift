import Combine
import CoreData
import SwiftUI

// ルートビュー
struct ContentView: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.managedObjectContext) private var viewContext
    @EnvironmentObject private var entitlementStore: EntitlementStore
    @EnvironmentObject private var rootPresentationRequests: AppRootPresentationRequests
    @StateObject private var cardListViewModel = CardListViewModel()
    @StateObject private var navigationState = AppNavigationState()
    @State private var compactPresentedRoute: CompactCardsRoutePresentation?

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
        .overlay(alignment: .bottomTrailing) {
            if horizontalSizeClass == .regular && shouldShowRootAddButton {
                rootAddButtonOverlay
            }
        }
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
            case "Settings":
                navigationState.prepareForSettingsSheet()
                rootPresentationRequests.requestSettingsSheet()
            default: navigationState.selectedTab = .cards
            }
        }
        .onChange(of: navigationState.activeCardsRoute) { _, _ in
            syncCompactCardsRoutePresentation()
        }
        .onChange(of: horizontalSizeClass) { _, _ in
            syncCompactCardsRoutePresentation()
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
        NavigationStack {
            cardsListRoot(usesSidebarLayout: false)
        }
        .fullScreenCover(item: $compactPresentedRoute, onDismiss: {
            guard horizontalSizeClass != .regular else { return }
            navigationState.returnToCardsRoot()
        }) { presentation in
            compactCardsRouteContent(presentation.route)
        }
    }

    private struct CompactCardsRoutePresentation: Identifiable {
        let route: CardListRoute

        var id: CardListRoute { route }
    }

    private func syncCompactCardsRoutePresentation() {
        guard horizontalSizeClass != .regular,
              navigationState.selectedTab == .cards else {
            setCompactPresentedRouteWithoutAnimation(nil)
            return
        }
        guard let route = navigationState.activeCardsRoute else {
            setCompactPresentedRouteWithoutAnimation(nil)
            return
        }
        guard compactPresentedRoute?.route != route else { return }
        setCompactPresentedRouteWithoutAnimation(
            CompactCardsRoutePresentation(route: route)
        )
    }

    private func compactCardsRouteContent(_ route: CardListRoute) -> some View {
        CompactCardsRouteContainer(
            route: route,
            onPopCompletion: completeCompactRoutePop
        ) { destination in
            cardRouteContent(destination)
                .toolbar(.visible, for: .navigationBar)
        }
        // 一覧のNavigation Itemを破棄せず、詳細だけを別Presentationで表示する。
        // iOS標準検索欄のGlass背景がpop後に遅れて再構成されるのを避ける。
        .presentationBackground(.clear)
    }

    private struct CompactCardsRouteContainer<Destination: View>: View {
        let route: CardListRoute
        let onPopCompletion: () -> Void
        @ViewBuilder let destination: (CardListRoute) -> Destination
        @State private var isPresented = false
        @State private var dragOffset: CGFloat = 0
        @State private var isEdgeDragging = false
        @State private var isCompletingPop = false

        var body: some View {
            GeometryReader { proxy in
                NavigationStack {
                    destination(route)
                        // 左端drag中は移動する詳細面のButtonが指の下に残るため、
                        // dragと同じ指離しで画像表示などを発火させない。
                        .allowsHitTesting(!isEdgeDragging && !isCompletingPop)
                        .toolbar {
                            ToolbarItem(placement: .topBarLeading) {
                                Button {
                                    completePop(containerWidth: proxy.size.width)
                                } label: {
                                    Image(systemName: "chevron.backward")
                                }
                                .tint(Color.primary)
                                .accessibilityLabel("戻る")
                            }
                        }
                    }
                .offset(x: isPresented ? dragOffset : proxy.size.width)
                .simultaneousGesture(edgePopGesture(containerWidth: proxy.size.width))
                .task {
                    // fullScreenCover自体は無動作で配置し、詳細面だけを右から移動する。
                    // UIKit標準popの全画面dimmingを使わず、一覧の色を変化させない。
                    try? await Task.sleep(for: .milliseconds(30))
                    guard !isPresented else { return }
                    withAnimation(.easeOut(duration: 0.28)) {
                        isPresented = true
                    }
                }
            }
        }

        private func edgePopGesture(containerWidth: CGFloat) -> some Gesture {
            DragGesture(minimumDistance: 8, coordinateSpace: .local)
                .onChanged { value in
                    guard !isCompletingPop,
                          value.startLocation.x <= 24,
                          value.translation.width > 0,
                          value.translation.width > abs(value.translation.height) else { return }
                    isEdgeDragging = true
                    dragOffset = min(containerWidth, value.translation.width)
                }
                .onEnded { value in
                    guard isEdgeDragging else { return }

                    let shouldComplete = value.translation.width > containerWidth * 0.25
                        || value.predictedEndTranslation.width > containerWidth * 0.6
                    if shouldComplete {
                        completePop(containerWidth: containerWidth)
                    } else {
                        // 指離し直後の子Button actionも抑止するため、詳細面が
                        // 元位置へ戻り切るまではhit testingを再開しない。
                        withAnimation(.easeOut(duration: 0.2), completionCriteria: .logicallyComplete) {
                            dragOffset = 0
                        } completion: {
                            isEdgeDragging = false
                        }
                    }
                }
        }

        private func completePop(containerWidth: CGFloat) {
            guard !isCompletingPop else { return }
            isCompletingPop = true
            withAnimation(.easeOut(duration: 0.22), completionCriteria: .logicallyComplete) {
                dragOffset = containerWidth
            } completion: {
                onPopCompletion()
            }
        }
    }

    private func completeCompactRoutePop() {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            compactPresentedRoute = nil
            navigationState.returnToCardsRoot()
        }
    }

    private func setCompactPresentedRouteWithoutAnimation(
        _ presentation: CompactCardsRoutePresentation?
    ) {
        guard compactPresentedRoute?.route != presentation?.route else { return }
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            compactPresentedRoute = presentation
        }
    }

    private var regularCardsRoot: some View {
        NavigationSplitView {
            cardsListRoot(usesSidebarLayout: true)
                .toolbar(removing: .sidebarToggle)
                .navigationSplitViewColumnWidth(min: 330, ideal: 380, max: 440)
        } detail: {
            NavigationStack {
                splitDetailContent
            }
        }
        .navigationSplitViewStyle(.balanced)
    }

    /// 標準検索UIはNavigationコンテナではなく一覧側のNavigation Itemが所有する。
    /// 詳細のpushやSplit Viewのdetail切替で検索コントローラを付け替えない。
    private func cardsListRoot(usesSidebarLayout: Bool) -> some View {
        CardListView(usesSidebarLayout: usesSidebarLayout)
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
        case .duplicates:
            DuplicateListView(pairs: $cardListViewModel.duplicatePairs, onMerge: {
                cardListViewModel.fetchCards()
                cardListViewModel.detectDuplicates()
            })
        case .detail(let objectURI):
            if let item = cardListViewModel.listItem(for: objectURI) {
                CardDetailView(item: item)
                    // Split Viewはdetail列の同じ構造を再利用するため、名刺URIを
                    // View identityに含めて@Stateへ旧名刺を残さない。
                    .id(objectURI)
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
        // compact詳細は別の全画面層がRoot Chromeを覆う。背面のTab Barを
        // 非表示化するとpop後の再生成が見えるため、選択モードだけを判定する。
        navigationState.shouldHideRootTabBar(
            isCompactWidth: false
        ) ? .hidden : .visible
    }

    /// 追加はTabの選択肢ではなく、右端に独立した標準Glass Buttonとして置く。
    private var rootAddButtonOverlay: some View {
        RootAddButton(action: navigationState.requestCardAddition)
        .frame(
            width: AppTheme.RootChrome.addButtonMaximumDiameter,
            height: AppTheme.RootChrome.addButtonMaximumDiameter
        )
        .accessibilityLabel("名刺を追加")
        .accessibilityIdentifier("cardAddButton")
        // overlayの下端は既にContentViewのSafe Area境界に一致する。
        // 標準bottomBarのGlass描画が持つ光学的な下余白だけ共通トークンで
        // 合わせ、端末固有のSafe Area値は足さない。
        .safeAreaPadding(.trailing, AppTheme.Spacing.large)
        .padding(.bottom, AppTheme.Spacing.xSmall)
    }

    private var shouldShowRootAddButton: Bool {
        guard !navigationState.isRootChromeSuppressed else { return false }
        switch navigationState.selectedTab {
        case .cards:
            // compact詳細では全画面層の背面に維持し、popの最初の一覧フレーム
            // から表示できるよう再生成しない。iPadでは従来どおり常時表示する。
            return true
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
