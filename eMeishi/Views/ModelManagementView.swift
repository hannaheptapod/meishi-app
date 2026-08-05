import SwiftUI

nonisolated enum ModelManagementPresentation: Equatable, Sendable {
    case deleteConfirmation
}

nonisolated enum ModelManagementConfirmationCommit: Equatable, Sendable {
    case deleteModel
}

struct ModelManagementView: View {
    @ObservedObject private var llm = LocalLLMService.shared
    @ObservedObject private var settings = SettingsStore.shared
    @Binding var modelError: String?
    @State private var presentationState = QueuedPresentationState<ModelManagementPresentation>()
    @State private var confirmationCommitState = DismissalCommitState<ModelManagementConfirmationCommit>()
    @State private var downloadTask: Task<Void, Never>?
    @State private var downloadTaskGate = SecondaryViewTaskGate()
    @State private var deleteTask: Task<Void, Never>?
    @State private var deleteTaskGate = SecondaryViewTaskGate()
    @State private var isStartingDownload = false
    @State private var isDeletingModel = false

    var body: some View {
        List {
            Section("利用状態") {
                LabeledContent("状態", value: statusText)
                LabeledContent("ダウンロード容量", value: "約570MB")
                if llm.isModelAvailable {
                    Button("このモデルを使用") {
                        settings.readingMethod = .localLLM
                    }
                    .disabled(settings.readingMethod == .localLLM || llm.isDownloading)
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
                        startDownload()
                    } label: {
                        Label("モデルをダウンロード", systemImage: "arrow.down.circle")
                    }
                    .disabled(isStartingDownload || isDeletingModel)
                } else {
                    Label("モデルは利用可能です", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }

                if let modelError {
                    InlineErrorView(message: modelError) {
                        startDownload()
                    }
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                }
            }

            if llm.isModelAvailable {
                Section {
                    Button("モデルを削除", role: .destructive) {
                        presentationState.request(.deleteConfirmation)
                    }
                    .disabled(llm.isDownloading || isStartingDownload || isDeletingModel)
                } footer: {
                    Text("削除後も、必要なときに再ダウンロードできます。")
                }
            }
        }
        .navigationTitle("AIモデル")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("AIモデルを削除しますか？", isPresented: deleteConfirmationBinding) {
            Button("削除", role: .destructive) {
                scheduleConfirmationCommit(.deleteModel)
            }
        }
        .background {
            PresentationDismissalObserver(
                activeID: presentationState.active?.id,
                dismissingID: presentationState.dismissing?.id,
                onDismissalCompleted: completeConfirmationDismissal
            )
            .frame(width: 0, height: 0)
        }
        .onDisappear(perform: cancelViewOwnedTasks)
    }

    private var deleteConfirmationBinding: Binding<Bool> {
        Binding(
            get: { presentationState.active?.destination == .deleteConfirmation },
            set: { isPresented in
                guard !isPresented,
                      let active = presentationState.active,
                      active.destination == .deleteConfirmation else { return }
                presentationState.clearActive(requestID: active.id)
            }
        )
    }

    private func scheduleConfirmationCommit(_ action: ModelManagementConfirmationCommit) {
        guard let active = presentationState.active,
              active.destination == .deleteConfirmation,
              confirmationCommitState.schedule(action, for: active.id) else { return }
        presentationState.clearActive(requestID: active.id)
    }

    private func completeConfirmationDismissal(requestID: UUID) {
        let commit = confirmationCommitState.take(afterDismissing: requestID)
        guard commit == .deleteModel else {
            presentationState.presentNext(afterDismissing: requestID)
            return
        }
        presentationState.presentNext(afterDismissing: requestID)
        startDelete()
    }

    private var statusText: String {
        if llm.isDownloading { return "ダウンロード中" }
        if llm.isModelAvailable { return "利用可能" }
        return "未取得"
    }

    private func startDownload() {
        guard !llm.isDownloading,
              !isDeletingModel,
              let operationID = downloadTaskGate.begin() else { return }
        isStartingDownload = true
        modelError = nil

        // モデルは一時領域へ取得後に原子的に入れ替えるため、画面遷移だけでは停止しない。
        let serviceTask = Task { @MainActor () -> String? in
            do {
                try await llm.downloadModel()
                return nil
            } catch {
                return error.localizedDescription
            }
        }
        downloadTask = Task { @MainActor in
            let errorMessage = await serviceTask.value
            guard !Task.isCancelled,
                  downloadTaskGate.finish(operationID) else { return }
            downloadTask = nil
            isStartingDownload = false
            modelError = errorMessage
        }
    }

    private func startDelete() {
        guard !llm.isDownloading,
              !isStartingDownload,
              let operationID = deleteTaskGate.begin() else { return }
        isDeletingModel = true
        modelError = nil

        // 確認済みの削除は推論workerが直列化する。画面側は結果待受だけを所有する。
        let serviceTask = Task { @MainActor () -> String? in
            do {
                try await llm.deleteModel()
                return nil
            } catch {
                return error.localizedDescription
            }
        }
        deleteTask = Task { @MainActor in
            let errorMessage = await serviceTask.value
            guard !Task.isCancelled,
                  deleteTaskGate.finish(operationID) else { return }
            deleteTask = nil
            isDeletingModel = false
            modelError = errorMessage
        }
    }

    private func cancelViewOwnedTasks() {
        downloadTaskGate.cancel()
        downloadTask?.cancel()
        downloadTask = nil
        isStartingDownload = false

        deleteTaskGate.cancel()
        deleteTask?.cancel()
        deleteTask = nil
        isDeletingModel = false

        confirmationCommitState.removeAll()
        presentationState.removeAll()
    }
}
