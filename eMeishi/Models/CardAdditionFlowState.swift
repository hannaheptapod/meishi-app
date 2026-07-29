import Foundation

/// 名刺追加フローでユーザーが選択できる開始方法。
nonisolated enum CardAdditionAction: Equatable, Sendable {
    case camera
    case photos
    case manual
    case resumePendingOCR
}

/// カメラを閉じた後に遷移する画面。
nonisolated enum CardAdditionPostCameraDestination: Equatable, Sendable {
    case idle
    case prepareBatch
}

/// sheet の実dismiss完了後に開始する処理。
nonisolated enum CardAdditionPostSheetDestination: Equatable, Sendable {
    case idle
    case preservePendingOCR
    case action(CardAdditionAction)
}

/// alert の実dismiss完了後に開始する処理。
nonisolated enum CardAdditionPostAlertDestination: Equatable, Sendable {
    case idle
    case batchReview
}

/// 名刺追加フローで表示するエラー。表示状態に値を含めることで、
/// メッセージ用の別Boolと表示内容がずれることを防ぐ。
nonisolated struct CardAdditionMessage: Equatable, Sendable, Identifiable {
    let title: String
    let message: String

    var id: String { "\(title)\u{0}\(message)" }
}

/// 名刺追加フローの排他的な表示状態。
///
/// `dismissing*` は presentation が画面階層から外れるまで保持する。
/// Binding が false/nil になった瞬間を完了扱いせず、sheet は `onDismiss`、
/// alert / PhotosPicker は `PresentationDismissalObserver` の完了通知で次へ進む。
nonisolated enum CardAdditionFlowState: Equatable, Sendable {
    case idle
    case chooser
    case aiSearchPaywall
    case manualForm
    case batchReview
    case dismissingSheet(to: CardAdditionPostSheetDestination)

    case camera
    case dismissingCamera(to: CardAdditionPostCameraDestination)
    case preparingCameraBatch
    case cancellingBatch

    case photoPicker(selectionReceived: Bool)
    case dismissingPhotoPicker(shouldImport: Bool)
    case importingPhotos

    case pendingOCRPrompt
    case launchAlert(AppLaunchAlert)
    case message(CardAdditionMessage)
    case dismissingAlert(to: CardAdditionPostAlertDestination)

    enum Presentation: Equatable, Sendable {
        case sheet
        case fullScreenCover
        case photoPicker
        case alert
    }

    var presentation: Presentation? {
        switch self {
        case .chooser, .aiSearchPaywall, .manualForm, .batchReview:
            .sheet
        case .camera:
            .fullScreenCover
        case .photoPicker:
            .photoPicker
        case .pendingOCRPrompt, .launchAlert, .message:
            .alert
        case .idle, .dismissingSheet, .dismissingCamera, .preparingCameraBatch,
             .cancellingBatch, .dismissingPhotoPicker, .importingPhotos, .dismissingAlert:
            nil
        }
    }

    mutating func send(_ event: CardAdditionFlowEvent) {
        switch (self, event) {
        case (.idle, .requestAddition):
            self = .chooser

        case (.idle, .requestAISearchPaywall):
            self = .aiSearchPaywall

        case (.idle, .showLaunchAlert(let alert)):
            self = .launchAlert(alert)

        case (.chooser, .selectAction(let action)):
            self = .dismissingSheet(to: .action(action))

        case (.chooser, .sheetDismissRequested),
             (.aiSearchPaywall, .sheetDismissRequested),
             (.manualForm, .sheetDismissRequested):
            self = .dismissingSheet(to: .idle)

        case (.batchReview, .sheetDismissRequested):
            self = .dismissingSheet(to: .preservePendingOCR)

        case (.manualForm, .manualFinished),
             (.batchReview, .batchFinished):
            self = .dismissingSheet(to: .idle)

        case (.dismissingSheet(let destination), .sheetDismissed):
            switch destination {
            case .idle, .preservePendingOCR:
                self = .idle
            case .action(let action):
                switch action {
                case .camera:
                    self = .camera
                case .photos:
                    self = .photoPicker(selectionReceived: false)
                case .manual:
                    self = .manualForm
                case .resumePendingOCR:
                    self = .batchReview
                }
            }

        case (.photoPicker(let alreadyReceived), .photoSelectionChanged(let hasItems)):
            self = .dismissingPhotoPicker(shouldImport: alreadyReceived || hasItems)

        case (.photoPicker(let selectionReceived), .photoPickerDismissRequested):
            self = .dismissingPhotoPicker(shouldImport: selectionReceived)

        // PhotosPicker は選択値更新と isPresented=false の通知順を保証しない。
        // dismiss開始後に選択値が届いた場合も、その事実だけを同じ状態へ反映する。
        case (.dismissingPhotoPicker(let shouldImport), .photoSelectionChanged(let hasItems)):
            self = .dismissingPhotoPicker(shouldImport: shouldImport || hasItems)

        case (.dismissingPhotoPicker(let shouldImport), .photoPickerDismissed):
            self = shouldImport ? .importingPhotos : .idle

        case (.importingPhotos, .photoImportSucceeded):
            self = .batchReview

        case (.importingPhotos, .photoImportFailed(let message)):
            self = .message(message)

        case (.camera, .cameraFinished(let hasImages)):
            self = .dismissingCamera(to: hasImages ? .prepareBatch : .idle)

        case (.dismissingCamera(let destination), .cameraDismissed):
            switch destination {
            case .idle:
                self = .idle
            case .prepareBatch:
                self = .preparingCameraBatch
            }

        case (.preparingCameraBatch, .cameraPreparationSucceeded),
             (.preparingCameraBatch, .cameraPreparationFailed):
            self = .batchReview

        case (.idle, .pendingOCRFound):
            self = .pendingOCRPrompt

        case (.pendingOCRPrompt, .resumePendingOCR):
            self = .dismissingAlert(to: .batchReview)

        case (.pendingOCRPrompt, .discardPendingOCR),
             (.pendingOCRPrompt, .dismissAlert),
             (.message, .dismissMessage),
             (.launchAlert, .dismissLaunchAlert):
            self = .dismissingAlert(to: .idle)

        case (.dismissingAlert(let destination), .alertDismissed):
            switch destination {
            case .idle:
                self = .idle
            case .batchReview:
                self = .batchReview
            }

        case (.idle, .showMessage(let message)),
             (.importingPhotos, .showMessage(let message)):
            self = .message(message)

        // 永続キューを破棄し終えるまでは次の追加処理を開始しない。
        case (.preparingCameraBatch, .beginBatchCancellation),
             (.importingPhotos, .beginBatchCancellation):
            self = .cancellingBatch

        case (.cancellingBatch, .batchCancellationCompleted):
            self = .idle

        // 互換用。永続キューを持たないidleだけは即時に中止できる。
        case (.preparingCameraBatch, .cancel),
             (.importingPhotos, .cancel),
             (.idle, .cancel):
            self = .idle

        default:
            break
        }
    }
}

nonisolated enum CardAdditionFlowEvent: Equatable, Sendable {
    case requestAddition
    case requestAISearchPaywall
    case showLaunchAlert(AppLaunchAlert)
    case selectAction(CardAdditionAction)
    case sheetDismissRequested
    case sheetDismissed
    case photoSelectionChanged(hasItems: Bool)
    case photoPickerDismissRequested
    case photoPickerDismissed
    case photoImportSucceeded
    case photoImportFailed(CardAdditionMessage)
    case cameraFinished(hasImages: Bool)
    case cameraDismissed
    case cameraPreparationSucceeded
    case cameraPreparationFailed
    case manualFinished
    case batchFinished
    case pendingOCRFound
    case resumePendingOCR
    case discardPendingOCR
    case showMessage(CardAdditionMessage)
    case dismissMessage
    case dismissLaunchAlert
    case dismissAlert
    case alertDismissed
    case cancel
    case beginBatchCancellation
    case batchCancellationCompleted
}
