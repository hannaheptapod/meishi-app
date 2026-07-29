import SwiftUI
import CoreData

@MainActor
private enum SettingsDateFormatters {
    static let relative: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "ja_JP")
        formatter.unitsStyle = .full
        return formatter
    }()

    static let absolute: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ja_JP")
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter
    }()
}

nonisolated enum SettingsAlertDestination: Equatable, Sendable {
    case restartRequired
    case purchaseRestore(message: String)
}

nonisolated enum SettingsPresentation: Equatable, Sendable {
    case deleteAllConfirmation
    case seedConfirmation
    case paywall
    case alert(SettingsAlertDestination)
}

nonisolated private enum SettingsConfirmationCommit: Equatable, Sendable {
    case deleteAllCards
    case seedSampleData
}

nonisolated private enum SettingsRestoreOutcome: Sendable {
    case restored
    case nothingToRestore
    case failed
}

// 設定画面
struct SettingsView: View {

    @EnvironmentObject private var listViewModel: CardListViewModel
    @EnvironmentObject private var entitlementStore: EntitlementStore
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject private var settings = SettingsStore.shared

    @ObservedObject private var syncMonitor = CloudSyncMonitor.shared

    @State private var modelError: String? = nil
    @State private var isTogglingLock = false
    @State private var isRestoringPurchases = false
    @State private var lockTask: Task<Void, Never>?
    @State private var lockTaskGate = SecondaryViewTaskGate()
    @State private var purchaseRestoreTask: Task<Void, Never>?
    @State private var purchaseRestoreTaskGate = SecondaryViewTaskGate()
    @State private var biometricType: AuthenticationService.BiometricType = .none
    @State private var presentationState = QueuedPresentationState<SettingsPresentation>()
    @State private var confirmationCommitState = DismissalCommitState<SettingsConfirmationCommit>()
    @AppStorage("cloudKitContainerUnavailable")
    private var cloudKitContainerUnavailable = false
#if DEBUG
    @AppStorage(OCRProcessingCoordinator.debugDelayDefaultsKey)
    private var ocrDebugPhaseDelaySeconds = 0.0
#endif

