import PhotosUI
import SwiftUI
import UIKit

// 名刺一覧画面
struct CardListView: View {

    @EnvironmentObject private var viewModel: CardListViewModel
    @EnvironmentObject private var navigationState: AppNavigationState
    @State private var isShowingForm = false
    @State private var batchImages: [UIImage] = []
    @State private var isReviewingBatch = false
    @State private var isShowingAddSheet = false
    @State private var isShowingImportConfirm = false
    @State private var isShowingTagManager = false
    @State private var isShowingPhotoPicker = false
    @State private var selectedPhotoItems: [PhotosPickerItem] = []
    @State private var isImportingPhotos = false
    @State private var photoImportMessage: String?
    @State private var isShowingPendingOCRPrompt = false
    @State private var pendingOCRImages: [UIImage] = []
    @State private var cardForDetail: BusinessCard?
    @State private var isShowingSortPopover = false
    @State private var isContextMenuPresented = false
    @State private var suppressCardTapUntil = Date.distantPast

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
    @State private var isShowingPaywall = false
    // スクリーンショット撮影モード用：CardFormView を OCR 完了状態のモックで開く
    @State private var isShowingMockOCRForm = false

    @EnvironmentObject private var entitlementStore: EntitlementStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    // 触覚フィードバック
    private let haptic = UIImpactFeedbackGenerator(style: .light)

    /// 選択モード時のみ選択を受け付けるバインディング
    private var selectionBinding: Binding<Set<BusinessCard.ID>> {
        Binding(
            get: { editMode == .active ? selectedCardIDs : [] },
            set: { if editMode == .active { selectedCardIDs = $0 } }
        )
    }

    private var screenBackground: Color {
        AppTheme.background
    }

    var body: some View {
        interactionPresentations
    }

