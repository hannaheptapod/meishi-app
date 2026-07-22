import SwiftUI

struct ModelManagementView: View {
    @ObservedObject private var llm = LocalLLMService.shared
    @ObservedObject private var settings = SettingsStore.shared
    @Binding var modelError: String?
    @State private var isShowingDeleteConfirm = false

    var body: some View {
        List {
            Section("利用状態") {
                LabeledContent("状態", value: statusText)
                LabeledContent("ダウンロード容量", value: "約570MB")
                if llm.isModelAvailable {
                    Button("このモデルを使用") {
                        settings.readingMethod = .localLLM
                    }
                    .disabled(settings.readingMethod == .localLLM)
                }
            }

            Section("更新状態") {
                if llm.isDownloading {
                    VStack(alignment: .leading, spacing: 8) {
                        ProgressView(value: llm.downloadProgress)
                        Text(llm.downloadProgress, format: .percent.precision(.fractionLength(0)))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                } else if !llm.isModelAvailable {
                    Button {
                        Task { await downloadModel() }
                    } label: {
                        Label("モデルをダウンロード", systemImage: "arrow.down.circle")
                    }
                } else {
                    Label("モデルは利用可能です", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }

                if let modelError {
                    InlineErrorView(message: modelError) {
                        Task { await downloadModel() }
                    }
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                }
            }

            if llm.isModelAvailable {
                Section {
                    Button("モデルを削除", role: .destructive) {
                        isShowingDeleteConfirm = true
                    }
                } footer: {
                    Text("削除後も、必要なときに再ダウンロードできます。")
                }
            }
        }
        .navigationTitle("AIモデル")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("AIモデルを削除しますか？", isPresented: $isShowingDeleteConfirm) {
            Button("削除", role: .destructive) {
                Task {
                    do {
                        try await llm.deleteModel()
                    } catch {
                        modelError = error.localizedDescription
                    }
                }
            }
        }
    }

    private var statusText: String {
        if llm.isDownloading { return "ダウンロード中" }
        if llm.isModelAvailable { return "利用可能" }
        return "未取得"
    }

    private func downloadModel() async {
        modelError = nil
        do {
            try await llm.downloadModel()
        } catch {
            modelError = error.localizedDescription
        }
    }
}
