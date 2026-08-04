import SwiftUI
import UIKit

nonisolated private enum CardListContextMenuAction: Equatable, Sendable {
    case toggleFavorite(objectURI: URL)
    case edit(objectURI: URL)
    case shareVCard(objectURI: URL)
    case saveToContacts(objectURI: URL)
    case delete(objectURI: URL)
}

nonisolated private enum CardListConfirmationCommit: Equatable, Sendable {
    case importContacts
    case deleteCard(objectURI: URL)
    case bulkDelete(cardURIs: Set<URL>)
}

// 名刺一覧画面
struct CardListView: View {
    /// regular幅のSplit Viewでだけ、一覧行とツールバーを狭いsidebar向けに調整する。
    /// 遷移方式とは分離し、幅変更時にCardListView自体を作り直さない。
    var usesSidebarLayout = false

    @EnvironmentObject private var viewModel: CardListViewModel
    @EnvironmentObject private var navigationState: AppNavigationState
    @State private var presentationState = CardListPresentationState()
    @State private var confirmationCommitState = DismissalCommitState<CardListConfirmationCommit>()
    @StateObject private var contextMenuInteractionGate = ContextMenuInteractionGate<CardListContextMenuAction>()
    @State private var didPrepareInitialAppearance = false
    @State private var refreshAfterSheetDismissal = false
    @State private var isCaptureDetailSelectionPending = false
    @State private var confirmationCommitTask: Task<Void, Never>?
    @State private var viewLifetimeID = UUID()

    // 選択モード用
    @State private var editMode: EditMode = .inactive
    @State private var selectedCardIDs: Set<URL> = []

    @EnvironmentObject private var entitlementStore: EntitlementStore
    // 触覚フィードバック
    private let haptic = UIImpactFeedbackGenerator(style: .light)

    /// 選択モード時のみ選択を受け付けるバインディング
    private var selectionBinding: Binding<Set<URL>> {
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
            if !viewModel.isListDisplayReady {
                ProgressView("名刺を読み込んでいます")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if !viewModel.hasDisplayedCards {
                emptyState
            } else if viewModel.filteredCardItems.isEmpty && viewModel.isDisplayedSearchActive {
                searchEmptyState
            } else if viewModel.filteredCardItems.isEmpty && viewModel.isDisplayedFilterActive {
                filterEmptyState
            } else {
                cardList
            }
        }
            .navigationTitle(editMode == .active ? selectionTitle : "名刺")
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaBar(edge: .top, spacing: 0) {
                if let externalFilter = viewModel.displayedExternalFilter,
                   editMode == .inactive {
                    activeExternalFilterBar(externalFilter)
                        .frame(maxWidth: AppTheme.cardListMaximumWidth)
                        .padding(.horizontal, AppTheme.Spacing.large)
                        .padding(.top, AppTheme.Spacing.small)
                        .padding(.bottom, AppTheme.Spacing.xSmall)
                }
            }
            .toolbar {
                normalToolbarContent
                selectionToolbarContent
            }
            .onChange(of: editMode) { _, mode in
                navigationState.setCardListSelectionActive(mode == .active)
            }
            .environment(\.editMode, $editMode)
            .background(AppTheme.background.ignoresSafeArea())
    }

