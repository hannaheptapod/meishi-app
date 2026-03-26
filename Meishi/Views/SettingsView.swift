import SwiftUI
import CoreData
import FoundationModels

// 設定画面
struct SettingsView: View {

    @EnvironmentObject private var listViewModel: CardListViewModel
    @ObservedObject private var settings = SettingsStore.shared
    @ObservedObject private var llm = LocalLLMService.shared

    @Environment(\.dismiss) private var dismiss

    @State private var showDeleteAllConfirm = false
    @State private var modelError: String? = nil
#if DEBUG
    @State private var showSeedConfirm = false
#endif

    var body: some View {
        NavigationStack {
            List {
                readingSection
                duplicateCheckSection
                exportSection
                dataSection
#if DEBUG
                debugSection
#endif
                appInfoSection
            }
            .navigationTitle("設定")
            .navigationBarTitleDisplayMode(.inline)
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

    // MARK: - 名刺の読み取り

    private var readingSection: some View {
        Section {
            // 自動
            readingMethodRow(.automatic, icon: "wand.and.sparkles") {
                EmptyView()
            }

            // Apple Intelligence
            if #available(iOS 18.0, *) {
                readingMethodRow(.appleIntelligence, icon: "apple.intelligence") {
                    appleIntelligenceStatusText
                }
            } else {
                readingMethodRow(.appleIntelligence, icon: "brain") {
                    Text("非対応").foregroundStyle(.secondary)
                }
            }

            // AIアシスト（ダウンロード管理付き）
            aiAssistRow

            // 標準読み取り
            readingMethodRow(.classifier, icon: "text.magnifyingglass") {
                Text("利用可能").foregroundStyle(.secondary)
            }

            if let err = modelError {
                Text(err).font(.caption).foregroundStyle(.red)
            }

        } header: {
            Text("名刺の読み取り")
        } footer: {
            Text("撮影した名刺の文字を自動でフィールドに振り分けます。「自動」は上から順に利用できるエンジンを使用します。")
        }
    }

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
                    do {
                        try llm.deleteModel()
                    } catch {
                        modelError = error.localizedDescription
                    }
                } label: {
                    Label("削除", systemImage: "trash")
                }
            }
        }
    }

    // MARK: - 重複チェック

    private var duplicateCheckSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("検出感度")
                    Spacer()
                    Text(thresholdLabel).foregroundStyle(.secondary)
                }
                Slider(value: $settings.duplicateThreshold, in: 0.5...1.0, step: 0.05)
            }
        } header: {
            Text("重複チェック")
        } footer: {
            Text("「低」にするほど名前が少し違っていても重複として検出します。「高」にするほど完全一致に近い場合のみ検出します。")
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

    // MARK: - 書き出し

    private var exportSection: some View {
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

    // MARK: - データ管理

    private var dataSection: some View {
        Section("データ管理") {
            Button(role: .destructive) {
                showDeleteAllConfirm = true
            } label: {
                Label("すべての名刺を削除", systemImage: "trash")
            }
            .confirmationDialog("すべての名刺を削除しますか？", isPresented: $showDeleteAllConfirm, titleVisibility: .visible) {
                Button("すべて削除", role: .destructive) { listViewModel.deleteAllCards() }
            } message: {
                Text("この操作は取り消せません。")
            }
            if let err = listViewModel.errorMessage {
                Text(err).font(.caption).foregroundStyle(.red)
            }
        }
    }

    // MARK: - 開発者向け（デバッグビルドのみ）

#if DEBUG
    private var debugSection: some View {
        Section("開発者向け") {
            Button {
                showSeedConfirm = true
            } label: {
                Label("サンプルデータを50件挿入", systemImage: "doc.badge.plus")
            }
            .confirmationDialog(
                "サンプル名刺を50件追加しますか？",
                isPresented: $showSeedConfirm,
                titleVisibility: .visible
            ) {
                Button("挿入") { listViewModel.seedSampleData() }
            } message: {
                Text("既存のデータは削除されません。")
            }
        }
    }
#endif

    // MARK: - アプリ情報

    private var appInfoSection: some View {
        Section("アプリ情報") {
            LabeledContent("バージョン", value: appVersion)
            LabeledContent("ビルド", value: buildNumber)
        }
    }

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
    }
    private var buildNumber: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—"
    }

}

#Preview {
    SettingsView()
        .environmentObject(CardListViewModel())
}
