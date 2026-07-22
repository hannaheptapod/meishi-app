import SwiftUI
import CoreData

// 設定画面
struct SettingsView: View {

    @EnvironmentObject private var listViewModel: CardListViewModel
    @EnvironmentObject private var entitlementStore: EntitlementStore
    @ObservedObject private var settings = SettingsStore.shared

    @ObservedObject private var syncMonitor = CloudSyncMonitor.shared

    @State private var showDeleteAllConfirm = false
    @State private var modelError: String? = nil
    @State private var isTogglingLock = false
    @State private var isShowingPaywall = false
    @State private var isRestoringPurchases = false
    @State private var purchaseRestoreMessage: String?
#if DEBUG
    @State private var showSeedConfirm = false
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
        .confirmationDialog("すべての名刺を削除しますか？", isPresented: $showDeleteAllConfirm, titleVisibility: .visible) {
            Button("すべて削除", role: .destructive) { listViewModel.deleteAllCards() }
        } message: {
            Text("この操作は取り消せません。")
        }
#if DEBUG
        .confirmationDialog("サンプル名刺を50件追加しますか？", isPresented: $showSeedConfirm, titleVisibility: .visible) {
            Button("挿入") { listViewModel.seedSampleData() }
        } message: {
            Text("既存のデータは削除されません。")
        }
#endif
        .sheet(isPresented: $isShowingPaywall) {
            PaywallView(context: .general)
                .environmentObject(entitlementStore)
        }
        .alert(
            "購入の復元",
            isPresented: Binding(
                get: { purchaseRestoreMessage != nil },
                set: { if !$0 { purchaseRestoreMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(purchaseRestoreMessage ?? "")
        }
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
                    isShowingPaywall = true
                }
            } else {
                Button("eMeishi Pro にアップグレード") {
                    isShowingPaywall = true
                }
                .fontWeight(.semibold)
                Button("購入を復元") {
                    guard !isRestoringPurchases else { return }
                    isRestoringPurchases = true
                    Task {
                        defer { isRestoringPurchases = false }
                        do {
                            switch try await StoreService.shared.restorePurchases() {
                            case .restored:
                                purchaseRestoreMessage = "購入情報を復元しました。"
                            case .nothingToRestore:
                                purchaseRestoreMessage = "復元できる購入が見つかりませんでした。"
                            }
                        } catch {
                            purchaseRestoreMessage = "購入情報を復元できませんでした。通信状態を確認して、もう一度お試しください。"
                        }
                    }
                }
                .disabled(isRestoringPurchases)
                .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - iCloud 同期

    @State private var showRestartAlert = false

    private var iCloudSection: some View {
        let cloudKitFailed = UserDefaults.standard.bool(forKey: "cloudKitContainerUnavailable")

        return Section {
            Toggle(isOn: $settings.iCloudSyncEnabled) {
                SettingsStateLabel(
                    title: "iCloud同期",
                    detail: iCloudStatusText(cloudKitFailed: cloudKitFailed),
                    systemImage: cloudKitFailed ? "exclamationmark.icloud" : "icloud"
                )
            }
            .onChange(of: settings.iCloudSyncEnabled) {
                showRestartAlert = true
            }
            // cloudKitContainerUnavailable フラグが立っている場合は警告を表示
            if settings.iCloudSyncEnabled && cloudKitFailed {
                Label("iCloudに接続できません。iCloudにサインインしているか確認してください。", systemImage: "exclamationmark.icloud")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            if PersistenceController.shared.iCloudSyncEnabled && !cloudKitFailed {
                if syncMonitor.isSyncing {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("同期中...").foregroundStyle(.secondary)
                    }
                } else {
                    Button {
                        syncMonitor.triggerSync()
                    } label: {
                        Label("今すぐ同期", systemImage: "arrow.triangle.2.circlepath.icloud")
                    }
                }
                if let date = syncMonitor.lastSyncDate {
                    LabeledContent("最終同期", value: lastSyncText(date))
                } else if syncMonitor.lastSyncFailed {
                    Label("同期に失敗しました", systemImage: "exclamationmark.icloud")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
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
        .alert("アプリの再起動が必要です", isPresented: $showRestartAlert) {
            Button("OK") {}
        } message: {
            Text("iCloud同期の設定変更はアプリを再起動すると反映されます。")
        }
    }

    private func lastSyncText(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "ja_JP")
        formatter.unitsStyle = .full
        let interval = Date().timeIntervalSince(date)
        if interval < 60 {
            return "たった今"
        }
        if interval < 86400 {
            return formatter.localizedString(for: date, relativeTo: Date())
        }
        let df = DateFormatter()
        df.locale = Locale(identifier: "ja_JP")
        df.dateStyle = .short
        df.timeStyle = .short
        return df.string(from: date)
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

    private var biometricType: AuthenticationService.BiometricType {
        AuthenticationService.shared.availableBiometricType()
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

    private var appLockBinding: Binding<Bool> {
        Binding(
            get: { settings.isAppLockEnabled },
            set: { newValue in
                isTogglingLock = true
                Task {
                    let reason = newValue
                        ? "アプリロックを有効にするために認証してください"
                        : "アプリロックを無効にするために認証してください"
                    let success = await AuthenticationService.shared.authenticate(reason: reason)
                    if success {
                        settings.isAppLockEnabled = newValue
                    }
                    isTogglingLock = false
                }
            }
        )
    }

    // MARK: - データ管理

    private var dataSection: some View {
        Section("データ管理") {
            Button(role: .destructive) {
                showDeleteAllConfirm = true
            } label: {
                Label("すべての名刺を削除", systemImage: "trash")
            }
            if let err = listViewModel.errorMessage {
                Text(err).font(.caption).foregroundStyle(.red)
            }
        }
    }

    // MARK: - 開発者向け（デバッグビルドのみ）

#if DEBUG
    @State private var ckUploadStatus: String = ""
    @State private var isUploading = false

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
                showSeedConfirm = true
            } label: {
                Label("サンプルデータを50件挿入", systemImage: "doc.badge.plus")
            }
            Button {
                isUploading = true
                ckUploadStatus = "アップロード中..."
                Task {
                    await CloudKitModelUploader.uploadCorrectModels { status in
                        ckUploadStatus = status
                        if !status.contains("中") { isUploading = false }
                    }
                }
            } label: {
                Label("CloudKit モデルを正しいバージョンに更新", systemImage: "icloud.and.arrow.up")
            }
            .disabled(isUploading)
            if !ckUploadStatus.isEmpty {
                Text(ckUploadStatus).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
#endif

    // MARK: - アプリ情報

    private var appInfoSection: some View {
        Section("アプリ情報") {
            Link(destination: URL(string: "https://hannaheptapod.github.io/meishi-app/privacy-policy.html")!) {
                Label("プライバシーポリシー", systemImage: "hand.raised")
            }
            Link(destination: URL(string: "https://hannaheptapod.github.io/meishi-app/support.html")!) {
                Label("サポート", systemImage: "questionmark.circle")
            }
            LabeledContent("バージョン", value: appVersion)
        }
    }

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
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
