import CoreData
import SwiftUI
import UIKit

// 名刺一覧画面
struct CardListView: View {
    var usesSplitView = false

    @EnvironmentObject private var viewModel: CardListViewModel
    @EnvironmentObject private var navigationState: AppNavigationState
    @Environment(\.managedObjectContext) private var viewContext
    @State private var isShowingImportConfirm = false
    @State private var isShowingTagManager = false
    @State private var isContextMenuPresented = false
    @State private var suppressCardTapUntil = Date.distantPast
    @State private var selectionChromeOwner = UUID()

    // コンテキストメニュー用
    @State private var cardToEdit: BusinessCard? = nil
    @State private var cardToDelete: BusinessCard? = nil
    @State private var isShowingDeleteConfirm = false

    // 選択モード用
    @State private var editMode: EditMode = .inactive
    @State private var selectedCardIDs: Set<BusinessCard.ID> = []
    @State private var isShowingBulkDeleteConfirm = false
    @State private var isShowingBulkTagSheet = false
    @State private var isShowingPaywall = false
    // スクリーンショット撮影モード用：CardFormView を OCR 完了状態のモックで開く
    @State private var isShowingMockOCRForm = false

    @EnvironmentObject private var entitlementStore: EntitlementStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    // 触覚フィードバック
    private let haptic = UIImpactFeedbackGenerator(style: .light)

    /// 選択モード時のみ選択を受け付けるバインディング
    private var selectionBinding: Binding<Set<BusinessCard.ID>> {
        Binding(
            get: { editMode == .active ? selectedCardIDs : [] },
            set: { if editMode == .active { selectedCardIDs = $0 } }
        )
    }

    var body: some View {
        interactionPresentations
    }

    private var baseView: some View {
        Group {
            if viewModel.cards.isEmpty {
                emptyState
            } else if viewModel.filteredCards.isEmpty && viewModel.isSearchActive {
                searchEmptyState
            } else if viewModel.filteredCards.isEmpty && viewModel.isFilterActive {
                filterEmptyState
            } else {
                cardList
            }
        }
            .navigationTitle(editMode == .active ? selectionTitle : "名刺")
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaBar(edge: .top, spacing: 0) {
                if let externalFilter = viewModel.externalFilter,
                   editMode == .inactive {
                    activeExternalFilterBar(externalFilter)
                        .frame(maxWidth: AppTheme.cardListMaximumWidth)
                        .padding(.horizontal, AppTheme.Spacing.large)
                        .padding(.top, AppTheme.Spacing.small)
                        .padding(.bottom, AppTheme.Spacing.xSmall)
                }
            }
            .scrollEdgeEffectStyle(.soft, for: .top)
            .toolbar {
                if editMode == .active {
                    selectionToolbarContent
                } else {
                    normalToolbarContent
                }
            }
            .onChange(of: editMode) { _, mode in
                navigationState.setRootChromeSuppressed(
                    mode == .active,
                    owner: selectionChromeOwner
                )
            }
            .environment(\.editMode, $editMode)
            .navigationDestination(for: CardListRoute.self) { route in
                destination(for: route)
            }
            .background(AppTheme.background.ignoresSafeArea())
    }

    @ViewBuilder
    private func destination(for route: CardListRoute) -> some View {
        switch route {
        case .detail(let objectURI):
            if let objectID = viewContext.persistentStoreCoordinator?
                .managedObjectID(forURIRepresentation: objectURI),
               let object = try? viewContext.existingObject(with: objectID),
               let card = object as? BusinessCard {
                CardDetailView(card: card)
            } else {
                ContentUnavailableView("名刺を表示できません", systemImage: "exclamationmark.triangle")
            }
        case .settings:
            SettingsView()
        case .duplicates:
            DuplicateListView(pairs: $viewModel.duplicatePairs, onMerge: {
                viewModel.fetchCards()
                viewModel.detectDuplicates()
            })
        }
    }

    private var importPresentations: some View {
        baseView
    }