    var body: some View {
        List {
            proSection
            iCloudSection
            securitySection
            advancedLinkSection
            dataSection
#if DEBUG
            debugSection
#endif
            appInfoSection
        }
        .scrollContentBackground(.hidden)
        .background(AppTheme.background)
        .navigationTitle("設定")
        .navigationBarTitleDisplayMode(.large)
        .confirmationDialog(
            settingsConfirmationTitle,
            isPresented: settingsConfirmationBinding,
            titleVisibility: .visible
        ) {
            settingsConfirmationActions
        } message: {
            Text(settingsConfirmationMessage)
        }
        .sheet(item: paywallPresentationBinding, onDismiss: {
            completeSheetDismissal()
        }) { _ in
            PaywallView(context: .general)
                .environmentObject(entitlementStore)
        }
        .alert(item: settingsAlertBinding, content: settingsAlert)
        .background {
            PresentationDismissalObserver(
                activeID: activeNonSheetRequestID,
                dismissingID: dismissingNonSheetRequestID,
                onDismissalCompleted: completeNonSheetPresentationDismissal
            )
            .frame(width: 0, height: 0)
        }
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            biometricType = AuthenticationService.shared.refreshAvailableBiometricType()
        }
        .onDisappear(perform: cancelViewOwnedTasks)
    }

    // MARK: - Pro

    private var proSection: some View {
        Section("eMeishi Pro") {
            if entitlementStore.hasPro {
                Label("Pro 有効", systemImage: "checkmark.seal.fill")
                    .foregroundStyle(.green)
                ManageSubscriptionButton()
            } else if entitlementStore.isGrandfathered {
                Label("既存ユーザー特典（AI 自然言語検索 無料）", systemImage: "person.badge.clock.fill")
                    .foregroundStyle(.secondary)
                    .font(.subheadline)
                Button("Pro の新機能を見る") {
                    presentationState.request(.paywall)
                }
            } else {
                Button("eMeishi Pro にアップグレード") {
                    presentationState.request(.paywall)
                }
                .fontWeight(.semibold)
                .disabled(isRestoringPurchases)
                Button("購入を復元") {
                    startPurchaseRestore()
                }
                .disabled(isRestoringPurchases)
                .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - iCloud 同期

    private var iCloudSection: some View {
        Section {
            Toggle(isOn: iCloudSyncBinding) {
                SettingsStateLabel(
                    title: "iCloud同期",
                    detail: iCloudStatusText(cloudKitFailed: cloudKitContainerUnavailable),
                    systemImage: cloudKitContainerUnavailable ? "exclamationmark.icloud" : "icloud"
                )
            }
            // cloudKitContainerUnavailable フラグが立っている場合は警告を表示
            if settings.iCloudSyncEnabled && cloudKitContainerUnavailable {
                Label("iCloudに接続できません。iCloudにサインインしているか確認してください。", systemImage: "exclamationmark.icloud")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            if PersistenceController.shared.iCloudSyncEnabled && !cloudKitContainerUnavailable {
                if syncMonitor.isSyncing {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("同期中...").foregroundStyle(.secondary)
                    }
                } else if syncMonitor.lastSyncFailed {
                    Label("直前の同期に失敗しました", systemImage: "exclamationmark.icloud")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    Label("自動同期は有効です", systemImage: "checkmark.icloud")
                        .foregroundStyle(.secondary)
                }
                if let date = syncMonitor.lastSyncDate {
                    LabeledContent("最終成功", value: lastSyncText(date))
                }
            }
        } header: {
            Text("iCloud")
        } footer: {
            if settings.iCloudSyncEnabled {
                Text("名刺データが同じApple IDのデバイス間で自動的に同期されます。データはあなたのiCloudアカウントにのみ保存され、開発者がアクセスすることはできません。設定の変更はアプリ再起動後に反映されます。")
            } else {
                Text("有効にすると、名刺データがあなたのiCloudに保存され、同じApple IDのデバイス間で同期されます。データは開発者を含む第三者からアクセスできません。")
            }
        }
    }

    private func lastSyncText(_ date: Date) -> String {
        let now = Date()
        let interval = now.timeIntervalSince(date)
        if interval < 60 {
            return "たった今"
        }
        if interval < 86400 {
            return SettingsDateFormatters.relative.localizedString(for: date, relativeTo: now)
        }
        return SettingsDateFormatters.absolute.string(from: date)
    }

    // MARK: - 高度な設定（リンク）

    private var advancedLinkSection: some View {
        Section {
            NavigationLink {
                AdvancedSettingsView(modelError: $modelError)
            } label: {
                SettingsStateLabel(
                    title: "高度な設定",
                    detail: "読み取り・AIモデル・書き出し",
                    systemImage: "gearshape.2"
                )
            }
        }
    }

    // MARK: - セキュリティ

    private var securitySection: some View {
        Section {
            Toggle(isOn: appLockBinding) {
                SettingsStateLabel(
                    title: appLockLabel,
                    detail: settings.isAppLockEnabled ? "有効" : "無効",
                    systemImage: appLockIcon
                )
            }
            .disabled(isTogglingLock || biometricType == .none)

            if settings.isAppLockEnabled {
                Picker("ロックまでの猶予", selection: $settings.lockGracePeriodSeconds) {
                    Text("即時").tag(0)
                    Text("15秒").tag(15)
                    Text("1分").tag(60)
                    Text("5分").tag(300)
                }
            }
        } header: {
            Text("セキュリティ")
        } footer: {
            if biometricType == .none {
                Text("生体認証が設定されていません。端末の設定から Face ID または Touch ID を有効にしてください。")
            } else {
                Text("有効にすると、アプリを開くときに\(biometricDisplayName)での認証が必要になります。")
            }
        }
    }

    private var biometricDisplayName: String {
        switch biometricType {
        case .faceID:  return "Face ID"
        case .touchID: return "Touch ID"
        case .none:    return "生体認証"
        }
    }

    private var appLockLabel: String {
        switch biometricType {
        case .faceID:  return "Face IDでロック"
        case .touchID: return "Touch IDでロック"
        case .none:    return "生体認証でロック"
        }
    }

    private var appLockIcon: String {
        switch biometricType {
        case .faceID:  return "faceid"
        case .touchID: return "touchid"
        case .none:    return "lock"
        }
    }

    private func iCloudStatusText(cloudKitFailed: Bool) -> String {
        guard settings.iCloudSyncEnabled else { return "無効" }
        if cloudKitFailed { return "接続を確認してください" }
        if syncMonitor.isSyncing { return "同期中" }
        return "有効"
    }

    /// 画面背後の設定値が CloudKit リセット等で更新された場合は通知せず、
    /// ユーザーがこの Toggle を操作した場合だけ再起動案内を提示する。
    private var iCloudSyncBinding: Binding<Bool> {
        Binding(
            get: { settings.iCloudSyncEnabled },
            set: { newValue in
                guard settings.iCloudSyncEnabled != newValue else { return }
                settings.iCloudSyncEnabled = newValue
                presentationState.request(.alert(.restartRequired))
            }
        )
    }

    private var appLockBinding: Binding<Bool> {
        Binding(
            get: { settings.isAppLockEnabled },
            set: { newValue in
                startLockToggle(newValue: newValue)
            }
        )
    }

    private func startPurchaseRestore() {
        guard let operationID = purchaseRestoreTaskGate.begin() else { return }
        isRestoringPurchases = true
        purchaseRestoreTask = Task { @MainActor in
            let outcome: SettingsRestoreOutcome
            do {
                switch try await StoreService.shared.restorePurchases() {
                case .restored:
                    outcome = .restored
                case .nothingToRestore:
                    outcome = .nothingToRestore
                }
            } catch {
                outcome = .failed
            }

            guard !Task.isCancelled,
                  purchaseRestoreTaskGate.finish(operationID) else { return }
            purchaseRestoreTask = nil
            isRestoringPurchases = false

            switch outcome {
            case .restored:
                presentationState.request(
                    .alert(.purchaseRestore(message: "購入情報を復元しました。"))
                )
            case .nothingToRestore:
                presentationState.request(
                    .alert(.purchaseRestore(message: "復元できる購入が見つかりませんでした。"))
                )
            case .failed:
                presentationState.request(
                    .alert(.purchaseRestore(
                        message: "購入情報を復元できませんでした。通信状態を確認して、もう一度お試しください。"
                    ))
                )
            }
        }
    }

    private func startLockToggle(newValue: Bool) {
        guard let operationID = lockTaskGate.begin() else { return }
        isTogglingLock = true
        let reason = newValue
            ? "アプリロックを有効にするために認証してください"
            : "アプリロックを無効にするために認証してください"

        lockTask = Task { @MainActor in
            let success = await AuthenticationService.shared.authenticate(reason: reason)
            guard !Task.isCancelled,
                  lockTaskGate.finish(operationID) else { return }
            lockTask = nil
            isTogglingLock = false
            if success {
                settings.isAppLockEnabled = newValue
            }
        }
    }

    private func cancelViewOwnedTasks() {
        purchaseRestoreTaskGate.cancel()
        purchaseRestoreTask?.cancel()
        purchaseRestoreTask = nil
        isRestoringPurchases = false

        lockTaskGate.cancel()
        lockTask?.cancel()
        lockTask = nil
        isTogglingLock = false

#if DEBUG
        uploadTaskGate.cancel()
        uploadTask?.cancel()
        uploadTask = nil
        isUploading = false
#endif

        confirmationCommitState.removeAll()
        presentationState.removeAll()
    }

    // MARK: - データ管理

    private var dataSection: some View {
        Section("データ管理") {
            Button(role: .destructive) {
                presentationState.request(.deleteAllConfirmation)
            } label: {
                Label("すべての名刺を削除", systemImage: "trash")
            }
            .disabled(isRestoringPurchases)
            if let err = listViewModel.errorMessage {
                Text(err).font(.caption).foregroundStyle(.red)
            }
        }
    }

    // MARK: - 開発者向け（デバッグビルドのみ）

#if DEBUG
    @State private var ckUploadStatus: String = ""
    @State private var isUploading = false
    @State private var uploadTask: Task<Void, Never>?
    @State private var uploadTaskGate = SecondaryViewTaskGate()

    private var debugSection: some View {
        Section("開発者向け") {
            Picker("OCRテスト速度", selection: $ocrDebugPhaseDelaySeconds) {
                Text("通常").tag(0.0)
                Text("低速（各段階3秒）").tag(3.0)
                Text("非常に低速（各段階10秒）").tag(10.0)
            }
            Text("進捗・残り時間・バックグラウンド表示の確認用です。実測時間の学習には人工遅延を含めません。")
                .font(.caption)
                .foregroundStyle(.secondary)

            Button {
                presentationState.request(.seedConfirmation)
            } label: {
                Label("サンプルデータを50件挿入", systemImage: "doc.badge.plus")
            }
            .disabled(isRestoringPurchases)
            Button {
                startDebugModelUpload()
            } label: {
                Label("CloudKit モデルを正しいバージョンに更新", systemImage: "icloud.and.arrow.up")
            }
            .disabled(isUploading)
            if !ckUploadStatus.isEmpty {
                Text(ckUploadStatus).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    /// デバッグ専用アップロードは画面所有の操作として扱い、画面終了時に取消す。
    /// status callbackにも操作IDを要求し、取消後の表示更新を拒否する。
    private func startDebugModelUpload() {
        guard let operationID = uploadTaskGate.begin() else { return }
        isUploading = true
        ckUploadStatus = "アップロード中..."
        uploadTask = Task { @MainActor in
            await CloudKitModelUploader.uploadCorrectModels { status in
                guard uploadTaskGate.accepts(operationID) else { return }
                ckUploadStatus = status
            }
            guard !Task.isCancelled,
                  uploadTaskGate.finish(operationID) else { return }
            uploadTask = nil
            isUploading = false
        }
    }
#endif

    // MARK: - アプリ情報

    private var appInfoSection: some View {
        Section("アプリ情報") {
            if let privacyURL = URL(
                string: "https://hannaheptapod.github.io/meishi-app/privacy-policy.html"
            ) {
                Link(destination: privacyURL) {
                    Label("プライバシーポリシー", systemImage: "hand.raised")
                }
            }
            if let supportURL = URL(
                string: "https://hannaheptapod.github.io/meishi-app/support.html"
            ) {
                Link(destination: supportURL) {
                    Label("サポート", systemImage: "questionmark.circle")
                }
            }
            LabeledContent("バージョン", value: appVersion)
        }
    }

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
    }

    private var settingsConfirmationBinding: Binding<Bool> {
        Binding(
            get: { activeSettingsConfirmation != nil },
            set: { isPresented in
                guard !isPresented, activeSettingsConfirmation != nil else { return }
                finishActivePresentation()
            }
        )
    }

    private var activeSettingsConfirmation: SettingsPresentation? {
        guard let destination = presentationState.active?.destination else { return nil }
        switch destination {
        case .deleteAllConfirmation, .seedConfirmation:
            return destination
        case .paywall, .alert:
            return nil
        }
    }

    private var settingsConfirmationTitle: String {
        switch activeSettingsConfirmation {
        case .deleteAllConfirmation:
            return "すべての名刺を削除しますか？"
        case .seedConfirmation:
            return "サンプル名刺を50件追加しますか？"
        case .paywall, .alert, nil:
            return ""
        }
    }

    private var settingsConfirmationMessage: String {
        switch activeSettingsConfirmation {
        case .deleteAllConfirmation:
            return "この操作は取り消せません。"
        case .seedConfirmation:
            return "既存のデータは削除されません。"
        case .paywall, .alert, nil:
            return ""
        }
    }

    @ViewBuilder
    private var settingsConfirmationActions: some View {
        switch activeSettingsConfirmation {
        case .deleteAllConfirmation:
            Button("すべて削除", role: .destructive) {
                scheduleConfirmationCommit(.deleteAllCards)
            }
        case .seedConfirmation:
#if DEBUG
            Button("挿入") {
                scheduleConfirmationCommit(.seedSampleData)
            }
#endif
        case .paywall, .alert, nil:
            EmptyView()
        }
    }

    private var paywallPresentationBinding: Binding<QueuedPresentationRequest<SettingsPresentation>?> {
        Binding(
            get: {
                guard let active = presentationState.active,
                      active.destination == .paywall
                else { return nil }
                return active
            },
            set: { newValue in
                guard newValue == nil,
                      let active = presentationState.active,
                      active.destination == .paywall
                else { return }
                _ = presentationState.clearActive(requestID: active.id)
            }
        )
    }

    private var settingsAlertBinding: Binding<QueuedPresentationRequest<SettingsPresentation>?> {
        Binding(
            get: {
                guard let active = presentationState.active,
                      case .alert = active.destination
                else { return nil }
                return active
            },
            set: { newValue in
                guard newValue == nil,
                      let active = presentationState.active,
                      case .alert = active.destination
                else { return }
                finishActivePresentation(expectedID: active.id)
            }
        )
    }

    private func finishActivePresentation(expectedID: UUID? = nil) {
        guard let active = presentationState.active,
              expectedID == nil || active.id == expectedID,
              presentationState.clearActive(requestID: active.id)
        else { return }

    }

    private var activeNonSheetRequestID: UUID? {
        guard let request = presentationState.active else { return nil }
        if case .paywall = request.destination { return nil }
        return request.id
    }

    private var dismissingNonSheetRequestID: UUID? {
        guard let request = presentationState.dismissing else { return nil }
        if case .paywall = request.destination { return nil }
        return request.id
    }

    private func completeNonSheetPresentationDismissal(requestID: UUID) {
        let commit = confirmationCommitState.take(afterDismissing: requestID)
        if let commit {
            performConfirmationCommit(commit)
        }
        presentationState.presentNext(afterDismissing: requestID)
    }

    /// 破壊的なデータ更新は確認ダイアログの背後で開始せず、
    /// UIKit が実 dismissal を通知した後にだけ実行する。
    private func scheduleConfirmationCommit(_ action: SettingsConfirmationCommit) {
        guard let active = presentationState.active else { return }
        switch active.destination {
        case .deleteAllConfirmation, .seedConfirmation:
            guard confirmationCommitState.schedule(action, for: active.id) else { return }
            finishActivePresentation(expectedID: active.id)
        case .paywall, .alert:
            break
        }
    }

    private func performConfirmationCommit(_ action: SettingsConfirmationCommit) {
        switch action {
        case .deleteAllCards:
            listViewModel.deleteAllCards()
        case .seedSampleData:
#if DEBUG
            listViewModel.seedSampleData()
#endif
        }
    }

    /// sheetは実際のdismiss animation完了後にだけ次のpresentationへ進める。
    private func completeSheetDismissal() {
        guard let requestID = presentationState.dismissing?.id else { return }
        presentationState.presentNext(afterDismissing: requestID)
    }

    private func settingsAlert(
        _ request: QueuedPresentationRequest<SettingsPresentation>
    ) -> Alert {
        guard case .alert(let destination) = request.destination else {
            return Alert(
                title: Text("エラー"),
                dismissButton: .cancel(Text("OK"))
            )
        }

        switch destination {
        case .restartRequired:
            return Alert(
                title: Text("アプリの再起動が必要です"),
                message: Text("iCloud同期の設定変更はアプリを再起動すると反映されます。"),
                dismissButton: .default(Text("OK"))
            )
        case .purchaseRestore(let message):
            return Alert(
                title: Text("購入の復元"),
                message: Text(message),
                dismissButton: .cancel(Text("OK"))
            )
        }
    }

}

private struct SettingsStateLabel: View {
    let title: String
    let detail: String
    let systemImage: String

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .foregroundStyle(.primary)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: systemImage)
                .symbolRenderingMode(.monochrome)
                .foregroundStyle(.secondary)
        }
    }
}

#Preview {
    SettingsView()
        .environmentObject(CardListViewModel())
        .environmentObject(EntitlementStore.shared)
}
