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
                ocrEngineSection
                duplicateCheckSection
                exportSection
                dataSection
                appInfoSection
            }
            .navigationTitle("設定")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    // MARK: - 読み取りエンジン

    private var ocrEngineSection: some View {
        Section {
            // Apple Intelligence
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

            // オンデバイスAI（Qwen2.5）
            if llm.isDownloading {
                VStack(alignment: .leading, spacing: 6) {
                    Label("AIをダウンロード中…", systemImage: "arrow.down.circle")
                    ProgressView(value: llm.downloadProgress)
                        .tint(.accentColor)
                    Text("\(Int(llm.downloadProgress * 100))%")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else if llm.isModelAvailable {
                HStack {
                    Label("オンデバイスAI", systemImage: "checkmark.circle.fill")
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
                .confirmationDialog("AIモデルを削除しますか？", isPresented: $showDeleteModelConfirm, titleVisibility: .visible) {
                    Button("削除", role: .destructive) {
                        do {
                            try llm.deleteModel()
                        } catch {
                            modelError = error.localizedDescription
                        }
                    }
                } message: {
                    Text("削除すると基本解析に切り替わります。再ダウンロードはいつでも可能です。")
                }
            } else {
                HStack {
                    Label("オンデバイスAI（未取得）", systemImage: "arrow.down.circle")
                        .foregroundStyle(.secondary, .primary)
                    Spacer()
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
            if let err = modelError {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            // 基本解析
            LabeledContent {
                Text("常時利用可能")
                    .foregroundStyle(.secondary)
            } label: {
                Label("基本解析", systemImage: "chevron.left.forwardslash.chevron.right")
            }

        } header: {
            Text("読み取りエンジン")
        } footer: {
            Text("撮影した名刺のテキストを自動でフィールドに分類します。上から順に利用可能なエンジンを使用します。")
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
            Text("「低」にするほど名前が少し違う名刺も重複として検出します。「高」にするほど厳密に一致した場合のみ検出します。（現在: \(String(format: "%.0f", settings.duplicateThreshold * 100))%）")
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
            return Text("Apple Intelligenceが無効")
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
        Section {
            Toggle("Excel 対応（CSV の文字化け防止）", isOn: $settings.csvIncludesBOM)

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
