import SwiftUI
import CoreData
import FoundationModels

// 設定画面
struct SettingsView: View {

    @EnvironmentObject private var listViewModel: CardListViewModel
    @EnvironmentObject private var entitlementStore: EntitlementStore
    @ObservedObject private var settings = SettingsStore.shared

    @Environment(\.dismiss) private var dismiss

    @State private var showDeleteAllConfirm = false
    @State private var modelError: String? = nil
    @State private var isTogglingLock = false
    @State private var isShowingPaywall = false
#if DEBUG
    @State private var showSeedConfirm = false
#endif

    var body: some View {
        NavigationStack {
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
            .navigationTitle("設定")
            .navigationBarTitleDisplayMode(.inline)
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
                PaywallView(context: .aiSearch)
                    .environmentObject(entitlementStore)
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                    }
                }
            }
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
                    Task { await StoreService.shared.restorePurchases() }
                }
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
                Label("iCloud同期", systemImage: "icloud")
            }
            .onChange(of: settings.iCloudSyncEnabled) {
                showRestartAlert = true
            }
            // cloudKitContainerUnavailable フラグが立っている場合は警告を表示
            if settings.iCloudSyncEnabled && cloudKitFailed {
                Label("iCloudに接続できません。iCloudにサインインしているか確認してください。", systemImage: "exclamationmark.icloud")
                    .font(.footnote)
                    .foregroundStyle(.orange)
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

    // MARK: - 高度な設定（リンク）

    private var advancedLinkSection: some View {
        Section {
            NavigationLink {
                AdvancedSettingsView(modelError: $modelError)
            } label: {
                Label("高度な設定", systemImage: "gearshape.2")
            }
        }
    }

    // MARK: - セキュリティ

    private var securitySection: some View {
        Section {
            Toggle(isOn: appLockBinding) {
                Label(appLockLabel, systemImage: appLockIcon)
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

// MARK: - 高度な設定画面

private struct AdvancedSettingsView: View {

    @ObservedObject private var settings = SettingsStore.shared
    @ObservedObject private var llm = LocalLLMService.shared
    @Binding var modelError: String?
    @State private var showDeleteModelConfirm = false

    var body: some View {
        List {
            // AIエンジン
            Section {
                readingMethodRow(.automatic, icon: "wand.and.sparkles") {
                    EmptyView()
                }

                if #available(iOS 18.0, *) {
                    readingMethodRow(.appleIntelligence, icon: "apple.intelligence") {
                        appleIntelligenceStatusText
                    }
                } else {
                    readingMethodRow(.appleIntelligence, icon: "brain") {
                        Text("非対応").foregroundStyle(.secondary)
                    }
                }

                aiAssistRow

                if let err = modelError {
                    Text(err).font(.caption).foregroundStyle(.red)
                }
            } header: {
                Text("AIエンジン")
            } footer: {
                Text("名刺の分析やAI検索に使用するエンジンを選択します。「自動」は利用できる最高精度のエンジンを使用します。")
            }

            // 重複検出
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("検出感度")
                        Spacer()
                        Text(thresholdLabel).foregroundStyle(.secondary)
                    }
                    Slider(value: $settings.duplicateThreshold, in: 0.5...1.0, step: 0.05)
                        .accessibilityLabel("重複検出感度")
                        .accessibilityValue(thresholdLabel)
                }
            } header: {
                Text("重複チェック")
            } footer: {
                Text("「低」にするほど名前が少し違っていても重複として検出します。「高」にするほど完全一致に近い場合のみ検出します。")
            }

            // 書き出し
            Section {
                Toggle("Excelで開けるCSV形式にする", isOn: $settings.csvIncludesBOM)
                Picker("連絡先ファイルの形式", selection: $settings.vCardVersion) {
                    Text("vCard 3.0（標準）").tag("3.0")
                    Text("vCard 4.0").tag("4.0")
                }
            } header: {
                Text("書き出し")
            }
        }
        .navigationTitle("高度な設定")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("AIデータを削除しますか？", isPresented: $showDeleteModelConfirm, titleVisibility: .visible) {
            Button("削除", role: .destructive) {
                do {
                    try llm.deleteModel()
                } catch {
                    modelError = error.localizedDescription
                }
            }
        } message: {
            Text("削除すると自動モードに切り替わります。再ダウンロードはいつでも可能です。")
        }
    }

    // MARK: - 読み取り方法行

    @ViewBuilder
    private func readingMethodRow<S: View>(
        _ method: ReadingMethod,
        icon: String,
        @ViewBuilder status: () -> S
    ) -> some View {
        HStack {
            Label(method.displayName, systemImage: icon)
                .symbolRenderingMode(.monochrome)
            Spacer()
            if settings.readingMethod != method {
                status()
            }
            if settings.readingMethod == method {
                Image(systemName: "checkmark")
                    .foregroundStyle(Color.accentColor)
                    .fontWeight(.semibold)
                    .padding(.leading, 4)
            }
        }
        .foregroundStyle(.primary)
        .contentShape(Rectangle())
        .onTapGesture {
            settings.readingMethod = method
        }
    }

    private var aiAssistRow: some View {
        HStack {
            Label("AIアシスト", systemImage: "sparkles")
                .symbolRenderingMode(.monochrome)
                .foregroundStyle(.primary)
            Spacer()

            if settings.readingMethod != .localLLM {
                if llm.isDownloading {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("\(Int(llm.downloadProgress * 100))%")
                            .foregroundStyle(.secondary)
                    }
                } else if llm.isModelAvailable {
                    Text("利用可能").foregroundStyle(.secondary)
                } else {
                    HStack(spacing: 8) {
                        Text("未取得").foregroundStyle(.secondary)
                        Button("取得する") {
                            Task {
                                do {
                                    try await llm.downloadModel()
                                } catch {
                                    modelError = error.localizedDescription
                                }
                            }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)

                    }
                }
            }

            if settings.readingMethod == .localLLM {
                Image(systemName: "checkmark")
                    .foregroundStyle(Color.accentColor)
                    .fontWeight(.semibold)
                    .padding(.leading, 4)
            }
        }
        .foregroundStyle(.primary)
        .contentShape(Rectangle())
        .onTapGesture {
            settings.readingMethod = .localLLM
        }
        .swipeActions(edge: .trailing) {
            if llm.isModelAvailable {
                Button(role: .destructive) {
                    showDeleteModelConfirm = true
                } label: {
                    Label("削除", systemImage: "trash")
                }
            }
        }
    }

    @available(iOS 18.0, *)
    private var appleIntelligenceStatusText: some View {
        switch SystemLanguageModel.default.availability {
        case .available:
            return Text("利用可能").foregroundStyle(.secondary)
        case .unavailable(.deviceNotEligible):
            return Text("非対応").foregroundStyle(.secondary)
        case .unavailable(.appleIntelligenceNotEnabled):
            return Text("オフ").foregroundStyle(.orange)
        case .unavailable(.modelNotReady):
            return Text("準備中").foregroundStyle(.secondary)
        default:
            return Text("利用不可").foregroundStyle(.secondary)
        }
    }

    private var thresholdLabel: String {
        switch settings.duplicateThreshold {
        case ..<0.65: return "低"
        case ..<0.80: return "中"
        default:      return "高"
        }
    }
}

#Preview {
    SettingsView()
        .environmentObject(CardListViewModel())
}
