import PhotosUI
import SwiftUI
import UIKit

/// 名刺追加の全入口を、排他的な状態機械から提示する。
/// 各状態はsheet・fullScreenCover・PhotosPicker・alertのいずれか1つだけを所有する。
struct CardAdditionFlowModifier: ViewModifier {
    @EnvironmentObject private var viewModel: CardListViewModel
    @EnvironmentObject private var navigationState: AppNavigationState
    @EnvironmentObject private var entitlementStore: EntitlementStore
    @EnvironmentObject private var rootPresentationRequests: AppRootPresentationRequests

    @State private var flowState: CardAdditionFlowState = .idle
    @State private var batchInputs: [CardImageInput] = []
    @State private var pendingOCRQueue: PendingOCRStore.Queue?
    @State private var selectedPhotoItems: [PhotosPickerItem] = []
    @State private var batchWarningMessage: String?
    @State private var deferredMessage: CardAdditionMessage?
    @State private var batchGeneration: UUID?
    @State private var batchProcessedCount = 0
    @State private var batchTotalCount = 0
    @State private var isPendingQueueAvailable = true
    @State private var photoImportTask: Task<Void, Never>?
    @State private var cameraPreparationTask: Task<Void, Never>?
    @State private var batchCancellationTask: Task<Void, Never>?
    @State private var pendingQueueMutationTask: Task<Void, Never>?
    @State private var modelDownloadTask: Task<Void, Never>?
    @State private var modelDownloadGeneration: UUID?
    @State private var shouldAutoPromptPendingOCR = true
    @State private var contextRefreshDeferralToken: UUID?
    @State private var didSaveCardInCurrentSheet = false
    @State private var isProgressAlertPresented = false
    @State private var pendingProgressAlertWork: (() -> Void)?

    func body(content: Content) -> some View {
        content
            .sheet(item: sheetDestination, onDismiss: handleSheetDismissed) { destination in
                sheetContent(for: destination)
            }
            .fullScreenCover(
                item: cameraDestination,
                onDismiss: handleCameraDismissed
            ) { _ in
                CameraCaptureView(
                    onComplete: handleCameraCompletion,
                    onCancel: handleCameraCancellation
                )
            }
            .photosPicker(
                isPresented: isPhotoPickerPresented,
                selection: $selectedPhotoItems,
                maxSelectionCount: 10,
                selectionBehavior: .ordered,
                matching: .images,
                preferredItemEncoding: .current
            )
            .onChange(of: selectedPhotoItems) { _, items in
                handlePhotoSelection(items)
            }
            .alert(item: alertDestination) { destination in
                alert(for: destination)
            }
            .background {
                PresentationDismissalObserver(
                    activeID: activeObservedPresentation,
                    dismissingID: dismissingObservedPresentation,
                    onDismissalCompleted: completeObservedPresentationDismissal
                )
                .frame(width: 0, height: 0)
                BatchProgressAlertPresenter(
                    title: progressAlertTitle,
                    onPresented: {
                        isProgressAlertPresented = true
                        if let work = pendingProgressAlertWork {
                            pendingProgressAlertWork = nil
                            work()
                        }
                    },
                    onCancel: { cancelBatchPreparation() }
                )
                .frame(width: 0, height: 0)
            }
            .onChange(of: navigationState.isCardAdditionRequested) { _, requested in
                if requested {
                    presentRequestedRootSheetIfPossible()
                }
            }
            .onChange(of: navigationState.isAISearchPaywallRequested) { _, requested in
                if requested {
                    presentRequestedRootSheetIfPossible()
                }
            }
            .onChange(of: rootPresentationRequests.isSettingsSheetPending) { _, requested in
                if requested {
                    presentRequestedRootSheetIfPossible()
                }
            }
            .onChange(of: rootPresentationRequests.queue) { _, _ in
                presentDeferredPromptOrRequest()
            }
            .onChange(of: flowState) { _, state in
                if state != .importingPhotos && state != .preparingCameraBatch {
                    isProgressAlertPresented = false
                    pendingProgressAlertWork = nil
                }
                guard state == .idle else { return }
                presentDeferredPromptOrRequest()
            }
            .onAppear {
                presentRequestedRootSheetIfPossible()
            }
            .task {
                await loadPendingOCR()
            }
            .onDisappear {
                cancelProcessingTasks()
                batchCancellationTask?.cancel()
                pendingQueueMutationTask?.cancel()
                modelDownloadTask?.cancel()
                modelDownloadTask = nil
                modelDownloadGeneration = nil
                finishCardMutationSession()
            }
    }

