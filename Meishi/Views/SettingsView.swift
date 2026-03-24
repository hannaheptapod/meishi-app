import SwiftUI
import CoreData
import FoundationModels

// 設定画面
struct SettingsView: View {

    @ObservedObject private var settings = SettingsStore.shared
    @ObservedObject private var llm = LocalLLMService.shared

    @State private var showDeleteAllConfirm = false
    @State private var showDeleteModelConfirm = false
    @State private var deleteAllError: String? = nil
    @State private var modelError: String? = nil

    var body: some View {
        NavigationStack {
            List {
                aiEngineSection
                duplicateCheckSection
                exportSection
                dataSection
                appInfoSection
            }
            .navigationTitle("設定")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    // MARK: - AIエンジン

    private var aiEngineSection: some View {
        Section {
            // 層1: Apple Intelligence
            if #available(iOS 18.0, *) {
                LabeledContent {
                    appleIntelligenceStatusText
                } label: {
                    Label("Apple Intelligence", systemImage: "apple.intelligence")
                }
            } else {
                LabeledContent {
                    Text("非対応")
                        .foregroundStyle(.secondary)
                } label: {
                    Label("Apple Intelligence", systemImage: "apple.intelligence")
                }
            }

            // 層2: ローカルLLM
            if llm.isDownloading {
                VStack(alignment: .leading, spacing: 6) {
                    Label("Qwen2.5（ダウンロード中…）", systemImage: "arrow.down.circle")
                    ProgressView(value: llm.downloadProgress)
                        .tint(.accentColor)
                    Text("\(Int(llm.downloadProgress * 100))%")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else if llm.isModelAvailable {
                HStack {
                    Label("Qwen2.5", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green, .primary)
                    Spacer()
                    if let size = llm.modelFileSize {
                        Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Button(role: .destructive) {
                        showDeleteModelConfirm = true
                    } label: {
                        Image(systemName: "trash")
                            .foregroundStyle(.red)
                    }
                    .buttonStyle(.plain)
                }
                .confirmationDialog("モデルを削除しますか？", isPresented: $showDeleteModelConfirm, titleVisibility: .visible) {
                    Button("削除", role: .destructive) {
                        do {
                            try llm.deleteModel()
                        } catch {
                            modelError = error.localizedDescription
                        }
                    }
                } message: {
                    Text("削除するとAI解析（正規表現にフォールバック）になります。再ダウンロードは可能です。")
                }
            } else {
                HStack {
                    Label("Qwen2.5（未ダウンロード）", systemImage: "arrow.down.circle")
                        .foregroundStyle(.secondary, .primary)
                    Spacer()
                    Button("ダウンロード") {
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
            if let err = modelError {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            // 層3: 正規表現
            LabeledContent {
                Text("常に利用可能")
                    .foregroundStyle(.secondary)
            } label: {
                Label("正規表現", systemImage: "chevron.left.forwardslash.chevron.right")
            }

        } header: {
            Text("AIエンジン")
        } footer: {
            Text("名刺OCR後のフィールド分類に使用します。上位の層から順に試みます。")
        }
    }

    // MARK: - 重複チェック

    private var duplicateCheckSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("検出感度")
                    Spacer()
                    Text(thresholdLabel)
                        .foregroundStyle(.secondary)
                }
                Slider(value: $settings.duplicateThreshold, in: 0.5...1.0, step: 0.05)
            }
        } header: {
            Text("重複チェック")
        } footer: {
            Text("感度が低いほど曖昧な一致も検出します。高いほど厳密に一致した場合のみ検出します。（現在: \(String(format: "%.0f", settings.duplicateThreshold * 100))%）")
        }
    }

    @available(iOS 18.0, *)
    private var appleIntelligenceStatusText: some View {
        switch SystemLanguageModel.default.availability {
        case .available:
            return Text("利用可能")
                .foregroundStyle(.green)
        case .unavailable(.deviceNotEligible):
            return Text("非対応デバイス")
                .foregroundStyle(.secondary)
        case .unavailable(.appleIntelligenceNotEnabled):
            return Text("Apple Intelligence が無効")
                .foregroundStyle(.orange)
        case .unavailable(.modelNotReady):
            return Text("準備中")
                .foregroundStyle(.secondary)
        default:
            return Text("利用不可")
                .foregroundStyle(.secondary)
        }
    }

    private var thresholdLabel: String {
        switch settings.duplicateThreshold {
        case ..<0.65: return "低"
        case ..<0.80: return "中"
        default:      return "高"
        }
    }

    // MARK: - エクスポート

    private var exportSection: some View {
        Section("エクスポート") {
            Toggle("CSV に BOM を付与（Excel 対応）", isOn: $settings.csvIncludesBOM)

            Picker("vCard バージョン", selection: $settings.vCardVersion) {
                Text("3.0").tag("3.0")
                Text("4.0").tag("4.0")
            }
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
                Button("すべて削除", role: .destructive) {
                    deleteAllCards()
                }
            } message: {
                Text("この操作は取り消せません。")
            }

            if let err = deleteAllError {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

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

    // MARK: - データ削除

    private func deleteAllCards() {
        let context = PersistenceController.shared.container.viewContext
        let request = BusinessCard.fetchRequest()
        do {
            let cards = try context.fetch(request)
            cards.forEach { context.delete($0) }
            try context.save()
        } catch {
            deleteAllError = "削除に失敗しました: \(error.localizedDescription)"
        }
    }
}

#Preview {
    SettingsView()
}
