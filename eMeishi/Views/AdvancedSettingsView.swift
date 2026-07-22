import SwiftUI
import FoundationModels

// MARK: - 高度な設定画面

struct AdvancedSettingsView: View {

    @ObservedObject private var settings = SettingsStore.shared
    @ObservedObject private var llm = LocalLLMService.shared
    @ObservedObject private var zoneReset = CloudKitZoneResetService.shared
    @Binding var modelError: String?
    @State private var showZoneResetConfirm = false
    @State private var showZoneResetResult = false
    @State private var zoneResetSucceeded = false

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

                NavigationLink {
                    ModelManagementView(modelError: $modelError)
                } label: {
                    HStack {
                        Label("AIモデル管理", systemImage: "externaldrive.badge.sparkles")
                        Spacer()
                        Text(llm.isModelAvailable ? "利用可能" : (llm.isDownloading ? "取得中" : "未取得"))
                            .foregroundStyle(.secondary)
                    }
                }

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

            // iCloud 同期のトラブルシューティング
            Section {
                Button(role: .destructive) {
                    showZoneResetConfirm = true
                } label: {
                    if zoneReset.isResetting {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("リセット中...").foregroundStyle(.secondary)
                        }
                    } else {
                        Label("iCloud同期をリセット", systemImage: "arrow.counterclockwise.icloud")
                    }
                }
                .disabled(zoneReset.isResetting)
                if let err = zoneReset.lastError {
                    Text(err).font(.caption).foregroundStyle(.red)
                }
            } header: {
                Text("iCloud")
            } footer: {
                Text("同期の不具合が続く場合のみ使用してください。iCloud上の名刺データを削除します。この端末のローカルデータは残ります。他のデバイスでiCloud同期を有効にしていると、そちらのクラウド側データも影響を受けます。")
            }
        }
        .navigationTitle("高度な設定")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog(
            "iCloud同期をリセットしますか？",
            isPresented: $showZoneResetConfirm,
            titleVisibility: .visible
        ) {
            Button("リセット", role: .destructive) {
                Task {
                    let ok = await zoneReset.resetCoreDataZone()
                    zoneResetSucceeded = ok
                    if ok { settings.iCloudSyncEnabled = false }
                    showZoneResetResult = true
                }
            }
        } message: {
            Text("この操作は取り消せません。実行後はアプリを再起動する必要があります。")
        }
        .alert(
            zoneResetSucceeded ? "リセットしました" : "リセットに失敗しました",
            isPresented: $showZoneResetResult
        ) {
            Button("OK") {}
        } message: {
            if zoneResetSucceeded {
                Text("iCloud上のデータを削除しました。アプリを再起動してからiCloud同期を有効にすると、ローカルのデータがクラウドに再アップロードされます。")
            } else {
                Text(zoneReset.lastError ?? "時間をおいて再度お試しください。")
            }
        }
    }

    // MARK: - 読み取り方法行

    @ViewBuilder
    private func readingMethodRow<S: View>(
        _ method: ReadingMethod,
        icon: String,
        @ViewBuilder status: () -> S
    ) -> some View {
        Button {
            settings.readingMethod = method
        } label: {
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
                        .padding(.leading, AppTheme.Spacing.xSmall)
                }
            }
            .foregroundStyle(.primary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(settings.readingMethod == method ? .isSelected : [])
    }

    @available(iOS 18.0, *)
    private var appleIntelligenceStatusText: some View {
        switch SystemLanguageModel.default.availability {
        case .available:
            return Text("利用可能").foregroundStyle(.secondary)
        case .unavailable(.deviceNotEligible):
            return Text("非対応").foregroundStyle(.secondary)
        case .unavailable(.appleIntelligenceNotEnabled):
            return Text("オフ").foregroundStyle(.secondary)
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