    // MARK: - Presentation bindings

    private var sheetDestination: Binding<CardAdditionSheetDestination?> {
        Binding(
            get: {
                switch flowState {
                case .chooser:
                    .chooser
                case .aiSearchPaywall:
                    .aiSearchPaywall
                case .settings:
                    .settings
                case .manualForm:
                    .manualForm
                case .batchReview:
                    .batchReview
                default:
                    nil
                }
            },
            set: { destination in
                guard destination == nil else { return }
                switch flowState {
                case .chooser, .aiSearchPaywall, .settings, .manualForm, .batchReview:
                    flowState.send(.sheetDismissRequested)
                default:
                    break
                }
            }
        )
    }

    private var cameraDestination: Binding<CardAdditionCameraDestination?> {
        Binding(
            get: { flowState == .camera ? .camera : nil },
            set: { destination in
                guard destination == nil, flowState == .camera else { return }
                flowState.send(.cameraFinished(hasImages: false))
            }
        )
    }

    private var isPhotoPickerPresented: Binding<Bool> {
        Binding(
            get: {
                if case .photoPicker = flowState { return true }
                return false
            },
            set: { isPresented in
                guard !isPresented else { return }
                if case .photoPicker = flowState {
                    flowState.send(.photoPickerDismissRequested)
                }
            }
        )
    }

    private var alertDestination: Binding<CardAdditionAlertDestination?> {
        Binding(
            get: {
                switch flowState {
                case .pendingOCRPrompt:
                    .pendingOCR(count: pendingOCRQueue?.inputs.count ?? 0)
                case .message(let message):
                    .message(message)
                case .launchAlert(let alert):
                    .launch(alert)
                default:
                    nil
                }
            },
            set: { destination in
                guard destination == nil else { return }
                switch flowState {
                case .message:
                    flowState.send(.dismissMessage)
                case .pendingOCRPrompt:
                    flowState.send(.dismissAlert)
                case .launchAlert:
                    flowState.send(.dismissLaunchAlert)
                default:
                    break
                }
            }
        )
    }

    /// 進行アラートのタイトル。SwiftUIの`.alert(item:)`はitemをnilへ戻す
    /// programmatic dismissを取りこぼすことがあるため、進行表示だけは
    /// BatchProgressAlertPresenterでUIAlertControllerを直接提示・取り下げる。
    private var progressAlertTitle: String? {
        switch flowState {
        case .importingPhotos:
            "写真を読み込み中"
        case .preparingCameraBatch:
            "撮影内容を準備中"
        default:
            nil
        }
    }

    // MARK: - Presented content

    @ViewBuilder
    private func sheetContent(for destination: CardAdditionSheetDestination) -> some View {
        switch destination {
        case .chooser:
            AddCardSheet(
                pendingCount: pendingOCRQueue?.inputs.count ?? 0,
                isImporting: false,
                onCamera: { selectAddAction(.camera) },
                onPhotos: { selectAddAction(.photos) },
                onManual: { selectAddAction(.manual) },
                onResume: pendingOCRQueue == nil
                    ? nil
                    : { selectAddAction(.resumePendingOCR) }
            )
            .presentationDetents([.medium])
            .presentationDragIndicator(.visible)

        case .aiSearchPaywall:
            PaywallView(context: .aiSearch)
                .environmentObject(entitlementStore)

        case .settings:
            NavigationStack {
                SettingsView()
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button("完了") {
                                flowState.send(.sheetDismissRequested)
                            }
                            .fontWeight(.semibold)
                            .accessibilityIdentifier("settingsDoneButton")
                        }
                    }
            }

        case .manualForm:
            CardFormView(onSave: {
                recordSuccessfulCardSave()
                flowState.send(.manualFinished)
            })