    private var baseView: AnyView {
        AnyView(
        Group {
            if viewModel.cards.isEmpty {
                emptyState
            } else if shouldShowAISearchPrompt {
                // テキスト検索で0件 → AI チャット検索を提案
                aiSearchPrompt
            } else {
                cardList
            }
        }
            .navigationTitle(editMode == .active ? selectionTitle : "名刺")
            .navigationBarTitleDisplayMode(editMode == .active ? .inline : .automatic)
            .searchable(
                text: $viewModel.searchText,
                placement: .navigationBarDrawer(displayMode: .always),
                prompt: "名前・会社・連絡先を検索"
            )
            .background {
                SearchBarSparklesInjector(searchText: viewModel.searchText) {
                    openAISearch()
                }
                .frame(width: 0, height: 0)
                .allowsHitTesting(false)
            }
            .onSubmit(of: .search) {
                if viewModel.filteredCards.isEmpty && !viewModel.searchText.trimmingCharacters(in: .whitespaces).isEmpty {
                    openAISearch()
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
            .navigationDestination(item: $cardForDetail) { card in
                CardDetailView(card: card)
            }
        .background(screenBackground.ignoresSafeArea())
        )
    }

    private var importPresentations: AnyView {
        AnyView(
            baseView
            .sheet(isPresented: $isShowingForm, onDismiss: viewModel.fetchCards) {
                CardFormView(onSave: { isShowingForm = false })
            }
            .sheet(isPresented: $isShowingAddSheet) {
                AddCardSheet(
                    pendingCount: pendingOCRImages.count,
                    isImporting: isImportingPhotos,
                    onCamera: {
                        isShowingAddSheet = false
                        startCameraCapture()
                    },
                    onPhotos: {
                        isShowingAddSheet = false
                        selectedPhotoItems = []
                        isShowingPhotoPicker = true
                    },
                    onManual: {
                        isShowingAddSheet = false
                        isShowingForm = true
                    },
                    onResume: pendingOCRImages.isEmpty ? nil : {
                        isShowingAddSheet = false
                        batchImages = pendingOCRImages
                        isReviewingBatch = !batchImages.isEmpty
                    }
                )
                .presentationDetents([.medium])
                .presentationDragIndicator(.visible)
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
            .photosPicker(
                isPresented: $isShowingPhotoPicker,
                selection: $selectedPhotoItems,
                maxSelectionCount: 10,
                selectionBehavior: .ordered,
                matching: .images,
                preferredItemEncoding: .compatible
            )
            .onChange(of: selectedPhotoItems) { _, items in
                handlePhotoSelection(items)
            }
            .alert("写真の読込み", isPresented: Binding(
                get: { photoImportMessage != nil },
                set: { if !$0 { photoImportMessage = nil } }
            )) {
                Button("OK", role: .cancel) { photoImportMessage = nil }
            } message: {
                Text(photoImportMessage ?? "")
            }
            .alert("未完了の読み取り", isPresented: $isShowingPendingOCRPrompt) {
                Button("再開") {
                    batchImages = pendingOCRImages
                    isReviewingBatch = !batchImages.isEmpty
                }
                Button("破棄", role: .destructive) {
                    pendingOCRImages = []
                    Task { await discardPendingOCR() }
                }
            } message: {
                Text("前回中断した名刺が\(pendingOCRImages.count)枚あります。")
            }
        )
    }

    private var managementPresentations: AnyView {
        AnyView(
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
        )
    }

    private var interactionPresentations: AnyView {
        AnyView(
            managementPresentations
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
                .environmentObject(entitlementStore)
            }
            .onAppear {
                viewModel.fetchCards()
                viewModel.externalFilter = navigationState.externalFilter
                handleScreenshotMode()
            }
            .onChange(of: navigationState.externalFilter) { _, filter in
                viewModel.externalFilter = filter
            }
            .task {
                await loadPendingOCR()
            }
            .sheet(isPresented: $isShowingAIChat) {
                AISearchChatView()
                    .environmentObject(viewModel)
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
        )
    }

    private func openAISearch() {
        if entitlementStore.hasAccess {
            isShowingAIChat = true
        } else {
            isShowingPaywall = true
        }
    }

    private var shouldShowAISearchPrompt: Bool {
        viewModel.isSearchActive
            && viewModel.filteredCards.isEmpty
            && !viewModel.searchText.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// XCUITest（ScreenshotRunner）から START_SCREEN を受け取った場合、対応するシートを開く
    private func handleScreenshotMode() {
        guard ScreenshotMode.isActive, let screen = ScreenshotMode.startScreen else { return }
        switch screen {
        case "Tags":     isShowingTagManager = true
        case "AIChat":   isShowingAIChat = true
        case "FormOCR":  isShowingMockOCRForm = true
        case "Paywall":  isShowingPaywall = true
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
        ToolbarItem(placement: .topBarTrailing) {
            Button {
                isShowingAddSheet = true
            } label: {
                Label("名刺を追加", systemImage: "plus")
            }
            .disabled(isImportingPhotos)
            .accessibilityIdentifier("addButton")
        }

        ToolbarSpacer(.fixed, placement: .topBarTrailing)

        ToolbarItem(placement: .topBarTrailing) {
            if !viewModel.cards.isEmpty {
                Button("選択") {
                    editMode = .active
                    selectedCardIDs = []
                }
                .accessibilityIdentifier("selectButton")
            }
        }

        ToolbarSpacer(.fixed, placement: .topBarTrailing)

        // 右上: 3点メニュー
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                if !viewModel.cards.isEmpty {
                    NavigationLink {
                        DuplicateListView(pairs: $viewModel.duplicatePairs, onMerge: {
                            viewModel.fetchCards()
                            viewModel.detectDuplicates()
                        })
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
            } label: {
                Label("メニュー", systemImage: "ellipsis")
            }
            .accessibilityIdentifier("ellipsisMenu")
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
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                Text("\(section.cards.count)")
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(.tertiary)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(.quaternary, in: Capsule())
                            }
                            .textCase(nil)
                        }
                        .id(section.id)
                    }
                }
            }
            .listStyle(.plain)
            .listRowSpacing(8)
            .listSectionSpacing(12)
            .scrollContentBackground(.hidden)
            .background(screenBackground)
            .scrollEdgeEffectHidden(true, for: .vertical)
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
            .frame(maxWidth: AppTheme.cardListMaximumWidth)
            .frame(maxWidth: .infinity)
        }
    }

    private func startCameraCapture() {
        CameraBatchCapture.shared.start { images in
            batchImages = images
            if !images.isEmpty {
                Task {
                    let inputs = images.compactMap { image in
                        image.jpegData(compressionQuality: 0.82).map {
                            CardImageInput(data: $0, source: .camera)
                        }
                    }
                    do {
                        try await PendingOCRStore.shared.persist(inputs)
                    } catch {
                        photoImportMessage = "未完了の読み取り情報を保存できませんでした。アプリ終了後の再開はできませんが、このまま確認を続けられます。"
                    }
                    try? await Task.sleep(for: .seconds(0.1))
                    isReviewingBatch = true
                }
            }
        }
    }

