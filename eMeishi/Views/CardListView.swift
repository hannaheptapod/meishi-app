import SwiftUI
import UIKit

// 名刺一覧画面
struct CardListView: View {

    @StateObject private var viewModel = CardListViewModel()
    @State private var isShowingForm = false
    @State private var isShowingCamera = false
    @State private var capturedImage: UIImage? = nil
    @State private var isShowingSettings = false
    @State private var isShowingImportConfirm = false
    @State private var isShowingTagManager = false

    // コンテキストメニュー用
    @State private var cardToEdit: BusinessCard? = nil
    @State private var cardToDelete: BusinessCard? = nil
    @State private var isShowingDeleteConfirm = false

    // 選択モード用
    @State private var editMode: EditMode = .inactive
    @State private var selectedCardIDs: Set<BusinessCard.ID> = []
    @State private var isShowingBulkDeleteConfirm = false
    @State private var isShowingBulkTagSheet = false

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
        NavigationStack {
            Group {
                if viewModel.cards.isEmpty {
                    emptyState
                } else {
                    cardList
                }
            }
            .navigationTitle(navigationTitleText)
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $viewModel.searchText, placement: .toolbar, prompt: "検索")
            .toolbar {
                if editMode == .active {
                    selectionToolbarContent
                } else {
                    normalToolbarContent
                }
            }
            .environment(\.editMode, $editMode)
            .sheet(isPresented: $isShowingForm, onDismiss: viewModel.fetchCards) {
                CardFormView(onSave: { isShowingForm = false })
            }
            .fullScreenCover(isPresented: $isShowingCamera) {
                CameraView(capturedImage: $capturedImage)
                    .ignoresSafeArea()
            }
            .sheet(item: $capturedImage, onDismiss: viewModel.fetchCards) { image in
                CardFormView(image: image, onSave: { capturedImage = nil })
            }
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
            .sheet(isPresented: $isShowingSettings) {
                SettingsView()
                    .environmentObject(viewModel)
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
            // コンテキストメニューからの編集シート
            .sheet(item: $cardToEdit, onDismiss: viewModel.fetchCards) { card in
                CardFormView(card: card, onSave: { cardToEdit = nil })
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
            }
            .onAppear(perform: viewModel.fetchCards)
        }
        .environmentObject(viewModel)
    }

    // MARK: - ナビゲーションタイトル

    /// フィルタ適用中は件数を表示
    private var navigationTitleText: String {
        if viewModel.isFilterActive || viewModel.isSearchActive {
            return "名刺（\(viewModel.filteredCards.count)件）"
        }
        return "名刺"
    }

    // MARK: - 通常モードのツールバー

    @ToolbarContentBuilder
    private var normalToolbarContent: some ToolbarContent {
        // 右上: 選択ボタン＋3点メニュー（HIG: Edit/Selectは trailing に配置）
        ToolbarItemGroup(placement: .topBarTrailing) {
            if !viewModel.cards.isEmpty {
                Button("選択") {
                    editMode = .active
                    selectedCardIDs = []
                }
                .accessibilityIdentifier("selectButton")
            }

            Menu {
                if !viewModel.cards.isEmpty {
                    NavigationLink {
                        DuplicateListView(pairs: viewModel.duplicatePairs, onMerge: viewModel.fetchCards)
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
                Divider()
                Button { isShowingSettings = true } label: {
                    Label("設定", systemImage: "gearshape")
                }
            } label: {
                Label("メニュー", systemImage: "ellipsis")
            }
            .accessibilityIdentifier("ellipsisMenu")
        }  // end ToolbarItemGroup

        // 左: 並び替え・フィルタ統合メニュー
        ToolbarItem(placement: .bottomBar) {
            Menu {
                // ── フィルタ ──
                Section("フィルタ") {
                    Button { viewModel.toggleFavoritesFilter() } label: {
                        Label("お気に入りのみ", systemImage: viewModel.showFavoritesOnly ? "checkmark.circle.fill" : "circle")
                    }
                    .menuActionDismissBehavior(.disabled)
                    if !viewModel.allTags.isEmpty {
                        ForEach(viewModel.allTags) { tag in
                            Button { viewModel.toggleTagFilter(tag) } label: {
                                Label(tag.tagName, systemImage: viewModel.selectedTagIDs.contains(tag.id ?? UUID()) ? "checkmark.circle.fill" : "circle")
                            }
                            .menuActionDismissBehavior(.disabled)
                        }
                    }
                }

                // ── 並び替え ──
                Section("並び替え") {
                    ForEach(CardSortKey.allCases) { key in
                        Button { viewModel.toggleSort(key: key) } label: {
                            if viewModel.sortKey == key {
                                Label(key.rawValue, systemImage: viewModel.sortAscending ? "arrow.up" : "arrow.down")
                            } else {
                                Text(key.rawValue)
                            }
                        }
                        .menuActionDismissBehavior(.disabled)
                    }
                }
            } label: {
                Label(
                    "並び替え・フィルタ",
                    systemImage: viewModel.isFilterActive
                        ? "line.3.horizontal.decrease.circle.fill"
                        : "line.3.horizontal.decrease.circle"
                )
            }
        }

        // 中央: 検索バー（システム提供・Liquid Glass自動適用）
        ToolbarSpacer(.flexible, placement: .bottomBar)
        DefaultToolbarItem(kind: .search, placement: .bottomBar)
        ToolbarSpacer(.flexible, placement: .bottomBar)

        // 右: 追加ボタン
        ToolbarItem(placement: .bottomBar) {
            Button {
                isShowingCamera = true
            } label: {
                Label("追加", systemImage: "plus")
            }
            .accessibilityIdentifier("addButton")
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
            .accessibilityIdentifier("selectAllButton")
        }

        // 右上: 完了ボタン（HIG: Edit/Done は trailing でトグル）
        ToolbarItem(placement: .topBarTrailing) {
            Button("完了") {
                editMode = .inactive
                selectedCardIDs = []
            }
            .accessibilityIdentifier("doneButton")
        }

        // 下部: 一括操作
        ToolbarItemGroup(placement: .bottomBar) {
            // 一括削除
            Button {
                isShowingBulkDeleteConfirm = true
            } label: {
                Label("削除", systemImage: "trash")
            }
            .disabled(selectedCardIDs.isEmpty)
            .accessibilityIdentifier("bulkDeleteButton")

            Spacer()

            // 選択件数 or ガイドテキスト
            if selectedCardIDs.isEmpty {
                Text("名刺をタップして選択")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("selectionGuideText")
            } else {
                Text("\(selectedCardIDs.count)件選択中")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("selectionCountText")
            }

            Spacer()

            // その他アクション
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
                if !viewModel.allTags.isEmpty {
                    Divider()
                    Button {
                        isShowingBulkTagSheet = true
                    } label: {
                        Label("タグを付ける", systemImage: "tag")
                    }
                }
            } label: {
                Label("その他", systemImage: "ellipsis.circle")
            }
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
                        viewModel.deleteCards(offsets.map { viewModel.filteredCards[$0] })
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
                                viewModel.deleteCards(offsets.map { section.cards[$0] })
                            }
                            .deleteDisabled(editMode == .active)
                        } header: {
                            Text(section.title)
                                .font(.subheadline)
                                .fontWeight(.bold)
                                .foregroundStyle(.primary)
                                .textCase(nil)
                        }
                        .id(section.id)
                    }
                }
            }
            .listStyle(.plain)
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
        }
    }

    // MARK: - カード行（コンテキストメニュー付き）

    @ViewBuilder
    private func cardRow(for card: BusinessCard) -> some View {
        if editMode == .inactive {
            NavigationLink {
                CardDetailView(card: card)
            } label: {
                CardRowView(card: card)
            }
            .accessibilityIdentifier("cardRow_\(card.fullName)")
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
                CardDetailView(card: card)
                    .environmentObject(viewModel)
            }
        } else {
            CardRowView(card: card)
                .accessibilityIdentifier("cardRow_\(card.fullName)")
        }
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

        Button {
            cardToEdit = card
        } label: {
            Label("編集", systemImage: "pencil")
        }

        Button {
            viewModel.shareVCard(card: card)
        } label: {
            Label("vCardとして共有", systemImage: "square.and.arrow.up")
        }

        Button {
            viewModel.saveToContacts(card: card)
        } label: {
            Label("連絡先に保存", systemImage: "person.crop.circle.badge.plus")
        }

        Divider()

        Button(role: .destructive) {
            cardToDelete = card
            isShowingDeleteConfirm = true
        } label: {
            Label("削除", systemImage: "trash")
        }
    }

    // MARK: - 空状態

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "rectangle.portrait.on.rectangle.portrait.slash")
                .font(.system(size: 60))
                .foregroundColor(.secondary)
            Text("名刺がありません")
                .font(.title3)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("名刺がありません")
    }

}

// CardRowView, SectionIndexView は Views/Components/ に定義
// ShareSheet, ExportItem は Utilities/ に定義

extension UIImage: @retroactive Identifiable {
    public var id: ObjectIdentifier { ObjectIdentifier(self) }
}
