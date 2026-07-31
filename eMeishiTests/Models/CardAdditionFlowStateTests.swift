import Testing
@testable import eMeishi

struct CardAdditionFlowStateTests {
    @Test
    func chooserWaitsForActualSheetDismissalBeforePresentingNextDestination() {
        var state = CardAdditionFlowState.idle

        state.send(.requestAddition)
        #expect(state == .chooser)
        state.send(.selectAction(.camera))
        #expect(state == .dismissingSheet(to: .action(.camera)))
        #expect(state.presentation == nil)

        state.send(.sheetDismissed)
        #expect(state == .camera)
        #expect(state.presentation == .fullScreenCover)
    }

    @Test
    func normalSheetDismissalDoesNotBecomeIdleUntilOnDismiss() {
        var state = CardAdditionFlowState.manualForm

        state.send(.manualFinished)
        #expect(state == .dismissingSheet(to: .idle))
        #expect(state.presentation == nil)

        state.send(.requestAddition)
        #expect(state == .dismissingSheet(to: .idle))

        state.send(.sheetDismissed)
        #expect(state == .idle)
    }

    @Test
    func everyReachableStateOwnsAtMostOneRootPresentation() {
        let message = CardAdditionMessage(title: "読込みエラー", message: "合成テスト用メッセージ")
        let states: [CardAdditionFlowState] = [
            .idle,
            .chooser,
            .aiSearchPaywall,
            .manualForm,
            .batchReview,
            .dismissingSheet(to: .action(.photos)),
            .camera,
            .dismissingCamera(to: .prepareBatch),
            .preparingCameraBatch,
            .cancellingBatch,
            .photoPicker(selectionReceived: false),
            .dismissingPhotoPicker(shouldImport: true),
            .importingPhotos,
            .pendingOCRPrompt,
            .launchAlert(.qwenDownloadPrompt),
            .message(message),
            .dismissingAlert(to: .idle),
        ]

        for state in states {
            let activePresentations = [
                state.presentation == .sheet,
                state.presentation == .fullScreenCover,
                state.presentation == .photoPicker,
                state.presentation == .alert,
            ].filter { $0 }.count
            #expect(activePresentations <= 1)
        }
    }

    @Test
    func cameraCompletionTransitionsOnlyAfterCoverDismissal() {
        var state = CardAdditionFlowState.camera

        state.send(.cameraFinished(hasImages: true))
        #expect(state == .dismissingCamera(to: .prepareBatch))
        state.send(.cameraDismissed)
        #expect(state == .preparingCameraBatch)
        #expect(state.presentation == .alert)
        state.send(.cameraPreparationSucceeded)
        #expect(state == .dismissingAlert(to: .batchReview))
        state.send(.alertDismissed)
        #expect(state == .batchReview)
    }

    @Test
    func cameraCancellationReturnsToIdleAfterCoverDismissal() {
        var state = CardAdditionFlowState.camera

        state.send(.cameraFinished(hasImages: false))
        #expect(state == .dismissingCamera(to: .idle))
        state.send(.cameraDismissed)

        #expect(state == .idle)
    }

    @Test
    func batchCancellationWaitsForPersistentQueueCleanup() {
        var state = CardAdditionFlowState.importingPhotos

        state.send(.beginBatchCancellation)
        #expect(state == .cancellingBatch)
        #expect(state.presentation == nil)

        state.send(.requestAddition)
        #expect(state == .cancellingBatch)
        state.send(.batchCancellationCompleted)
        #expect(state == .idle)
    }

    @Test
    func batchReviewDismissalPreservesPendingQueueIntent() {
        var state = CardAdditionFlowState.batchReview

        state.send(.sheetDismissRequested)
        #expect(state == .dismissingSheet(to: .preservePendingOCR))
        state.send(.sheetDismissed)
        #expect(state == .idle)
    }

    @Test
    func photoImportStartsOnlyAfterPickerIsActuallyDismissedForBothCallbackOrders() {
        var selectionFirst = CardAdditionFlowState.photoPicker(selectionReceived: false)
        selectionFirst.send(.photoSelectionChanged(hasItems: true))
        #expect(selectionFirst == .dismissingPhotoPicker(shouldImport: true))
        #expect(selectionFirst.presentation == nil)
        selectionFirst.send(.photoPickerDismissRequested)
        #expect(selectionFirst == .dismissingPhotoPicker(shouldImport: true))
        selectionFirst.send(.photoPickerDismissed)
        #expect(selectionFirst == .importingPhotos)

        var dismissalFirst = CardAdditionFlowState.photoPicker(selectionReceived: false)
        dismissalFirst.send(.photoPickerDismissRequested)
        #expect(dismissalFirst == .dismissingPhotoPicker(shouldImport: false))
        dismissalFirst.send(.photoSelectionChanged(hasItems: true))
        #expect(dismissalFirst == .dismissingPhotoPicker(shouldImport: true))
        dismissalFirst.send(.photoPickerDismissed)
        #expect(dismissalFirst == .importingPhotos)
    }

    @Test
    func photoImportPresentsProgressAlertAndWaitsForItsDismissalBeforeReview() {
        var state = CardAdditionFlowState.importingPhotos
        #expect(state.presentation == .alert)

        state.send(.photoImportSucceeded)
        #expect(state == .dismissingAlert(to: .batchReview))
        #expect(state.presentation == nil)
        state.send(.alertDismissed)
        #expect(state == .batchReview)
    }

    @Test
    func photoImportFailurePresentsMessageOnlyAfterProgressAlertDismissal() {
        let message = CardAdditionMessage(title: "写真の読込み", message: "合成テスト用メッセージ")
        var state = CardAdditionFlowState.importingPhotos

        state.send(.photoImportFailed(message))
        #expect(state == .dismissingAlert(to: .message(message)))
        state.send(.alertDismissed)
        #expect(state == .message(message))
        #expect(state.presentation == .alert)
    }

    @Test
    func pickerCancellationWaitsForDismissalThenReturnsIdle() {
        var state = CardAdditionFlowState.photoPicker(selectionReceived: false)
        state.send(.photoPickerDismissRequested)
        #expect(state == .dismissingPhotoPicker(shouldImport: false))
        state.send(.photoPickerDismissed)
        #expect(state == .idle)
    }

    @Test
    func pendingOCRAlertWaitsForActualDismissalBeforeReview() {
        var state = CardAdditionFlowState.pendingOCRPrompt
        state.send(.resumePendingOCR)

        #expect(state == .dismissingAlert(to: .batchReview))
        #expect(state.presentation == nil)
        state.send(.requestAddition)
        #expect(state == .dismissingAlert(to: .batchReview))

        state.send(.alertDismissed)
        #expect(state == .batchReview)
    }

    @Test
    func launchAlertUsesTheSameRootPresentationStateMachine() {
        var state = CardAdditionFlowState.idle
        state.send(.showLaunchAlert(.grandfatheredAnnouncement))
        #expect(state == .launchAlert(.grandfatheredAnnouncement))
        #expect(state.presentation == .alert)

        state.send(.dismissLaunchAlert)
        #expect(state == .dismissingAlert(to: .idle))
        state.send(.alertDismissed)
        #expect(state == .idle)
    }

    @Test
    func invalidEventsCannotReplaceAnActivePresentation() {
        var state = CardAdditionFlowState.camera
        let message = CardAdditionMessage(title: "合成エラー", message: "合成データ")

        state.send(.requestAddition)
        state.send(.pendingOCRFound)
        state.send(.photoImportSucceeded)
        state.send(.showMessage(message))

        #expect(state == .camera)
        #expect(state.presentation == .fullScreenCover)
    }
}