    private func importSelectedPhotos(_ items: [PhotosPickerItem]) async {
        isImportingPhotos = true
        defer {
            isImportingPhotos = false
            selectedPhotoItems = []
        }

        let result = await PhotoImportService.shared.importImages(from: items)
        batchImages = result.images.compactMap { UIImage(data: $0.data) }

        if batchImages.isEmpty {
            let reason = result.failures.first?.reason.message ?? "画像を読み込めませんでした"
            photoImportMessage = "読込みに失敗しました。\(reason)。もう一度お試しください。"
            return
        }

        if !result.failures.isEmpty {
            photoImportMessage = "\(batchImages.count)枚を読み込み、\(result.failures.count)枚は読み込めませんでした。"
        }
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        do {
            try await PendingOCRStore.shared.persist(result.images)
        } catch {
            photoImportMessage = "未完了の読み取り情報を保存できませんでした。アプリ終了後の再開はできませんが、このまま確認を続けられます。"
        }
        isReviewingBatch = true
    }

    private func handlePhotoSelection(_ items: [PhotosPickerItem]) {
        guard !items.isEmpty else { return }
        Task { await importSelectedPhotos(items) }
    }

    private func loadPendingOCR() async {
        guard !ScreenshotMode.isActive else { return }
        do {
            let restored = try await PendingOCRStore.shared.restore()
            pendingOCRImages = restored.compactMap { UIImage(data: $0.data) }
            isShowingPendingOCRPrompt = !pendingOCRImages.isEmpty
        } catch {
            photoImportMessage = "前回の未完了読み取りを復元できませんでした。破損した一時データは設定を変えずに保持しています。"
        }
    }

    private func discardPendingOCR() async {
        do {
            try await PendingOCRStore.shared.discard()
        } catch {
            photoImportMessage = "未完了の読み取り情報を破棄できませんでした。"
        }
    }

    // MARK: - フィルター・ソート統合バー

    private var filterSortBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                // ── 並び替え ──
                Button {
                    isShowingSortPopover.toggle()
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
                    .background(AppTheme.brandOrange.opacity(0.14), in: .capsule)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("sortButton")
                .accessibilityValue("\(viewModel.sortKey.rawValue)・\(viewModel.sortAscending ? "昇順" : "降順")")
                .popover(
                    isPresented: $isShowingSortPopover,
                    attachmentAnchor: .rect(.bounds),
                    arrowEdge: .top
                ) {
                    VStack(spacing: 0) {
                        ForEach(CardSortKey.allCases) { key in
                            Button {
                                haptic.impactOccurred()
                                viewModel.toggleSort(key: key)
                            } label: {
                                HStack(spacing: 14) {
                                    Image(systemName: viewModel.sortAscending ? "arrow.up" : "arrow.down")
                                        .font(.body.weight(.medium))
                                        .opacity(viewModel.sortKey == key ? 1 : 0)
                                        .frame(width: 24, alignment: .center)
                                        .accessibilityIdentifier("sortDirection_\(key.rawValue)")
                                        .accessibilityHidden(viewModel.sortKey != key)

                                    Text(key.rawValue)
                                        .foregroundStyle(.primary)

                                    Spacer(minLength: 0)
                                }
                                .padding(.horizontal, 18)
                                .frame(width: 250, height: 44)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("sortOption_\(key.rawValue)")
                            .accessibilityValue(viewModel.sortKey == key
                                ? (viewModel.sortAscending ? "昇順" : "降順")
                                : "")
                        }
                    }
                    .padding(.vertical, 8)
                    .presentationCompactAdaptation(.popover)
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
                Button {
                    haptic.impactOccurred()
                    viewModel.toggleFavoritesFilter()
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "star.fill")
                            .font(.caption)
                        Text("お気に入り")
                            .font(.footnote)
                    }
                    .padding(.horizontal, 12)
                    .frame(minHeight: 32)
                    .background(
                        viewModel.showFavoritesOnly
                            ? AppTheme.brandOrange.opacity(0.14)
                            : AppTheme.auxiliarySurface,
                        in: .capsule
                    )
                }
                .buttonStyle(.plain)
                .accessibilityLabel("お気に入りフィルタ")
                .accessibilityAddTraits(viewModel.showFavoritesOnly ? .isSelected : [])

                // ── タグフィルタ ──
                ForEach(viewModel.allTags) { tag in
                    let isSelected = viewModel.selectedTagIDs.contains(tag.id ?? UUID())
                    Button {
                        haptic.impactOccurred()
                        viewModel.toggleTagFilter(tag)
                    } label: {
                        HStack(spacing: 5) {
                            Circle()
                                .fill(tag.color)
                                .frame(width: 8, height: 8)
                            Text(tag.tagName)
                                .font(.footnote)
                        }
                        .padding(.horizontal, 12)
                        .frame(minHeight: 32)
                        .background(
                            isSelected
                                ? tag.color.opacity(0.16)
                                : AppTheme.auxiliarySurface,
                            in: .capsule
                        )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("タグフィルタ: \(tag.tagName)")
                    .accessibilityAddTraits(isSelected ? .isSelected : [])
                }

                if let externalFilter = viewModel.externalFilter {
                    Button {
                        haptic.impactOccurred()
                        navigationState.externalFilter = nil
                        viewModel.clearExternalFilter()
                    } label: {
                        HStack(spacing: 5) {
                            Text(externalFilter.displayTitle)
                                .font(.footnote)
                            Image(systemName: "xmark")
                                .font(.caption2.weight(.semibold))
                        }
                        .padding(.horizontal, 12)
                        .frame(minHeight: 32)
                        .background(AppTheme.brandOrange.opacity(0.14), in: .capsule)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("外部フィルターを解除: \(externalFilter.displayTitle)")
                }
                }
                .padding(.horizontal)
                .padding(.vertical, 8)
                .animation(
                    reduceMotion ? nil : .snappy(duration: 0.22),
                    value: viewModel.showFavoritesOnly
                )
                .animation(
                    reduceMotion ? nil : .snappy(duration: 0.22),
                    value: viewModel.selectedTagIDs
                )
        }
    }

