import SwiftUI
import UIKit

// 名刺一覧画面
struct CardListView: View {

    @StateObject private var viewModel = CardListViewModel()
    @State private var isShowingForm = false
    @State private var batchImages: [UIImage] = []
    @State private var isReviewingBatch = false
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
    @State private var isShowingAIChat = false

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
                } else if viewModel.isSearchActive && viewModel.filteredCards.isEmpty
                    && !viewModel.searchText.trimmingCharacters(in: .whitespaces).isEmpty {
                    // テキスト検索で0件 → AI チャット検索を提案
                    aiSearchPrompt
                } else {
                    cardList
                }
            }
            .navigationTitle(selectionTitle)
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $viewModel.searchText, prompt: "検索")
            .background {
                SearchBarSparklesInjector(searchText: viewModel.searchText) {
                    isShowingAIChat = true
                }
                .frame(width: 0, height: 0)
                .allowsHitTesting(false)
            }
            .onSubmit(of: .search) {
                if viewModel.filteredCards.isEmpty && !viewModel.searchText.trimmingCharacters(in: .whitespaces).isEmpty {
                    isShowingAIChat = true
                }
            }
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
            // カメラは CameraBatchCapture（UIKit直接管理）で表示。fullScreenCover 不使用。
            .sheet(isPresented: $isReviewingBatch, onDismiss: {
                batchImages = []
                viewModel.fetchCards()
            }) {
                BatchReviewView(images: $batchImages, onComplete: {
                    isReviewingBatch = false
                })
                .environmentObject(viewModel)
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
            .sheet(isPresented: $isShowingAIChat) {
                AISearchChatView()
                    .environmentObject(viewModel)
            }
        }
        .environmentObject(viewModel)
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
        // 右上: 選択ボタン（HIG: テキストラベルとシンボルは別グループに分離）
        ToolbarItem(placement: .topBarTrailing) {
            if !viewModel.cards.isEmpty {
                Button("選択") {
                    editMode = .active
                    selectedCardIDs = []
                }
                .accessibilityIdentifier("selectButton")
            }
        }

        // 右上: 3点メニュー
        ToolbarItem(placement: .topBarTrailing) {
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
                if !viewModel.cards.isEmpty {
                    NavigationLink {
                        InsightsView()
                    } label: {
                        Label("インサイト", systemImage: "chart.bar")
                    }
                }
                Divider()
                Button { isShowingSettings = true } label: {
                    Label("設定", systemImage: "gearshape")
                }
            } label: {
                Label("メニュー", systemImage: "ellipsis")
            }
            .accessibilityIdentifier("ellipsisMenu")
        }

        // 左: 検索バー（システム提供・Liquid Glass自動適用）
        DefaultToolbarItem(kind: .search, placement: .bottomBar)

        // 中央: スペーサー
        ToolbarSpacer(.flexible, placement: .bottomBar)

        // 右: 追加ボタン
        ToolbarItem(placement: .bottomBar) {
            Button {
                CameraBatchCapture.shared.start { images in
                    batchImages = images
                    if !images.isEmpty {
                        // batchImages の更新を SwiftUI に反映させてから sheet を表示する
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                            isReviewingBatch = true
                        }
                    }
                }
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

        // 右上: 完了ボタン（HIG: Done は trailing + .prominent）
        ToolbarItem(placement: .topBarTrailing) {
            Button("完了") {
                editMode = .inactive
                selectedCardIDs = []
            }
            .fontWeight(.semibold)
            .accessibilityIdentifier("doneButton")
        }

        // 下部: 一括操作（左: 削除 / 中央: タグ＋お気に入り / 右: エクスポート）
        ToolbarItemGroup(placement: .bottomBar) {
            // 削除
            Button {
                isShowingBulkDeleteConfirm = true
            } label: {
                Label("削除", systemImage: "trash")
            }
            .disabled(selectedCardIDs.isEmpty)
            .accessibilityIdentifier("bulkDeleteButton")

            Spacer()

            // タグ
            Button {
                isShowingBulkTagSheet = true
            } label: {
                Label("タグ", systemImage: "tag")
            }
            .disabled(selectedCardIDs.isEmpty)

            // お気に入り
            Button {
                haptic.impactOccurred()
                viewModel.toggleBulkFavorite(ids: selectedCardIDs)
            } label: {
                Label("お気に入り", systemImage: "star")
            }
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
                                .fontWeight(.semibold)
                                .foregroundStyle(.secondary)
                                .textCase(nil)
                        }
                        .id(section.id)
                    }
                }
            }
            .listStyle(.plain)
            .scrollIndicators(showIndex ? .hidden : .automatic)
            .scrollDismissesKeyboard(.immediately)
            .safeAreaInset(edge: .top) {
                if editMode == .inactive {
                    filterSortBar
                }
            }
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

    // MARK: - フィルター・ソート統合バー

    private var filterSortBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                // ── 並び替え ──
                Menu {
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
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: viewModel.sortAscending ? "arrow.up" : "arrow.down")
                            .font(.footnote)
                        Text(viewModel.sortKey.rawValue)
                            .font(.footnote)
                    }
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 12)
                    .frame(minHeight: 32)
                    .background(Color(.secondarySystemFill))
                    .clipShape(Capsule())
                }

                // ── 区切り + フィルタアイコン ──
                HStack(spacing: 6) {
                    Divider()
                        .frame(height: 20)
                    Image(systemName: "line.3.horizontal.decrease")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("絞り込み")
                }

                // ── お気に入りフィルタ ──
                Button { viewModel.toggleFavoritesFilter() } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "star.fill")
                            .font(.caption)
                        Text("お気に入り")
                            .font(.footnote)
                    }
                    .padding(.horizontal, 12)
                    .frame(minHeight: 32)
                    .background(viewModel.showFavoritesOnly ? Color.yellow.opacity(0.2) : Color(.secondarySystemFill))
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("お気に入りフィルタ")
                .accessibilityAddTraits(viewModel.showFavoritesOnly ? .isSelected : [])

                // ── タグフィルタ ──
                ForEach(viewModel.allTags) { tag in
                    let isSelected = viewModel.selectedTagIDs.contains(tag.id ?? UUID())
                    Button { viewModel.toggleTagFilter(tag) } label: {
                        HStack(spacing: 5) {
                            Circle()
                                .fill(tag.color)
                                .frame(width: 8, height: 8)
                            Text(tag.tagName)
                                .font(.footnote)
                        }
                        .padding(.horizontal, 12)
                        .frame(minHeight: 32)
                        .background(isSelected ? tag.color.opacity(0.2) : Color(.secondarySystemFill))
                        .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("タグフィルタ: \(tag.tagName)")
                    .accessibilityAddTraits(isSelected ? .isSelected : [])
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
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

    // MARK: - AI検索UI

    /// テキスト検索で0件時に表示する AI チャット検索提案
    private var aiSearchPrompt: some View {
        VStack(spacing: 12) {
            Button {
                isShowingAIChat = true
            } label: {
                Label("AI検索で探す", systemImage: "sparkles")
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(.tint.opacity(0.1))
                    .clipShape(Capsule())
            }
            .padding(.top, 12)

            Text("AIチャットで自然言語検索できます")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.bottom, 8)
    }

    // MARK: - 空状態

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "tray")
                .font(.system(size: 48))
                .foregroundStyle(.tertiary)
            Text("名刺がありません")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("名刺がありません")
    }

}

