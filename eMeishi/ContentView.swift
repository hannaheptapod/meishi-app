import CoreData
import SwiftUI

// ルートビュー
struct ContentView: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @EnvironmentObject private var entitlementStore: EntitlementStore
    @StateObject private var cardListViewModel = CardListViewModel()
    @StateObject private var navigationState = AppNavigationState()
    @State private var tabBarAnchorFrame = CGRect.zero
    @State private var addButtonSize = CGSize(width: 58, height: 58)
    @State private var addButtonLabelSide: CGFloat = 44
    @State private var isShowingAISearchPaywall = false

    var body: some View {
        TabView(selection: $navigationState.selectedTab) {
            Tab("名刺", systemImage: "person.text.rectangle", value: AppTab.cards) {
                cardsRoot
            }

            Tab("インサイト", systemImage: "chart.xyaxis.line", value: AppTab.insights) {
                NavigationStack(path: $navigationState.insightsPath) {
                    InsightsView()
                }
            }
        }
        .tabViewStyle(.tabBarOnly)
        .tabBarMinimizeBehavior(.never)
        .tint(AppTheme.brandOrange)
        .background {
            SystemTabBarFrameReader(itemFrame: $tabBarAnchorFrame)
                .frame(width: 0, height: 0)
        }
        .background(AppTheme.background.ignoresSafeArea())
        .overlay {
            if shouldShowRootAddButton {
                rootAddButtonOverlay
                    .id(rootAddButtonPresentationID)
            }
        }
        .cardAdditionFlow()
        .environmentObject(cardListViewModel)
        .environmentObject(navigationState)
        .sheet(isPresented: $isShowingAISearchPaywall) {
            PaywallView(context: .aiSearch)
                .environmentObject(entitlementStore)
        }
        .onAppear {
            guard ScreenshotMode.isActive else { return }
            switch ScreenshotMode.startScreen {
            case "Insights": navigationState.selectedTab = .insights
            case "Settings": navigationState.showSettings()
            default: navigationState.selectedTab = .cards
            }
        }
    }

    @ViewBuilder
    private var cardsRoot: some View {
        Group {
            if horizontalSizeClass == .regular {
                NavigationSplitView {
                    NavigationStack(path: $navigationState.cardsPath) {
                        CardListView(usesSplitView: true)
                    }
                    .toolbar(removing: .sidebarToggle)
                    .navigationSplitViewColumnWidth(min: 330, ideal: 380, max: 440)
                } detail: {
                    NavigationStack {
                        if let card = navigationState.selectedCardForSplit,
                           !card.isDeleted,
                           card.managedObjectContext != nil {
                            CardDetailView(card: card)
                        } else {
                            ContentUnavailableView(
                                "名刺を選択",
                                systemImage: "person.text.rectangle",
                                description: Text("一覧から名刺を選ぶと詳細を表示します。")
                            )
                            .background(AppTheme.background.ignoresSafeArea())
                        }
                    }
                }
                .navigationSplitViewStyle(.balanced)
            } else {
                NavigationStack(path: $navigationState.cardsPath) {
                    CardListView()
                }
            }
        }
        // NavigationStackより長く生存する階層が標準検索UIを所有する。
        // push/popで検索コントローラを作り直さず、内容とGlass背景を同一ライフサイクルに保つ。
        .searchable(
            text: $cardListViewModel.searchText,
            placement: .navigationBarDrawer(displayMode: .always),
            prompt: "キーワード・自然な言葉で検索"
        )
        .searchSuggestions {
            cardSearchSuggestions
        }
        .onSubmit(of: .search) {
            submitCardSearch()
        }
        .toolbar(cardsRootTabBarVisibility, for: .tabBar)
    }

    private var cardsRootTabBarVisibility: Visibility {
        guard horizontalSizeClass == .compact else { return .visible }
        return navigationState.cardsPath.isEmpty && !navigationState.isRootChromeSuppressed
            ? .visible
            : .hidden
    }

    @ViewBuilder
    private var cardSearchSuggestions: some View {
        if navigationState.cardsPath.isEmpty,
           !navigationState.isRootChromeSuppressed,
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
        guard navigationState.cardsPath.isEmpty,
              cardListViewModel.isSearchActive else { return }
        if entitlementStore.hasAccess {
            cardListViewModel.submitUnifiedSearch()
        } else if cardListViewModel.filteredCards.isEmpty {
            isShowingAISearchPaywall = true
        }
    }

    /// TabView全体の最前面に、現在のルート画面用追加ボタンを1個だけ配置する。
    /// 子画面への遷移時はオーバーレイごと除去し、遷移スナップショットへ操作面を残さない。
    private var rootAddButtonOverlay: some View {
        GeometryReader { proxy in
            if horizontalSizeClass == .compact {
                Button {
                    navigationState.requestCardAddition()
                } label: {
                    Image(systemName: "plus")
                        .font(.title2.weight(.medium))
                        .frame(width: addButtonLabelSide, height: addButtonLabelSide)
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
                    let heightDifference = tabBarAnchorFrame.height - size.height
                    guard abs(heightDifference) > 0.5 else { return }
                    addButtonLabelSide = min(max(addButtonLabelSide + heightDifference, 36), 64)
                }
                .position(
                    x: proxy.size.width - AppTheme.Spacing.large - addButtonSize.width / 2,
                    y: addButtonCenterY(in: proxy)
                )
            }
        }
    }

    private func addButtonCenterY(in proxy: GeometryProxy) -> CGFloat {
        if !tabBarAnchorFrame.isEmpty {
            return tabBarAnchorFrame.midY - proxy.frame(in: .global).minY
        }
        // Tab Bar座標の確定前だけ、安全領域から一時座標を算出する。
        return proxy.size.height
            - proxy.safeAreaInsets.bottom
            - addButtonSize.height / 2
            + AppTheme.Spacing.small
    }

    private var shouldShowRootAddButton: Bool {
        guard !navigationState.isRootChromeSuppressed else { return false }
        switch navigationState.selectedTab {
        case .cards:
            return navigationState.cardsPath.isEmpty
        case .insights:
            return navigationState.insightsPath.isEmpty
        }
    }

    /// Navigation遷移のスナップショットへ前画面の追加ボタンを残さないため、
    /// 表示コンテキストごとにオーバーレイの同一性を分離する。
    private var rootAddButtonPresentationID: String {
        switch navigationState.selectedTab {
        case .cards: "cards-root-add"
        case .insights: "insights-root-add"
        }
    }
}