    private var interactionPresentations: some View {
        baseView
            // sheet / confirmationDialog / alert は同じ状態機械を共有し、同時表示を禁止する。
            .sheet(item: sheetPresentationBinding, onDismiss: {
                completeCurrentPresentationDismissal()
                if refreshAfterSheetDismissal {
                    refreshAfterSheetDismissal = false
                    viewModel.fetchCards()
                }
            }) { request in
                sheetContent(for: request)
            }
            .confirmationDialog(
                confirmationTitle,
                isPresented: confirmationPresentationBinding,
                titleVisibility: .visible
            ) {
                confirmationActions
            } message: {
                Text(confirmationMessage)
            }
            .alert(alertTitle, isPresented: alertPresentationBinding) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(alertMessage)
            }
            .background {
                ZStack {
                    PresentationDismissalObserver(
                        activeID: activeNonSheetRequestID,
                        dismissingID: dismissingNonSheetRequestID,
                        onDismissalCompleted: completeNonSheetPresentationDismissal
                    )
                }
                .frame(width: 0, height: 0)
            }
            .onAppear {
                if viewModel.externalFilter != navigationState.externalFilter {
                    viewModel.externalFilter = navigationState.externalFilter
                }
                navigationState.setCardListBackgroundInteractionBlocked(
                    contextMenuInteractionGate.blocksCardInteraction
                )
                // 非表示中に完了した共有・連絡先処理の結果も、復帰時に必ず取り込む。
                consumeViewModelPresentationSignals()
                guard !didPrepareInitialAppearance else { return }
                didPrepareInitialAppearance = true
                handleScreenshotMode()
            }
            .onChange(of: navigationState.externalFilter) { _, filter in
                viewModel.externalFilter = filter
            }
            .onChange(of: navigationState.selectedTab) { _, selectedTab in
                guard selectedTab != .cards else { return }
                deactivateTransientInteractionState()
            }
            .onChange(of: contextMenuInteractionGate.blocksCardInteraction) { _, isBlocked in
                navigationState.setCardListBackgroundInteractionBlocked(isBlocked)
            }
            .onChange(of: viewModel.exportItem?.id) { _, _ in
                consumeExportPresentation()
            }
            .onChange(of: viewModel.errorMessage) { _, _ in
                consumeErrorPresentation()
            }
            .onChange(of: viewModel.importResultMessage) { _, _ in
                consumeImportResultPresentation()
            }
            .onChange(of: viewModel.isListDisplayReady) { _, _ in
                selectFirstCardForCaptureIfReady()
            }
    }

    // MARK: - Presentation state

    /// 現在の sheet request の ID を Binding に閉じ込める。
    /// 前の sheet が遅れて dismiss を通知しても、次の表示を閉じない。
    private var sheetPresentationBinding: Binding<CardListPresentationRequest?> {
        let requestID = activeSheetRequest?.id
        return Binding(
            get: { activeSheetRequest },
            set: { request in
                guard request == nil, let requestID else { return }
                presentationState.clearActive(requestID: requestID)
            }
        )
    }

    private var confirmationPresentationBinding: Binding<Bool> {
        let requestID = activeConfirmationRequest?.id
        return Binding(
            get: { activeConfirmationRequest != nil },
            set: { isPresented in
                guard !isPresented, let requestID else { return }
                beginPresentationDismissal(requestID: requestID)
            }
        )
    }

    private var alertPresentationBinding: Binding<Bool> {
        let requestID = activeAlertRequest?.id
        return Binding(
            get: { activeAlertRequest != nil },
            set: { isPresented in
                guard !isPresented, let requestID else { return }
                beginPresentationDismissal(requestID: requestID)
            }
        )
    }

    private var activeSheetRequest: CardListPresentationRequest? {
        guard let request = presentationState.active,
              case .sheet = request.destination else { return nil }
        return request
    }

    private var activeConfirmationRequest: CardListPresentationRequest? {
        guard let request = presentationState.active,
              case .confirmation = request.destination else { return nil }
        return request
    }

    private var activeAlertRequest: CardListPresentationRequest? {
        guard let request = presentationState.active,
              case .alert = request.destination else { return nil }
        return request
    }

    @ViewBuilder
    private func sheetContent(for request: CardListPresentationRequest) -> some View {
        if case .sheet(let destination) = request.destination {
            switch destination {
            case .tagManager:
                TagManagementView()
                    .environmentObject(viewModel)
            case .editCard(let objectURI):
                if let card = viewModel.cardForEditing(objectURI: objectURI) {
                    CardFormView(card: card, onSave: {
                        // Core Dataの保存通知で予約された再取得を止め、sheetの
                        // 離脱完了後に一度だけ実行する。遷移中の全一覧更新を避ける。
                        viewModel.cancelPendingContextRefresh()
                        refreshAfterSheetDismissal = true
                        presentationState.clearActive(requestID: request.id)
                    })
                } else {
                    unavailableSheet(
                        title: "名刺を編集できません",
                        description: "この名刺は削除されたか、同期によって更新されています。",
                        requestID: request.id
                    )
                }
            case .bulkTag(let cardURIs):
                if cardURIs.isEmpty {
                    unavailableSheet(
                        title: "名刺を選択できません",
                        description: "選択した名刺は削除されたか、同期によって更新されています。",
                        requestID: request.id
                    )
                } else {
                    BulkTagAssignView(
                        selectedCardURIs: cardURIs,
                        onDismiss: {
                            presentationState.clearActive(requestID: request.id)
                        }
                    )
                    .environmentObject(viewModel)
                    .environmentObject(entitlementStore)
                }
            case .paywall:
                PaywallView(context: .aiSearch)
                    .environmentObject(entitlementStore)
            case .mockOCRForm:
                CardFormView(viewModelFactory: {
                    ScreenshotMockSupport.makeMockOCRFinishedViewModel()
                }, onSave: {
                    presentationState.clearActive(requestID: request.id)
                })
                .environmentObject(viewModel)
            case .shareExport(let url):
                ShareSheet(activityItems: [url])
            }
        }
    }

    private func unavailableSheet(
        title: String,
        description: String,
        requestID: UUID
    ) -> some View {
        NavigationStack {
            ContentUnavailableView(
                title,
                systemImage: "exclamationmark.triangle",
                description: Text(description)
            )
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("閉じる") {
                        presentationState.clearActive(requestID: requestID)
                    }
                }
            }
        }
    }

    private var confirmationTitle: String {
        switch activeConfirmation {
        case .importContacts: "連絡先からインポート"
        case .deleteCard, .bulkDelete: "名刺を削除"
        case nil: ""
        }
    }

    private var confirmationMessage: String {
        switch activeConfirmation {
        case .importContacts:
            "iPhoneの連絡先をすべて名刺としてインポートします。"
        case .deleteCard:
            "この名刺を削除します。この操作は取り消せません。"
        case .bulkDelete(let cardURIs):
            "\(cardURIs.count)件の名刺を削除します。この操作は取り消せません。"
        case nil:
            ""
        }
    }

    @ViewBuilder
    private var confirmationActions: some View {
        switch activeConfirmation {
        case .importContacts:
            Button("インポート") {
                scheduleActiveConfirmationCommit(.importContacts)
            }
            Button("キャンセル", role: .cancel) {}
        case .deleteCard(let objectURI):
            Button("削除", role: .destructive) {
                scheduleActiveConfirmationCommit(.deleteCard(objectURI: objectURI))
            }
            Button("キャンセル", role: .cancel) {}
        case .bulkDelete(let cardURIs):
            Button("削除（\(cardURIs.count)件）", role: .destructive) {
                scheduleActiveConfirmationCommit(.bulkDelete(cardURIs: cardURIs))
            }
            Button("キャンセル", role: .cancel) {}
        case nil:
            EmptyView()
        }
    }

    private var activeConfirmation: CardListPresentationDestination.Confirmation? {
        guard let request = activeConfirmationRequest,
              case .confirmation(let confirmation) = request.destination else { return nil }
        return confirmation
    }

    private var alertTitle: String {
        switch activeAlert {
        case .error: "エラー"
        case .importResult: "インポート完了"
        case nil: ""
        }
    }

    private var alertMessage: String {
        switch activeAlert {
        case .error(let message), .importResult(let message): message
        case nil: ""
        }
    }

    private var activeAlert: CardListPresentationDestination.Alert? {
        guard let request = activeAlertRequest,
              case .alert(let alert) = request.destination else { return nil }
        return alert
    }

    private func requestPresentation(_ destination: CardListPresentationDestination) {
        presentationState.request(destination)
    }

    private var activeNonSheetRequestID: UUID? {
        guard let request = presentationState.active else { return nil }
        switch request.destination {
        case .alert, .confirmation:
            return request.id
        case .sheet:
            return nil
        }
    }

    private var dismissingNonSheetRequestID: UUID? {
        guard let request = presentationState.dismissing else { return nil }
        switch request.destination {
        case .alert, .confirmation:
            return request.id
        case .sheet:
            return nil
        }
    }

    private func beginPresentationDismissal(requestID: UUID) {
        presentationState.clearActive(requestID: requestID)
    }

    private func completeNonSheetPresentationDismissal(requestID: UUID) {
        let commit = confirmationCommitState.take(afterDismissing: requestID)
        let lifetimeID = viewLifetimeID
        confirmationCommitTask?.cancel()
        confirmationCommitTask = Task {
            defer {
                if viewLifetimeID == lifetimeID {
                    confirmationCommitTask = nil
                }
            }
            if let commit {
                await performConfirmationCommit(commit)
            }
            guard !Task.isCancelled,
                  viewLifetimeID == lifetimeID,
                  presentationState.dismissing?.id == requestID else { return }
            presentationState.presentNext(afterDismissing: requestID)
        }
    }

    private func completeCurrentPresentationDismissal() {
        guard let requestID = presentationState.dismissing?.id else { return }
        presentationState.presentNext(afterDismissing: requestID)
    }

    /// 確認ダイアログ内では、連絡先権限UI・Core Data更新・toolbar切替を開始しない。
    /// 実際のdialog dismissal完了後にだけ副作用を実行する。
    private func scheduleActiveConfirmationCommit(_ action: CardListConfirmationCommit) {
        guard let active = activeConfirmationRequest,
              confirmationCommitState.schedule(action, for: active.id) else { return }
        beginPresentationDismissal(requestID: active.id)
    }

    private func performConfirmationCommit(_ action: CardListConfirmationCommit) async {
        switch action {
        case .importContacts:
            await viewModel.importFromContacts()
        case .deleteCard(let objectURI):
            viewModel.deleteCards(objectURIs: [objectURI])
        case .bulkDelete(let cardURIs):
            viewModel.deleteCards(objectURIs: cardURIs)
            selectedCardIDs = []
            editMode = .inactive
        }
    }

    private var selectedCardURIs: Set<URL> {
        selectedCardIDs
    }

    /// ViewModel の一時的な出力を presentation state へ移し、二重の表示状態を残さない。
    private func consumeViewModelPresentationSignals() {
        consumeExportPresentation()
        consumeErrorPresentation()
        consumeImportResultPresentation()
    }

    private func consumeExportPresentation() {
        guard let item = viewModel.exportItem else { return }
        viewModel.exportItem = nil
        requestPresentation(.sheet(.shareExport(url: item.url)))
    }

    private func consumeErrorPresentation() {
        guard let message = viewModel.errorMessage else { return }
        viewModel.errorMessage = nil
        requestPresentation(.alert(.error(message: message)))
    }

    private func consumeImportResultPresentation() {
        guard let message = viewModel.importResultMessage else { return }
        viewModel.importResultMessage = nil
        requestPresentation(.alert(.importResult(message: message)))
    }

    /// XCUITest（ScreenshotRunner）から START_SCREEN を受け取った場合、対応するシートを開く
    private func handleScreenshotMode() {
        guard ScreenshotMode.isActive, let screen = ScreenshotMode.startScreen else { return }
        switch screen {
        case "Tags":     requestPresentation(.sheet(.tagManager))
        case "UnifiedSearch":
            // 撮影ランではシミュレータで LLM が動かないため確定結果を注入する
            viewModel.applyCaptureUnifiedSearchMock()
            // iPad は検索結果の先頭を detail 列へ表示した状態で撮る
            if usesSidebarLayout {
                isCaptureDetailSelectionPending = true
                selectFirstCardForCaptureIfReady()
            }
        case "FormOCR":  requestPresentation(.sheet(.mockOCRForm))
        case "Paywall":  requestPresentation(.sheet(.paywall))
        case "Settings": navigationState.showSettings()
        case "List":
            // iPad の一覧撮影は detail 列を空にせず、先頭名刺の詳細を表示した状態で撮る
            guard usesSidebarLayout else { break }
            isCaptureDetailSelectionPending = true
            selectFirstCardForCaptureIfReady()
        default: break
        }
    }

    /// 一覧の初期ロード完了を待ってから先頭名刺を選択する（撮影ラン専用）
    private func selectFirstCardForCaptureIfReady() {
        guard isCaptureDetailSelectionPending,
              viewModel.isListDisplayReady,
              let first = viewModel.filteredCardItems.first else { return }
        isCaptureDetailSelectionPending = false
        navigationState.showCardDetail(first.id)
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
            if editMode == .inactive {
                sortFilterMenu
                    .disabled(!viewModel.hasDisplayedCards)
                    .accessibilityHidden(!viewModel.hasDisplayedCards)
            }
        }

        if !usesSidebarLayout && editMode == .inactive {
            ToolbarSpacer(.fixed, placement: .topBarTrailing)
        }

        ToolbarItem(placement: .topBarTrailing) {
            if editMode == .active {
                Button("完了") {
                    editMode = .inactive
                    selectedCardIDs = []
                }
                .fontWeight(.semibold)
                .tint(Color.primary)
                .accessibilityIdentifier("doneButton")
            } else {
                Button("選択") {
                    editMode = .active
                    selectedCardIDs = []
                }
                .tint(Color.primary)
                .disabled(!viewModel.hasDisplayedCards)
                .accessibilityHidden(!viewModel.hasDisplayedCards)
                .accessibilityIdentifier("selectButton")
            }
        }

        if !usesSidebarLayout && editMode == .inactive {
            ToolbarSpacer(.fixed, placement: .topBarTrailing)
        }

        // 右上: その他の操作
        ToolbarItem(placement: .topBarTrailing) {
            if editMode == .inactive {
                Menu {
                if viewModel.hasDisplayedCards {
                    Button {
                        navigationState.showCardRoute(.duplicates)
                    } label: {
                        Label(
                            viewModel.duplicatePairs.isEmpty ? "重複チェック" : "重複チェック（\(viewModel.duplicatePairs.count)件）",
                            systemImage: "person.2.slash"
                        )
                    }
                    Divider()
                }
                Button {
                    requestPresentation(.confirmation(.importContacts))
                } label: {
                    Label("連絡先からインポート", systemImage: "person.crop.circle.badge.plus")
                }
                .disabled(viewModel.isImporting)
                .accessibilityIdentifier("importFromContacts")
                if viewModel.hasDisplayedCards {
                    Divider()
                    Button { viewModel.exportCSV() } label: {
                        Label("CSV としてエクスポート", systemImage: "tablecells")
                    }
                    Button { viewModel.exportVCard() } label: {
                        Label("vCard としてエクスポート", systemImage: "person.crop.rectangle")
                    }
                }
                Divider()
                Button { requestPresentation(.sheet(.tagManager)) } label: {
                    Label("タグ管理", systemImage: "tag")
                }
                .accessibilityIdentifier("tagManager")
                Divider()
                Button {
                    navigationState.showSettings()
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
        }

    }

    // MARK: - 選択モードのツールバー

    @ToolbarContentBuilder
    private var selectionToolbarContent: some ToolbarContent {
        // 左上: すべて選択/全解除
        ToolbarItem(placement: .topBarLeading) {
            if editMode == .active {
                Button(selectedCardIDs.count == viewModel.filteredCardItems.count && !viewModel.filteredCardItems.isEmpty ? "全解除" : "すべて選択") {
                    if selectedCardIDs.count == viewModel.filteredCardItems.count {
                        selectedCardIDs = []
                    } else {
                        selectedCardIDs = Set(viewModel.filteredCardItems.map(\.id))
                    }
                }
                .tint(Color.primary)
                .accessibilityIdentifier("selectAllButton")
            }
        }

        // 下部: 一括操作（左: 削除 / 中央: タグ＋お気に入り / 右: エクスポート）
        if editMode == .active {
            ToolbarItemGroup(placement: .bottomBar) {
            // 削除
            Button(role: .destructive) {
                requestPresentation(.confirmation(.bulkDelete(cardURIs: selectedCardURIs)))
            } label: {
                Label("削除", systemImage: "trash")
            }
            .tint(.red)
            .disabled(selectedCardIDs.isEmpty)
            .accessibilityIdentifier("bulkDeleteButton")

            Spacer()

            // タグ
            Button {
                requestPresentation(.sheet(.bulkTag(cardURIs: selectedCardURIs)))
            } label: {
                Label("タグ", systemImage: "tag")
            }
            .tint(Color.primary)
            .disabled(selectedCardIDs.isEmpty)

            // お気に入り
            Button {
                haptic.impactOccurred()
                viewModel.toggleBulkFavorite(objectURIs: selectedCardIDs)
            } label: {
                Label("お気に入り", systemImage: "star")
            }
            .tint(Color.primary)
            .disabled(selectedCardIDs.isEmpty)

            Spacer()

            // エクスポート
            Menu {
                Button {
                    exportSelectedCards(as: .csv)
                } label: {
                    Label("CSVエクスポート", systemImage: "tablecells")
                }
                Button {
                    exportSelectedCards(as: .vCard)
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
    }

    // MARK: - サブビュー

    private var cardList: some View {
        let showIndex = editMode == .inactive && !viewModel.isDisplayedSearchActive &&
            (viewModel.displayedSortKey == .name || viewModel.displayedSortKey == .company)
        return ScrollViewReader { proxy in
            List(selection: selectionBinding) {
                if viewModel.isDisplayedSearchActive {
                    // 検索中はフラット表示
                    ForEach(viewModel.filteredCardItems) { item in
                        cardRow(for: item)
                    }
                    .onDelete { offsets in
                        // 確認ダイアログを経由してから削除（HIG: 取り消せない破壊的操作は確認が必要）
                        if let item = offsets.map({ viewModel.filteredCardItems[$0] }).first {
                            requestPresentation(
                                .confirmation(.deleteCard(objectURI: item.id))
                            )
                        }
                    }
                    .deleteDisabled(editMode == .active)
                } else {
                    // ソート順に応じたセクション表示
                    ForEach(viewModel.groupedCardItemSections) { section in
                        Section {
                            ForEach(section.items) { item in
                                cardRow(for: item)
                            }
                            .onDelete { offsets in
                                // 確認ダイアログを経由してから削除（HIG: 取り消せない破壊的操作は確認が必要）
                                if let item = offsets.map({ section.items[$0] }).first {
                                    requestPresentation(
                                        .confirmation(.deleteCard(objectURI: item.id))
                                    )
                                }
                            }
                            .deleteDisabled(editMode == .active)
                        } header: {
                            HStack(spacing: 7) {
                                Text(section.title)
                                    .font(.subheadline.weight(.bold))
                                    .foregroundStyle(.primary)
                                Text("\(section.items.count)")
                                    .font(.caption.weight(.bold))
                                    .foregroundStyle(Color.primary.opacity(0.72))
                                    .padding(.horizontal, 7)
                                    .padding(.vertical, 3)
                                    .background(Color.secondary.opacity(0.16), in: Capsule())
                            }
                            .textCase(nil)
                            .accessibilityElement(children: .combine)
                            .accessibilityLabel("\(section.title)、\(section.items.count)件")
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
            // 索引の44ptタップ領域とカードのhit領域を完全に分離する。
            .contentMargins(.trailing, showIndex ? 44 : 0, for: .scrollContent)
            .scrollIndicators(showIndex ? .hidden : .automatic)
            .scrollDismissesKeyboard(.immediately)
            .overlay(alignment: .trailing) {
                if showIndex {
                    SectionIndexView(
                        sectionIDs: viewModel.groupedCardItemSections.map(\.id),
                        proxy: proxy
                    )
                    .padding(.trailing, 0)
                }
            }
            .frame(maxWidth: AppTheme.cardListMaximumWidth)
            .frame(maxWidth: .infinity)
        }
    }

    /// タブを離れた時だけ、一時的な操作状態を終了する。
    /// compact幅の詳細遷移はsidebarの`onDisappear`を発生させるため、ここには含めない。
    private func deactivateTransientInteractionState() {
        // 詳細列の表示ではなく、名刺タブ自体を離れた時だけ画面起点の世代を終了する。
        // これにより別タブ表示後に古い確認処理やpresentationが戻ってこない。
        viewLifetimeID = UUID()
        confirmationCommitTask?.cancel()
        confirmationCommitTask = nil
        confirmationCommitState.removeAll()
        presentationState.removeAll()
        refreshAfterSheetDismissal = false
        if editMode == .active {
            editMode = .inactive
            selectedCardIDs = []
        } else {
            navigationState.setCardListSelectionActive(false)
        }
        contextMenuInteractionGate.reset()
        navigationState.setCardListBackgroundInteractionBlocked(false)
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
            tags: viewModel.tagDisplaySnapshots.compactMap { tag in
                guard let id = tag.tagID else { return nil }
                return NativeSortFilterMenuButton.TagOption(id: id, name: tag.name)
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
                haptic.impactOccurred()
                viewModel.setTagFilter(id: tagID, enabled: isEnabled)
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
    private func cardRow(for item: CardListItemSnapshot) -> some View {
        let rowSnapshot = item.row
        if editMode == .inactive {
            Button {
                guard !contextMenuInteractionGate.blocksCardInteraction else { return }
                haptic.impactOccurred(intensity: 0.55)
                navigationState.showCardDetail(item.id)
            } label: {
                CardRowView(
                    item: item,
                    compact: usesSidebarLayout,
                    isSelected: usesSidebarLayout &&
                        navigationState.selectedCardURI == item.id
                )
            }
            .buttonStyle(CardRowButtonStyle())
            .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .accessibilityIdentifier("cardRow_\(rowSnapshot.displayName)")
            .accessibilityHint("詳細を表示")
            .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
            .swipeActions(edge: .leading) {
                Button {
                    haptic.impactOccurred()
                    viewModel.toggleFavorite(objectURI: item.id)
                } label: {
                    Label(
                        rowSnapshot.isFavorite ? "解除" : "お気に入り",
                        systemImage: rowSnapshot.isFavorite ? "star.slash" : "star.fill"
                    )
                }
                .tint(.yellow)
            }
            .contextMenu {
                cardContextMenu(for: item.id, isFavorite: rowSnapshot.isFavorite)
            } preview: {
                CardPeekView(item: item)
                    .background {
                        ContextMenuPreviewLifecycleObserver(
                            onPreviewPresented: {
                                contextMenuInteractionGate.previewDidAppear()
                            },
                            onDismissalBegan: { sessionID in
                                contextMenuInteractionGate.previewDidDisappear(
                                    sessionID: sessionID
                                )
                            },
                            onDismissalCompleted: { sessionID in
                                completeContextMenuDismissal(sessionID: sessionID)
                            },
                            onDismissalCancelled: { sessionID in
                                contextMenuInteractionGate.dismissalWasCancelled(
                                    sessionID: sessionID
                                )
                            }
                        )
                        .frame(width: 0, height: 0)
                    }
            }
        } else {
            CardRowView(item: item, compact: usesSidebarLayout)
                .accessibilityIdentifier("cardRow_\(rowSnapshot.displayName)")
                .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
        }
    }

    // MARK: - コンテキストメニュー

    @ViewBuilder
    private func cardContextMenu(for objectURI: URL, isFavorite: Bool) -> some View {
        Button {
            requestContextMenuAction(
                .toggleFavorite(objectURI: objectURI)
            )
        } label: {
            Label(
                isFavorite ? "お気に入り解除" : "お気に入りに追加",
                systemImage: isFavorite ? "star.slash" : "star.fill"
            )
        }
        .tint(Color.primary)

        Button {
            requestContextMenuAction(.edit(objectURI: objectURI))
        } label: {
            Label("編集", systemImage: "pencil")
        }
        .tint(Color.primary)

        Button {
            requestContextMenuAction(.shareVCard(objectURI: objectURI))
        } label: {
            Label("vCardとして共有", systemImage: "square.and.arrow.up")
        }
        .tint(Color.primary)

        Button {
            requestContextMenuAction(.saveToContacts(objectURI: objectURI))
        } label: {
            Label("連絡先に保存", systemImage: "person.crop.circle.badge.plus")
        }
        .tint(Color.primary)

        Divider()

        Button(role: .destructive) {
            requestContextMenuAction(.delete(objectURI: objectURI))
        } label: {
            Label("削除", systemImage: "trash")
        }
    }

    private func requestContextMenuAction(_ action: CardListContextMenuAction) {
        guard let immediateAction = contextMenuInteractionGate.deferUntilDismissal(action) else {
            return
        }
        performContextMenuAction(immediateAction)
    }

    private func completeContextMenuDismissal(sessionID: UUID) {
        guard let deferredAction = contextMenuInteractionGate.dismissalDidComplete(
            sessionID: sessionID
        ) else { return }
        performContextMenuAction(deferredAction)
    }

    private func performContextMenuAction(_ action: CardListContextMenuAction) {
        switch action {
        case .toggleFavorite(let objectURI):
            haptic.impactOccurred()
            viewModel.toggleFavorite(objectURI: objectURI)
        case .edit(let objectURI):
            requestPresentation(.sheet(.editCard(objectURI: objectURI)))
        case .shareVCard(let objectURI):
            viewModel.shareVCard(objectURI: objectURI)
        case .saveToContacts(let objectURI):
            viewModel.saveToContacts(objectURI: objectURI)
        case .delete(let objectURI):
            requestPresentation(.confirmation(.deleteCard(objectURI: objectURI)))
        }
    }

    private enum SelectedCardExportFormat {
        case csv
        case vCard
    }

    private func exportSelectedCards(as format: SelectedCardExportFormat) {
        guard !selectedCardURIs.isEmpty else { return }
        switch format {
        case .csv:
            viewModel.exportSelectedCSV(objectURIs: selectedCardURIs)
        case .vCard:
            viewModel.exportSelectedVCard(objectURIs: selectedCardURIs)
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