    private var managementPresentations: some View {
        importPresentations
            .sheet(item: $viewModel.exportItem) { item in
                ShareSheet(activityItems: [item.url])
            }
            .alert("エラー", isPresented: Binding(
                get: { viewModel.errorMessage != nil },
                set: { if !$0 { viewModel.errorMessage = nil } }
            )) {
                Button("OK", role: .cancel) { viewModel.errorMessage = nil }
            } message: {
                Text(viewModel.errorMessage ?? "")
            }
            .sheet(isPresented: $isShowingTagManager) {
                TagManagementView()
                    .environmentObject(viewModel)
            }
            .alert("連絡先からインポート", isPresented: $isShowingImportConfirm) {
                Button("インポート") { viewModel.importFromContacts() }
                Button("キャンセル", role: .cancel) {}
            } message: {
                Text("iPhoneの連絡先をすべて名刺としてインポートします。")
            }
            .alert("インポート完了", isPresented: Binding(
                get: { viewModel.importResultMessage != nil },
                set: { if !$0 { viewModel.importResultMessage = nil } }
            )) {
                Button("OK", role: .cancel) { viewModel.importResultMessage = nil }
            } message: {
                Text(viewModel.importResultMessage ?? "")
            }
    }

    private var interactionPresentations: some View {
        managementPresentations
            // コンテキストメニューからの編集シート
            .sheet(item: $cardToEdit) { card in
                CardFormView(card: card, onSave: {
                    viewModel.fetchCards()
                    cardToEdit = nil
                })
            }
            // コンテキストメニューからの削除確認
            .confirmationDialog(
                "名刺を削除",
                isPresented: $isShowingDeleteConfirm,
                titleVisibility: .visible
            ) {
                Button("削除", role: .destructive) {
                    if let card = cardToDelete {
                        viewModel.deleteCards([card])
                    }
                    cardToDelete = nil
                }
                Button("キャンセル", role: .cancel) {
                    cardToDelete = nil
                }
            } message: {
                Text("「\(cardToDelete?.fullName ?? "")」を削除します。この操作は取り消せません。")
            }
            // 一括削除確認
            .confirmationDialog(
                "名刺を削除",
                isPresented: $isShowingBulkDeleteConfirm,
                titleVisibility: .visible
            ) {
                Button("削除（\(selectedCardIDs.count)件）", role: .destructive) {
                    viewModel.deleteCards(viewModel.selectedCards(from: selectedCardIDs))
                    selectedCardIDs = []
                    editMode = .inactive
                }
                Button("キャンセル", role: .cancel) {}
            } message: {
                Text("\(selectedCardIDs.count)件の名刺を削除します。この操作は取り消せません。")
            }
            // 一括タグ付けシート
            .sheet(isPresented: $isShowingBulkTagSheet) {
                BulkTagAssignView(
                    selectedCardIDs: selectedCardIDs,
                    onDismiss: {
                        isShowingBulkTagSheet = false
                    }
                )
                .environmentObject(viewModel)
                .environmentObject(entitlementStore)
            }
            .onAppear {
                viewModel.externalFilter = navigationState.externalFilter
                handleScreenshotMode()
            }
            .onChange(of: navigationState.externalFilter) { _, filter in
                viewModel.externalFilter = filter
            }
            .sheet(isPresented: $isShowingPaywall) {
                PaywallView(context: .aiSearch)
                    .environmentObject(entitlementStore)
            }
            // スクリーンショット撮影モード用：OCR 完了状態のモックフォームを表示
            .sheet(isPresented: $isShowingMockOCRForm) {
                CardFormView(viewModelFactory: {
                    ScreenshotMockSupport.makeMockOCRFinishedViewModel()
                }, onSave: { isShowingMockOCRForm = false })
                .environmentObject(viewModel)
            }
    }

    /// XCUITest（ScreenshotRunner）から START_SCREEN を受け取った場合、対応するシートを開く
    private func handleScreenshotMode() {
        guard ScreenshotMode.isActive, let screen = ScreenshotMode.startScreen else { return }
        switch screen {
        case "Tags":     isShowingTagManager = true
        case "AIChat":
            viewModel.searchText = "IT関係の人"
            viewModel.submitUnifiedSearch()
        case "FormOCR":  isShowingMockOCRForm = true
        case "Paywall":  isShowingPaywall = true
        case "Settings": navigationState.pushCardsRoute(.settings)
        default: break
        }
    }

    // MARK: - 選択件数タイトル

    /// 選択モード中は件数を表示、通常時は空
    private var selectionTitle: String {
        guard editMode == .active else { return "" }
        if selectedCardIDs.isEmpty {
            return "項目を選択"
        }
        return "\(selectedCardIDs.count)件選択中"
    }