// CardRowView, SectionIndexView は Views/Components/ に定義
// ShareSheet, ExportItem は Utilities/ に定義

// MARK: - 検索バー内 sparkles ボタン

/// UISearchBar の searchTextField.rightView に sparkles ボタンを配置する
/// searchText を受け取ることで、検索アクティブ化時に updateUIView が呼ばれる
private struct SearchBarSparklesInjector: UIViewRepresentable {
    var searchText: String
    let onTap: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onTap: onTap) }

    func makeUIView(context: Context) -> UIView {
        let v = UIView()
        retryInject(from: v, coordinator: context.coordinator, attempts: 20)
        return v
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.onTap = onTap
        retryInject(from: uiView, coordinator: context.coordinator, attempts: 20)
    }

    private func retryInject(from view: UIView, coordinator: Coordinator, attempts: Int) {
        guard attempts > 0 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            if self.inject(from: view, coordinator: coordinator) { return }
            self.retryInject(from: view, coordinator: coordinator, attempts: attempts - 1)
        }
    }

    @discardableResult
    private func inject(from view: UIView, coordinator: Coordinator) -> Bool {
        guard let window = view.window else { return false }

        if let searchBar = Self.findSearchBar(in: window) {
            let tf = searchBar.searchTextField
            if let rv = tf.rightView, rv.tag == 8888 { return true }
            tf.rightView = Self.makeButton(coordinator: coordinator)
            tf.rightViewMode = .always
            return true
        }

        if let tf = Self.findSearchTextField(in: window) {
            if let rv = tf.rightView, rv.tag == 8888 { return true }
            tf.rightView = Self.makeButton(coordinator: coordinator)
            tf.rightViewMode = .always
            return true
        }

        return false
    }

    private static func makeButton(coordinator: Coordinator) -> UIButton {
        let btn = UIButton(type: .system)
        let cfg = UIImage.SymbolConfiguration(pointSize: 15, weight: .medium)
        btn.setImage(UIImage(systemName: "sparkles", withConfiguration: cfg), for: .normal)
        btn.tintColor = UIColor.tintColor
        btn.tag = 8888
        btn.frame = CGRect(x: 0, y: 0, width: 28, height: 28)
        btn.addTarget(coordinator, action: #selector(Coordinator.tapped), for: .touchUpInside)
        return btn
    }

    private static func findSearchBar(in view: UIView) -> UISearchBar? {
        if let sb = view as? UISearchBar { return sb }
        for child in view.subviews {
            if let found = findSearchBar(in: child) { return found }
        }
        return nil
    }

    private static func findSearchTextField(in view: UIView) -> UISearchTextField? {
        if let tf = view as? UISearchTextField { return tf }
        for child in view.subviews {
            if let found = findSearchTextField(in: child) { return found }
        }
        return nil
    }

    final class Coordinator: NSObject {
        var onTap: () -> Void
        init(onTap: @escaping () -> Void) { self.onTap = onTap }
        @objc func tapped() { onTap() }
    }
}