    // MARK: - カード行（コンテキストメニュー付き）

    @ViewBuilder
    private func cardRow(for card: BusinessCard) -> some View {
        if editMode == .inactive {
            CardRowView(card: card)
            .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .onTapGesture {
                guard !isContextMenuPresented, Date() >= suppressCardTapUntil else { return }
                haptic.impactOccurred(intensity: 0.55)
                cardForDetail = card
            }
            .accessibilityIdentifier("cardRow_\(card.fullName)")
            .accessibilityHint("詳細を表示")
            .accessibilityAddTraits(.isButton)
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
                CardDetailView(card: card)
                    .environmentObject(viewModel)
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
            CardRowView(card: card)
                .accessibilityIdentifier("cardRow_\(card.fullName)")
                .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
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
                openAISearch()
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
        ContentUnavailableView(
            "名刺がありません",
            systemImage: "person.crop.rectangle.stack",
            description: Text("右上の追加ボタンから、名刺を撮影または読み込めます。")
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("名刺がありません")
    }

}

// CardRowView, SectionIndexView は Views/Components/ に定義
// ShareSheet, ExportItem は Utilities/ に定義

private struct AddCardSheet: View {
    let pendingCount: Int
    let isImporting: Bool
    let onCamera: () -> Void
    let onPhotos: () -> Void
    let onManual: () -> Void
    let onResume: (() -> Void)?

    var body: some View {
        NavigationStack {
            VStack(spacing: AppTheme.Spacing.medium) {
                addAction(
                    title: "カメラで撮影",
                    detail: "名刺を撮影して文字を読み取ります",
                    systemImage: "camera",
                    action: onCamera
                )
                addAction(
                    title: "写真から読み込む",
                    detail: "写真ライブラリから最大10枚選べます",
                    systemImage: "photo.on.rectangle.angled",
                    action: onPhotos
                )
                addAction(
                    title: "手動で入力",
                    detail: "画像を使わずに名刺を登録します",
                    systemImage: "square.and.pencil",
                    action: onManual
                )
                if let onResume {
                    addAction(
                        title: "未完了の読み取りを再開",
                        detail: "\(pendingCount)枚の確認を続けます",
                        systemImage: "arrow.clockwise",
                        action: onResume
                    )
                }
                Spacer(minLength: 0)
            }
            .padding(AppTheme.Spacing.large)
            .background(AppTheme.background.ignoresSafeArea())
            .navigationTitle("名刺を追加")
            .navigationBarTitleDisplayMode(.inline)
        }
        .disabled(isImporting)
    }

    private func addAction(
        title: String,
        detail: String,
        systemImage: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            ContentSurface {
                HStack(spacing: AppTheme.Spacing.medium) {
                    Image(systemName: systemImage)
                        .font(.title3)
                        .foregroundStyle(AppTheme.brandOrange)
                        .frame(width: 32)
                    VStack(alignment: .leading, spacing: AppTheme.Spacing.xSmall) {
                        Text(title)
                            .font(.headline)
                            .foregroundStyle(.primary)
                        Text(detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
            }
        }
        .buttonStyle(.plain)
    }
}

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
        Task {
            try? await Task.sleep(for: .seconds(0.15))
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