    // MARK: - 通常モードのツールバー

    @ToolbarContentBuilder
    private var normalToolbarContent: some ToolbarContent {
        // 写真アプリと同様に、並べ替え・フィルターを選択操作の左へ置く。
        ToolbarItem(placement: .topBarTrailing) {
            if !viewModel.cards.isEmpty {
                sortFilterMenu
            }
        }

        if !usesSplitView {
            ToolbarSpacer(.fixed, placement: .topBarTrailing)
        }

        ToolbarItem(placement: .topBarTrailing) {
            if !viewModel.cards.isEmpty {
                Button("選択") {
                    editMode = .active
                    selectedCardIDs = []
                }
                .tint(Color.primary)
                .accessibilityIdentifier("selectButton")
            }
        }

        if !usesSplitView {
            ToolbarSpacer(.fixed, placement: .topBarTrailing)
        }

        // 右上: その他の操作
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                if !viewModel.cards.isEmpty {
                    Button {
                        navigationState.pushCardsRoute(.duplicates)
                    } label: {
                        Label(
                            viewModel.duplicatePairs.isEmpty ? "重複チェック" : "重複チェック（\(viewModel.duplicatePairs.count)件）",
                            systemImage: "person.2.slash"
                        )
                    }
                    Divider()
                }
                Button {
                    isShowingImportConfirm = true
                } label: {
                    Label("連絡先からインポート", systemImage: "person.crop.circle.badge.plus")
                }
                .disabled(viewModel.isImporting)
                .accessibilityIdentifier("importFromContacts")
                if !viewModel.cards.isEmpty {
                    Divider()
                    Button { viewModel.exportCSV() } label: {
                        Label("CSV としてエクスポート", systemImage: "tablecells")
                    }
                    Button { viewModel.exportVCard() } label: {
                        Label("vCard としてエクスポート", systemImage: "person.crop.rectangle")
                    }
                }
                Divider()
                Button { isShowingTagManager = true } label: {
                    Label("タグ管理", systemImage: "tag")
                }
                .accessibilityIdentifier("tagManager")
                Divider()
                Button {
                    navigationState.pushCardsRoute(.settings)
                } label: {
                    Label("設定", systemImage: "gearshape")
                }
                .accessibilityIdentifier("settingsMenu")
            } label: {
                Label("メニュー", systemImage: "ellipsis")
            }
            .tint(Color.primary)
            .accessibilityIdentifier("ellipsisMenu")
        }

        if usesSplitView {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    navigationState.requestCardAddition()
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .tint(AppTheme.brandOrange)
                .accessibilityLabel("名刺を追加")
                .accessibilityIdentifier("splitCardAddButton")
            }
        }
    }

    // MARK: - 選択モードのツールバー

    @ToolbarContentBuilder
    private var selectionToolbarContent: some ToolbarContent {
        // 左上: すべて選択/全解除
        ToolbarItem(placement: .topBarLeading) {
            Button(selectedCardIDs.count == viewModel.filteredCards.count && !viewModel.filteredCards.isEmpty ? "全解除" : "すべて選択") {
                if selectedCardIDs.count == viewModel.filteredCards.count {
                    selectedCardIDs = []
                } else {
                    selectedCardIDs = Set(viewModel.filteredCards.compactMap(\.id))
                }
            }
            .tint(Color.primary)
            .accessibilityIdentifier("selectAllButton")
        }

        // 右上: 完了ボタン（HIG: Done は trailing + .prominent）
        ToolbarItem(placement: .topBarTrailing) {
            Button("完了") {
                editMode = .inactive
                selectedCardIDs = []
            }
            .fontWeight(.semibold)
            .tint(Color.primary)
            .accessibilityIdentifier("doneButton")
        }

        // 下部: 一括操作（左: 削除 / 中央: タグ＋お気に入り / 右: エクスポート）
        ToolbarItemGroup(placement: .bottomBar) {
            // 削除
            Button(role: .destructive) {
                isShowingBulkDeleteConfirm = true
            } label: {
                Label("削除", systemImage: "trash")
            }
            .tint(.red)
            .disabled(selectedCardIDs.isEmpty)
            .accessibilityIdentifier("bulkDeleteButton")

            Spacer()

            // タグ
            Button {
                isShowingBulkTagSheet = true
            } label: {
                Label("タグ", systemImage: "tag")
            }
            .tint(Color.primary)
            .disabled(selectedCardIDs.isEmpty)

            // お気に入り
            Button {
                haptic.impactOccurred()
                viewModel.toggleBulkFavorite(ids: selectedCardIDs)
            } label: {
                Label("お気に入り", systemImage: "star")
            }
            .tint(Color.primary)
            .disabled(selectedCardIDs.isEmpty)

            Spacer()

            // エクスポート
            Menu {
                Button {
                    viewModel.exportSelectedCSV(ids: selectedCardIDs)
                } label: {
                    Label("CSVエクスポート", systemImage: "tablecells")
                }
                Button {
                    viewModel.exportSelectedVCard(ids: selectedCardIDs)
                } label: {
                    Label("vCardエクスポート", systemImage: "person.crop.rectangle")
                }
            } label: {
                Label("エクスポート", systemImage: "square.and.arrow.up")
            }
            .tint(Color.primary)
            .disabled(selectedCardIDs.isEmpty)
        }
    }

    // MARK: - サブビュー

    private var cardList: some View {
        let showIndex = editMode == .inactive && !viewModel.isSearchActive &&
            (viewModel.sortKey == .name || viewModel.sortKey == .company)
        return ScrollViewReader { proxy in
            List(selection: selectionBinding) {
                if viewModel.isSearchActive {
                    // 検索中はフラット表示
                    ForEach(viewModel.filteredCards) { card in
                        cardRow(for: card)
                    }
                    .onDelete { offsets in
                        // 確認ダイアログを経由してから削除（HIG: 取り消せない破壊的操作は確認が必要）
                        if let card = offsets.map({ viewModel.filteredCards[$0] }).first {
                            cardToDelete = card
                            isShowingDeleteConfirm = true
                        }
                    }
                    .deleteDisabled(editMode == .active)
                } else {
                    // ソート順に応じたセクション表示
                    ForEach(viewModel.groupedCards) { section in
                        Section {
                            ForEach(section.cards) { card in
                                cardRow(for: card)
                            }
                            .onDelete { offsets in
                                // 確認ダイアログを経由してから削除（HIG: 取り消せない破壊的操作は確認が必要）
                                if let card = offsets.map({ section.cards[$0] }).first {
                                    cardToDelete = card
                                    isShowingDeleteConfirm = true
                                }
                            }
                            .deleteDisabled(editMode == .active)
                        } header: {
                            HStack(spacing: 7) {
                                Text(section.title)
                                    .font(.subheadline.weight(.bold))
                                    .foregroundStyle(.primary)
                                Text("\(section.cards.count)")
                                    .font(.caption.weight(.bold))
                                    .foregroundStyle(Color.primary.opacity(0.72))
                                    .padding(.horizontal, 7)
                                    .padding(.vertical, 3)
                                    .background(Color.secondary.opacity(0.16), in: Capsule())
                            }
                            .textCase(nil)
                            .accessibilityElement(children: .combine)
                            .accessibilityLabel("\(section.title)、\(section.cards.count)件")
                        }
                        .id(section.id)
                    }
                }
            }
            .listStyle(.plain)
            .listRowSpacing(8)
            .listSectionSpacing(12)
            .scrollContentBackground(.hidden)
            .background(AppTheme.background)
            .scrollIndicators(showIndex ? .hidden : .automatic)
            .scrollDismissesKeyboard(.immediately)
            .overlay(alignment: .trailing) {
                if showIndex {
                    SectionIndexView(
                        sections: viewModel.groupedCards,
                        proxy: proxy
                    )
                    .padding(.trailing, 0)
                }
            }
            .frame(maxWidth: AppTheme.cardListMaximumWidth)
            .frame(maxWidth: .infinity)
            .animation(
                reduceMotion ? nil : .snappy(duration: 0.32, extraBounce: 0.03),
                value: visibleCardTransitionIDs
            )
        }
    }

    // MARK: - フィルター・ソート

    /// Insights から遷移した条件だけは、現在の一覧条件を見失わないよう検索欄直下に明示する。
    private func activeExternalFilterBar(_ externalFilter: CardListExternalFilter) -> some View {
        HStack(spacing: AppTheme.Spacing.small) {
            Image(systemName: "line.3.horizontal.decrease.circle.fill")
                .foregroundStyle(AppTheme.brandOrange)
            Text("絞り込み中：\(externalFilter.displayTitle)")
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
            Spacer(minLength: AppTheme.Spacing.small)
            Button {
                haptic.impactOccurred()
                navigationState.externalFilter = nil
                viewModel.clearExternalFilter()
            } label: {
                Image(systemName: "xmark")
                    .font(.caption.weight(.bold))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("絞り込みを解除")
        }
        .padding(.horizontal, AppTheme.Spacing.large)
        .frame(minHeight: 40)
        .background(AppTheme.contentSurface, in: .capsule)
        .accessibilityIdentifier("activeExternalFilter")
    }

    private var sortFilterMenu: some View {
        NativeSortFilterMenuButton(
            sortKey: viewModel.sortKey,
            sortAscending: viewModel.sortAscending,
            showFavoritesOnly: viewModel.showFavoritesOnly,
            tags: viewModel.allTags.compactMap { tag in
                guard let id = tag.id else { return nil }
                return NativeSortFilterMenuButton.TagOption(id: id, name: tag.tagName)
            },
            selectedTagIDs: viewModel.selectedTagIDs,
            externalFilterTitle: viewModel.externalFilter?.displayTitle,
            isFilterActive: viewModel.isFilterActive,
            accessibilityValue: sortFilterAccessibilityValue,
            onSelectSort: { key in
                haptic.impactOccurred()
                viewModel.toggleSort(key: key)
            },
            onSelectAllCards: resetFilters,
            onSetFavorites: { isEnabled in
                haptic.impactOccurred()
                viewModel.setFavoritesFilter(isEnabled)
            },
            onSetTag: { tagID, isEnabled in
                guard let tag = viewModel.allTags.first(where: { $0.id == tagID }) else { return }
                haptic.impactOccurred()
                viewModel.setTagFilter(tag, enabled: isEnabled)
            },
            onClearExternalFilter: {
                haptic.impactOccurred()
                navigationState.externalFilter = nil
                viewModel.clearExternalFilter()
            },
            onResetFilters: resetFilters
        )
        .frame(width: 44, height: 44)
    }

    private var activeFilterCount: Int {
        viewModel.selectedTagIDs.count
            + (viewModel.showFavoritesOnly ? 1 : 0)
            + (viewModel.externalFilter == nil ? 0 : 1)
    }

    private var sortFilterAccessibilityValue: String {
        let direction = viewModel.sortAscending ? "昇順" : "降順"
        guard activeFilterCount > 0 else {
            return "\(viewModel.sortKey.rawValue)・\(direction)・フィルターなし"
        }
        return "\(viewModel.sortKey.rawValue)・\(direction)・フィルター\(activeFilterCount)件"
    }

    private func resetFilters() {
        guard viewModel.isFilterActive else { return }
        haptic.impactOccurred()
        navigationState.externalFilter = nil
        viewModel.clearAllFilters()
    }

    // MARK: - カード行（コンテキストメニュー付き）

    @ViewBuilder
    private func cardRow(for card: BusinessCard) -> some View {
        if editMode == .inactive {
            Button {
                guard !isContextMenuPresented, Date() >= suppressCardTapUntil else { return }
                haptic.impactOccurred(intensity: 0.55)
                if usesSplitView {
                    navigationState.selectedCardForSplit = card
                } else {
                    navigationState.pushCardsRoute(.detail(card.objectID.uriRepresentation()))
                }
            } label: {
                CardRowView(
                    card: card,
                    compact: usesSplitView,
                    isSelected: usesSplitView && navigationState.selectedCardForSplit?.objectID == card.objectID
                )
            }
            .buttonStyle(CardRowButtonStyle())
            .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .accessibilityIdentifier("cardRow_\(card.fullName)")
            .accessibilityHint("詳細を表示")
            .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
            .swipeActions(edge: .leading) {
                Button {
                    haptic.impactOccurred()
                    viewModel.toggleFavorite(card)
                } label: {
                    Label(
                        card.isFavorite ? "解除" : "お気に入り",
                        systemImage: card.isFavorite ? "star.slash" : "star.fill"
                    )
                }
                .tint(.yellow)
            }
            .contextMenu {
                cardContextMenu(for: card)
            } preview: {
                CardPeekView(card: card)
                    .onAppear {
                        isContextMenuPresented = true
                    }
                    .onDisappear {
                        isContextMenuPresented = false
                        // dismissalに使った背面タップが次の行へ伝播する期間だけ無効化する。
                        suppressCardTapUntil = Date().addingTimeInterval(0.35)
                    }
            }
        } else {
            CardRowView(card: card, compact: usesSplitView)
                .accessibilityIdentifier("cardRow_\(card.fullName)")
                .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
        }
    }

    /// 一覧の並び替え・絞り込み・追加削除を安定IDでアニメーションさせる。
    private var visibleCardTransitionIDs: [String] {
        if viewModel.isSearchActive {
            return viewModel.filteredCards.map(transitionID(for:))
        }
        return viewModel.groupedCards
            .flatMap(\.cards)
            .map(transitionID(for:))
    }

    private func transitionID(for card: BusinessCard) -> String {
        card.id?.uuidString ?? card.objectID.uriRepresentation().absoluteString
    }

    // MARK: - コンテキストメニュー

    @ViewBuilder
    private func cardContextMenu(for card: BusinessCard) -> some View {
        Button {
            haptic.impactOccurred()
            viewModel.toggleFavorite(card)
        } label: {
            Label(
                card.isFavorite ? "お気に入り解除" : "お気に入りに追加",
                systemImage: card.isFavorite ? "star.slash" : "star.fill"
            )
        }
        .tint(Color.primary)

        Button {
            cardToEdit = card
        } label: {
            Label("編集", systemImage: "pencil")
        }
        .tint(Color.primary)

        Button {
            viewModel.shareVCard(card: card)
        } label: {
            Label("vCardとして共有", systemImage: "square.and.arrow.up")
        }
        .tint(Color.primary)

        Button {
            viewModel.saveToContacts(card: card)
        } label: {
            Label("連絡先に保存", systemImage: "person.crop.circle.badge.plus")
        }
        .tint(Color.primary)

        Divider()

        Button(role: .destructive) {
            cardToDelete = card
            isShowingDeleteConfirm = true
        } label: {
            Label("削除", systemImage: "trash")
        }
    }

    // MARK: - AI検索UI

    /// 通常検索が0件になった段階から、検索確定後のAI検索までを同じ場所で案内する。
    private var searchEmptyState: some View {
        Group {
            if viewModel.isSemanticSearchInProgress {
                ContentUnavailableView {
                    VStack(spacing: AppTheme.Spacing.medium) {
                        ProgressView()
                            .controlSize(.large)
                        Text("AIで検索中")
                            .font(.headline)
                    }
                } description: {
                    Text("名前・会社・部署・役職・住所・タグから、条件に合う名刺を探しています。")
                }
            } else if let message = viewModel.semanticSearchMessage {
                ContentUnavailableView {
                    Label("AI検索でも見つかりませんでした", systemImage: "sparkles")
                } description: {
                    Text(message)
                } actions: {
                    clearSearchButton
                }
            } else {
                ContentUnavailableView {
                    Label(
                        entitlementStore.hasAccess ? "AIで名刺を検索" : "AI検索を利用できます",
                        systemImage: "sparkles"
                    )
                } description: {
                    if entitlementStore.hasAccess {
                        Text("キーボードの「検索」を押すと、「\(viewModel.searchText)」に合う名刺を内容から探します。")
                    } else {
                        Text("キーボードの「検索」を押すと、Pro機能のAI検索をご案内します。")
                    }
                } actions: {
                    clearSearchButton
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var clearSearchButton: some View {
        Button("検索を消去") {
            viewModel.searchText = ""
        }
        .buttonStyle(.bordered)
    }

    /// フィルターで0件になった場合に、空白画面ではなく解除手段を示す。
    private var filterEmptyState: some View {
        ContentUnavailableView {
            Label("条件に一致する名刺がありません", systemImage: "line.3.horizontal.decrease.circle")
        } description: {
            Text("別の条件を選ぶか、フィルターをリセットしてください。")
        } actions: {
            Button("フィルターをリセット", action: resetFilters)
                .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - 空状態

    private var emptyState: some View {
        ContentUnavailableView(
            "名刺がありません",
            systemImage: "person.crop.rectangle.stack",
            description: Text("画面下部右端の追加から、名刺を撮影または読み込めます。")
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("名刺がありません")
    }

}

// CardRowView、一覧操作部品は Views/Components/ に定義
// ShareSheet、ExportItem は Utilities/ に定義