        case .batchReview:
            BatchReviewView(
                inputs: $batchInputs,
                queueID: batchGeneration,
                processedCount: $batchProcessedCount,
                totalCount: batchTotalCount,
                externalWarning: $batchWarningMessage,
                isPendingQueueAvailable: $isPendingQueueAvailable,
                onCardSaved: recordSuccessfulCardSave,
                onComplete: {
                    if let queueID = batchGeneration {
                        discardCompletedQueue(queueID: queueID)
                    }
                    pendingOCRQueue = nil
                    flowState.send(.batchFinished)
                }
            )
            .environmentObject(viewModel)
        }
    }

    private func alert(for destination: CardAdditionAlertDestination) -> Alert {
        switch destination {
        case .pendingOCR(let count):
            Alert(
                title: Text("未完了の読み取り"),
                message: Text("前回中断した名刺が\(count)枚あります。"),
                primaryButton: .default(Text("再開")) {
                    activatePendingQueue()
                    flowState.send(.resumePendingOCR)
                },
                secondaryButton: .destructive(Text("破棄")) {
                    discardRestoredQueue()
                    flowState.send(.discardPendingOCR)
                }
            )

        case .message(let message):
            Alert(
                title: Text(message.title),
                message: Text(message.message),
                dismissButton: .cancel(Text("OK")) {
                    flowState.send(.dismissMessage)
                }
            )

        case .launch(let alert):
            switch alert {
            case .grandfatheredAnnouncement:
                Alert(
                    title: Text("eMeishi Pro が登場しました"),
                    message: Text("既存ユーザーには、AI 自然言語検索を引き続き無料でご利用いただけます。新しい Pro 機能は設定画面からご確認ください。"),
                    dismissButton: .default(Text("OK")) {
                        flowState.send(.dismissLaunchAlert)
                    }
                )
            case .qwenDownloadPrompt:
                Alert(
                    title: Text("AIモデルをダウンロードしますか？"),
                    message: Text("この端末はApple Intelligenceに対応していないため、名刺の読み取り精度を向上させるAIモデルをダウンロードできます。Wi-Fi環境でのダウンロードを推奨します。"),
                    primaryButton: .default(Text("ダウンロード（約570MB）")) {
                        flowState.send(.dismissLaunchAlert)
                        startModelDownload()
                    },
                    secondaryButton: .cancel(Text("あとで")) {
                        flowState.send(.dismissLaunchAlert)
                    }
                )
            }
        }
    }

    // MARK: - State transitions

    private func presentRequestedRootSheetIfPossible() {
        guard flowState == .idle else { return }

        // 同じrootのsheet所有者を1つに固定し、AI検索のPaywall・追加フロー・設定が
        // 同時に提示されないよう、先に届いたユーザー操作を状態機械へ取り込む。
        if navigationState.isAISearchPaywallRequested {
            flowState.send(.requestAISearchPaywall)
            navigationState.consumeAISearchPaywallRequest()
        } else if navigationState.isCardAdditionRequested {
            flowState.send(.requestAddition)
            navigationState.consumeCardAdditionRequest()
        } else if rootPresentationRequests.consumeSettingsSheetRequest() {
            flowState.send(.requestSettings)
        }
    }

    private func presentDeferredPromptOrRequest() {
        guard flowState == .idle else { return }
        if let deferredMessage {
            self.deferredMessage = nil
            flowState.send(.showMessage(deferredMessage))
        } else if shouldAutoPromptPendingOCR, pendingOCRQueue != nil {
            flowState.send(.pendingOCRFound)
        } else if let launchAlert = rootPresentationRequests.consumeNextLaunchAlert() {
            flowState.send(.showLaunchAlert(launchAlert))
        } else {
            presentRequestedRootSheetIfPossible()
        }
    }

    private func selectAddAction(_ action: CardAdditionAction) {
        if action == .photos {
            selectedPhotoItems = []
        }
        if action == .resumePendingOCR {
            activatePendingQueue()
        }
        if action == .manual {
            beginCardMutationSessionIfNeeded()
        }
        flowState.send(.selectAction(action))
    }

    private func handleSheetDismissed() {
        guard case .dismissingSheet(let destination) = flowState else { return }
        flowState.send(.sheetDismissed)

        switch destination {
        case .idle:
            resetTransientBatchState()
            finishCardMutationSession()
        case .preservePendingOCR:
            if let queueID = batchGeneration, isPendingQueueAvailable, !batchInputs.isEmpty {
                pendingOCRQueue = PendingOCRStore.Queue(
                    id: queueID,
                    inputs: batchInputs,
                    processedCount: batchProcessedCount,
                    totalCount: batchTotalCount
                )
                // ユーザーが閉じた直後に同じ警告を再提示せず、次の追加シートから再開できるようにする。
                shouldAutoPromptPendingOCR = false
            }
            resetTransientBatchState()
            finishCardMutationSession()
        case .action:
            break
        }
    }

    private func handleCameraCompletion(_ inputs: [CardImageInput]) {
        batchInputs = inputs
        let generation = UUID()
        batchGeneration = inputs.isEmpty ? nil : generation
        batchProcessedCount = 0
        batchTotalCount = inputs.count
        isPendingQueueAvailable = true
        flowState.send(.cameraFinished(hasImages: !inputs.isEmpty))
    }

    private func handleCameraCancellation() {
        batchInputs = []
        batchGeneration = nil
        batchProcessedCount = 0
        batchTotalCount = 0
        flowState.send(.cameraFinished(hasImages: false))
    }

    private func handleCameraDismissed() {
        flowState.send(.cameraDismissed)
        guard flowState == .preparingCameraBatch,
              let generation = batchGeneration else { return }
        cameraPreparationTask?.cancel()
        cameraPreparationTask = Task {
            await prepareCameraBatch(generation: generation)
            guard batchGeneration == generation else { return }
            cameraPreparationTask = nil
        }
    }

    private func prepareCameraBatch(generation: UUID) async {
        do {
            try Task.checkCancellation()
            try await PendingOCRStore.shared.persist(batchInputs, queueID: generation)
            try Task.checkCancellation()
            performWhenProgressAlertSettled {
                guard batchGeneration == generation,
                      flowState == .preparingCameraBatch else { return }
                isPendingQueueAvailable = true
                beginCardMutationSessionIfNeeded()
                flowState.send(.cameraPreparationSucceeded)
            }
        } catch is CancellationError {
            return
        } catch {
            performWhenProgressAlertSettled {
                guard batchGeneration == generation,
                      flowState == .preparingCameraBatch else { return }
                isPendingQueueAvailable = false
                batchWarningMessage = "未完了の読み取り情報を保存できませんでした。アプリ終了後の再開はできませんが、このまま確認を続けられます。"
                flowState.send(.cameraPreparationFailed)
            }
        }
    }

    // MARK: - Photo import and pending OCR

    private func handlePhotoSelection(_ items: [PhotosPickerItem]) {
        switch flowState {
        case .photoPicker, .dismissingPhotoPicker:
            flowState.send(.photoSelectionChanged(hasItems: !items.isEmpty))
        default:
            break
        }
    }

    private func importSelectedPhotos(_ items: [PhotosPickerItem], generation: UUID) async {
        defer {
            if batchGeneration == generation {
                selectedPhotoItems = []
            }
        }
        batchWarningMessage = nil
        isPendingQueueAvailable = true

        let result = await PhotoImportService.shared.importImages(from: items)
        guard !Task.isCancelled else { return }
        guard batchGeneration == generation,
              flowState == .importingPhotos else { return }
        batchInputs = result.images
        batchProcessedCount = 0
        batchTotalCount = result.images.count

        guard !batchInputs.isEmpty else {
            let reason = result.failures.first?.reason.message ?? "画像を読み込めませんでした"
            performWhenProgressAlertSettled {
                guard batchGeneration == generation,
                      flowState == .importingPhotos else { return }
                flowState.send(.photoImportFailed(CardAdditionMessage(
                    title: "写真の読込み",
                    message: "読込みに失敗しました。\(reason)。もう一度お試しください。"
                )))
            }
            return
        }

        if !result.failures.isEmpty {
            batchWarningMessage = "\(batchInputs.count)枚を読み込み、\(result.failures.count)枚は読み込めませんでした。"
        }
        UINotificationFeedbackGenerator().notificationOccurred(.success)

        do {
            try Task.checkCancellation()
            try await PendingOCRStore.shared.persist(result.images, queueID: generation)
            try Task.checkCancellation()
        } catch is CancellationError {
            return
        } catch {
            guard batchGeneration == generation,
                  flowState == .importingPhotos else { return }
            isPendingQueueAvailable = false
            batchWarningMessage = "未完了の読み取り情報を保存できませんでした。アプリ終了後の再開はできませんが、このまま確認を続けられます。"
        }
        performWhenProgressAlertSettled {
            guard batchGeneration == generation,
                  flowState == .importingPhotos else { return }
            beginCardMutationSessionIfNeeded()
            flowState.send(.photoImportSucceeded)
        }
    }

    /// 進行アラートのpresentation animation完了前に取り下げを伴う遷移を送ると、
    /// dismiss要求がanimationと競合してアラートが画面に残留する。
    /// UIAlertControllerのpresent完了通知（onPresented）を受けるまで処理を保留する。
    private func performWhenProgressAlertSettled(_ work: @escaping () -> Void) {
        if isProgressAlertPresented {
            work()
        } else {
            pendingProgressAlertWork = work
        }
    }

    private func loadPendingOCR() async {
        guard !ScreenshotMode.isActive else { return }
        do {
            let restored = try await PendingOCRStore.shared.restore()
            guard !Task.isCancelled else { return }
            pendingOCRQueue = restored
            if restored != nil, flowState == .idle {
                flowState.send(.pendingOCRFound)
            }
        } catch {
            showMessageWhenPossible(CardAdditionMessage(
                title: "未完了の読み取り",
                message: "前回の未完了読み取りを復元できませんでした。破損した一時データは設定を変えずに保持しています。"
            ))
        }
    }

    private func discardRestoredQueue() {
        guard let queue = pendingOCRQueue else { return }
        pendingOCRQueue = nil
        pendingQueueMutationTask?.cancel()
        pendingQueueMutationTask = Task {
            do {
                try await PendingOCRStore.shared.discard(queueID: queue.id)
            } catch {
                guard !Task.isCancelled else { return }
                showMessageWhenPossible(CardAdditionMessage(
                    title: "未完了の読み取り",
                    message: "未完了の読み取り情報を破棄できませんでした。"
                ))
            }
            guard !Task.isCancelled else { return }
            pendingQueueMutationTask = nil
        }
    }

    private func discardCompletedQueue(queueID: UUID) {
        pendingQueueMutationTask?.cancel()
        pendingQueueMutationTask = Task {
            do {
                try await PendingOCRStore.shared.discard(queueID: queueID)
            } catch {
                guard !Task.isCancelled else { return }
                deferredMessage = CardAdditionMessage(
                    title: "読み取り完了",
                    message: "完了済みの一時データを削除できませんでした。次回起動時に再確認してください。"
                )
            }
            guard !Task.isCancelled else { return }
            pendingQueueMutationTask = nil
        }
    }

    private func showMessageWhenPossible(_ message: CardAdditionMessage) {
        if flowState == .idle || flowState == .importingPhotos {
            flowState.send(.showMessage(message))
        } else {
            deferredMessage = message
        }
    }

    private func startModelDownload() {
        // 同じルート上のダウンロード要求は1つだけ所有し、二重開始を防ぐ。
        guard modelDownloadTask == nil else { return }
        let generation = UUID()
        modelDownloadGeneration = generation
        modelDownloadTask = Task {
            defer {
                if modelDownloadGeneration == generation {
                    modelDownloadGeneration = nil
                    modelDownloadTask = nil
                }
            }
            do {
                try await LocalLLMService.shared.downloadModel()
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled, modelDownloadGeneration == generation else { return }
                showMessageWhenPossible(CardAdditionMessage(
                    title: "AIモデルのダウンロード",
                    message: "ダウンロードに失敗しました。通信環境を確認して、設定からもう一度お試しください。"
                ))
            }
        }
    }

    private var activeObservedPresentation: CardAdditionObservedPresentation? {
        switch flowState {
        case .photoPicker:
            .photoPicker
        case .pendingOCRPrompt, .launchAlert, .message, .importingPhotos, .preparingCameraBatch:
            .alert
        default:
            nil
        }
    }

    private var dismissingObservedPresentation: CardAdditionObservedPresentation? {
        switch flowState {
        case .dismissingPhotoPicker:
            .photoPicker
        case .dismissingAlert:
            .alert
        default:
            nil
        }
    }

    private func completeObservedPresentationDismissal(
        _ presentation: CardAdditionObservedPresentation
    ) {
        switch presentation {
        case .photoPicker:
            flowState.send(.photoPickerDismissed)
            if flowState == .importingPhotos {
                let items = selectedPhotoItems
                guard !items.isEmpty else {
                    flowState.send(.photoImportFailed(CardAdditionMessage(
                        title: "写真の読込み",
                        message: "写真が選択されませんでした。もう一度お試しください。"
                    )))
                    return
                }
                photoImportTask?.cancel()
                let generation = UUID()
                batchGeneration = generation
                batchProcessedCount = 0
                batchTotalCount = items.count
                photoImportTask = Task {
                    await importSelectedPhotos(items, generation: generation)
                    guard batchGeneration == generation else { return }
                    photoImportTask = nil
                }
            } else {
                selectedPhotoItems = []
                presentDeferredPromptOrRequest()
            }
        case .alert:
            flowState.send(.alertDismissed)
            if flowState == .idle {
                presentDeferredPromptOrRequest()
            }
        }
    }

    private func resetTransientBatchState() {
        cancelProcessingTasks()
        batchInputs = []
        batchWarningMessage = nil
        batchGeneration = nil
        batchProcessedCount = 0
        batchTotalCount = 0
        isPendingQueueAvailable = true
    }

    private func cancelBatchPreparation() {
        guard flowState == .importingPhotos || flowState == .preparingCameraBatch else { return }
        let generation = batchGeneration
        cancelProcessingTasks()
        flowState.send(.beginBatchCancellation)
        batchCancellationTask?.cancel()
        batchCancellationTask = Task {
            if let generation {
                do {
                    try await PendingOCRStore.shared.discard(queueID: generation)
                } catch {
                    guard !Task.isCancelled else { return }
                    deferredMessage = CardAdditionMessage(
                        title: "読込みのキャンセル",
                        message: "一時データを破棄できませんでした。次回起動時に再確認できます。"
                    )
                }
            }
            guard !Task.isCancelled, batchGeneration == generation else { return }
            batchInputs = []
            selectedPhotoItems = []
            batchWarningMessage = nil
            batchGeneration = nil
            batchProcessedCount = 0
            batchTotalCount = 0
            isPendingQueueAvailable = true
            batchCancellationTask = nil
            flowState.send(.batchCancellationCompleted)
            presentDeferredPromptOrRequest()
        }
    }

    private func cancelProcessingTasks() {
        photoImportTask?.cancel()
        photoImportTask = nil
        cameraPreparationTask?.cancel()
        cameraPreparationTask = nil
    }

    private func activatePendingQueue() {
        guard let queue = pendingOCRQueue else { return }
        beginCardMutationSessionIfNeeded()
        batchInputs = queue.inputs
        batchGeneration = queue.id
        batchProcessedCount = queue.processedCount
        batchTotalCount = queue.totalCount
        pendingOCRQueue = nil
        shouldAutoPromptPendingOCR = true
        isPendingQueueAvailable = true
    }

    /// Core Data の変更通知による一覧更新を、追加シートの実 dismiss 完了まで保留する。
    private func beginCardMutationSessionIfNeeded() {
        guard contextRefreshDeferralToken == nil else { return }
        contextRefreshDeferralToken = viewModel.beginContextRefreshDeferral()
        didSaveCardInCurrentSheet = false
    }

    private func recordSuccessfulCardSave() {
        didSaveCardInCurrentSheet = true
        // 保存通知から既に予約された更新も、dismiss完了後の1回へまとめる。
        viewModel.cancelPendingContextRefresh()
    }

    private func finishCardMutationSession() {
        guard let token = contextRefreshDeferralToken else { return }
        contextRefreshDeferralToken = nil
        let shouldRefresh = didSaveCardInCurrentSheet
        didSaveCardInCurrentSheet = false
        viewModel.endContextRefreshDeferral(token, refreshCards: shouldRefresh)
    }

}

extension View {
    func cardAdditionFlow() -> some View {
        modifier(CardAdditionFlowModifier())
    }
}

private enum CardAdditionSheetDestination: String, Identifiable {
    case chooser
    case aiSearchPaywall
    case settings
    case manualForm
    case batchReview

    var id: String { rawValue }
}

private enum CardAdditionCameraDestination: String, Identifiable {
    case camera

    var id: String { rawValue }
}

private enum CardAdditionAlertDestination: Identifiable {
    case pendingOCR(count: Int)
    case message(CardAdditionMessage)
    case launch(AppLaunchAlert)

    var id: String {
        switch self {
        case .pendingOCR(let count):
            "pending-\(count)"
        case .message(let message):
            "message-\(message.id)"
        case .launch(let alert):
            "launch-\(alert.id)"
        }
    }
}

private enum CardAdditionObservedPresentation: Hashable {
    case photoPicker
    case alert
}
