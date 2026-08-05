import CoreData
import SwiftUI
import UIKit

nonisolated struct CardFormBatchProgress: Equatable, Sendable {
    let current: Int
    let total: Int
}

nonisolated enum CardFormMode: Equatable, Sendable {
    case create
    case edit
    case ocrReview
}

nonisolated enum CardFormAlertDestination: Equatable, Sendable {
    case llmDownload
    case saveFailure(message: String)
}

// 名刺の新規作成・編集フォーム画面
struct CardFormView: View {

    @StateObject private var viewModel: CardFormViewModel
    let onSave: () -> Void
    let onSkip: (() -> Void)?
    let batchProgress: BatchProgress?
    let mode: CardFormMode

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var listViewModel: CardListViewModel
    @FocusState private var focusedField: FormField?
    @State private var exitLifecycle = CardFormExitLifecycle()
    @State private var exitTask: Task<Void, Never>?
    @State private var editLoadTask: Task<Void, Never>?
    @State private var editLoadGeneration = UUID()
    @State private var saveTask: Task<Void, Never>?
    @State private var saveRequestID: UUID?
    @State private var modelDownloadTask: Task<Void, Never>?
    @State private var modelDownloadRequestID: UUID?
    @State private var viewLifetimeID: UUID?
    @State private var isShowingAdditionalFields = false
    @State private var alertState = QueuedPresentationState<CardFormAlertDestination>()

    // 連続撮影時のバッチ進捗
    typealias BatchProgress = CardFormBatchProgress

    private enum FormField: Hashable {
        case lastName, lastNameReading, firstName, firstNameReading
        case company, companyReading, department, title, email, address, website, notes
    }

    // MARK: - 初期化（手動入力・新規作成）

    init(onSave: @escaping () -> Void) {
        _viewModel = StateObject(wrappedValue: CardFormViewModel())
        self.onSave = onSave
        self.onSkip = nil
        self.batchProgress = nil
        self.mode = .create
    }

    // MARK: - 初期化（正規化済み入力からOCR）

    init(input: CardImageInput, batchProgress: BatchProgress? = nil,
         onSave: @escaping () -> Void, onSkip: (() -> Void)? = nil) {
        _viewModel = StateObject(
            wrappedValue: CardFormViewModel(normalizedImageData: input.data)
        )
        self.onSave = onSave
        self.onSkip = onSkip
        self.batchProgress = batchProgress
        self.mode = .ocrReview
    }

    // MARK: - 初期化（外部から ViewModel を注入）
    // スクリーンショット撮影用にモックの ViewModel を注入できるようにする

    init(viewModelFactory: @escaping () -> CardFormViewModel, onSave: @escaping () -> Void) {
        _viewModel = StateObject(wrappedValue: viewModelFactory())
        self.onSave = onSave
        self.onSkip = nil
        self.batchProgress = nil
        self.mode = .ocrReview
    }

    // MARK: - 初期化（既存カードの編集）

    init(card: BusinessCard, onSave: @escaping () -> Void) {
        _viewModel = StateObject(
            wrappedValue: CardFormViewModel(
                card: card,
                context: card.managedObjectContext
            )
        )
        self.onSave = onSave
        self.onSkip = nil
        self.batchProgress = nil
        self.mode = .edit
    }

    var body: some View {
        NavigationStack {
            Form {
                if viewModel.isLoadingEditSnapshot {
                    editLoadingShell
                } else if let editLoadErrorMessage = viewModel.editLoadErrorMessage {
                    Section {
                        Label(editLoadErrorMessage, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.secondary)
                        Button("再試行") {
                            startEditSnapshotLoad(force: true)
                        }
                    }
                } else {
                // 撮影画像プレビュー
                if let imageData = viewModel.capturedImageData {
                    Section {
                        CardImageHero(
                            imageData: imageData,
                            cacheIdentifier: CardImageCacheKey.transient(
                                owner: ObjectIdentifier(viewModel),
                                revision: viewModel.capturedImageRevision,
                                dataCount: imageData.count
                            ),
                            initials: "",
                            maximumHeight: 220
                        )
                    }
                }

                // OCR処理中インジケーター
                if viewModel.isProcessingOCR {
                    Section {
                        OCRStatusStepper(
                            state: viewModel.ocrProcessingState,
                            canContinueInBackground: viewModel.canContinueOCRInBackground,
                            onCancel: {
                                viewModel.cancelOCR()
                            }
                        )
                        .padding(.vertical, 4)
                    }
                }

                // OCRエラー表示
                if let errorMessage = viewModel.ocrErrorMessage {
                    Section {
                        Text(errorMessage)
                            .foregroundStyle(.red)
                            .font(.footnote)
                    }
                }

                if !viewModel.isProcessingOCR {
                Section("氏名") {
                    LabeledContent("姓") {
                        TextField("姓", text: $viewModel.lastName)
                            .textContentType(.familyName)
                            .autocorrectionDisabled()
                            .multilineTextAlignment(.trailing)
                            .focused($focusedField, equals: .lastName)
                            .submitLabel(.next)
                            .onSubmit { focusedField = .lastNameReading }
                    }
                    readingRow(
                        text: $viewModel.lastNameReading,
                        focus: .lastNameReading,
                        nextFocus: .firstName
                    )
                    LabeledContent("名") {
                        TextField("名", text: $viewModel.firstName)
                            .textContentType(.givenName)
                            .autocorrectionDisabled()
                            .multilineTextAlignment(.trailing)
                            .focused($focusedField, equals: .firstName)
                            .submitLabel(.next)
                            .onSubmit { focusedField = .firstNameReading }
                    }
                    readingRow(
                        text: $viewModel.firstNameReading,
                        focus: .firstNameReading,
                        nextFocus: .company
                    )
                }

                Section("所属") {
                    LabeledContent("会社名") {
                        TextField("会社名", text: $viewModel.company)
                            .textContentType(.organizationName)
                            .autocorrectionDisabled()
                            .multilineTextAlignment(.trailing)
                            .focused($focusedField, equals: .company)
                            .submitLabel(.next)
                            .onSubmit { focusedField = .companyReading }
                    }
                    readingRow(
                        text: $viewModel.companyReading,
                        focus: .companyReading,
                        nextFocus: nil
                    )
                    if !isOCRReview {
                        TextField("部署", text: $viewModel.department)
                            .autocorrectionDisabled()
                            .focused($focusedField, equals: .department)
                        TextField("役職", text: $viewModel.title)
                            .textContentType(.jobTitle)
                            .autocorrectionDisabled()
                            .focused($focusedField, equals: .title)
                    }
                }

                Section("連絡先") {
                    ForEach($viewModel.phoneFields) { $phoneField in
                        HStack {
                            TextField("電話番号", text: $phoneField.value)
                                .keyboardType(.phonePad)
                                .textContentType(.telephoneNumber)
                            if viewModel.phoneFields.count > 1 {
                                Button(role: .destructive) {
                                    viewModel.removePhoneField(id: phoneField.id)
                                } label: {
                                    Image(systemName: "minus.circle.fill")
                                        .foregroundStyle(.red)
                                        .frame(width: 44, height: 44)
                                }
                                .buttonStyle(.borderless)
                                .accessibilityLabel("電話番号を削除")
                            }
                        }
                    }
                    Button {
                        viewModel.appendPhoneField()
                    } label: {
                        Label("電話番号を追加", systemImage: "plus.circle")
                            .font(.subheadline)
                    }
                    TextField("メールアドレス", text: $viewModel.email)
                        .keyboardType(.emailAddress)
                        .textContentType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($focusedField, equals: .email)
                        .submitLabel(.next)
                        .onSubmit { focusedField = .address }
                }

                if isOCRReview {
                    Section {
                        DisclosureGroup(isExpanded: $isShowingAdditionalFields) {
                            TextField("部署", text: $viewModel.department)
                            TextField("役職", text: $viewModel.title)
                            TextField("住所", text: $viewModel.address)
                                .textContentType(.fullStreetAddress)
                            TextField("Webサイト", text: $viewModel.website)
                                .keyboardType(.URL)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                            TextField("メモ", text: $viewModel.notes)
                            if !listViewModel.tagDisplaySnapshots.isEmpty {
                                VStack(alignment: .leading, spacing: 8) {
                                    Text("タグ")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    FlowLayout(spacing: 6) {
                                        ForEach(listViewModel.tagDisplaySnapshots) { tag in
                                            if let id = tag.tagID {
                                                let selected = viewModel.selectedTags.contains(id)
                                                TagSelectionChip(tag: tag, isSelected: selected) {
                                                    if selected {
                                                        viewModel.selectedTags.remove(id)
                                                    } else {
                                                        viewModel.selectedTags.insert(id)
                                                    }
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                        } label: {
                            Text("その他の項目")
                        }
                    }
                }

                // タグ選択セクション
                if !isOCRReview {
                Section("タグ") {
                    // AI提案タグ
                    if !viewModel.suggestedTagIDs.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 4) {
                                Image(systemName: "sparkles")
                                    .font(.caption)
                                    .foregroundStyle(.tint)
                                Text("AI提案")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            FlowLayout(spacing: 6) {
                                ForEach(listViewModel.tagDisplaySnapshots.filter { tag in
                                    tag.tagID.map { viewModel.suggestedTagIDs.contains($0) } ?? false
                                }) { tag in
                                    HStack(spacing: 4) {
                                        // 承認ボタン
                                        Button {
                                            if let id = tag.tagID {
                                                viewModel.acceptTagSuggestion(id)
                                            }
                                        } label: {
                                            HStack(spacing: 4) {
                                                Image(systemName: "plus")
                                                    .font(.caption2)
                                                Circle()
                                                    .fill(Color(hex: tag.colorHex))
                                                    .frame(width: 8, height: 8)
                                                Text(tag.name)
                                                    .font(.caption)
                                            }
                                            .padding(.horizontal, 10)
                                            .frame(minHeight: 44)
                                            .background(Color(hex: tag.colorHex).opacity(0.12))
                                            .foregroundStyle(Color(hex: tag.colorHex))
                                            .clipShape(Capsule())
                                            .overlay(
                                                Capsule()
                                                    .strokeBorder(
                                                        Color(hex: tag.colorHex).opacity(0.3),
                                                        lineWidth: 1
                                                    )
                                            )
                                        }
                                        .buttonStyle(.plain)
                                        .accessibilityLabel("\(tag.name)を追加")
                                        // 却下ボタン
                                        Button {
                                            if let id = tag.tagID {
                                                viewModel.dismissTagSuggestion(id)
                                            }
                                        } label: {
                                            Image(systemName: "xmark")
                                                .font(.caption2)
                                                .foregroundStyle(.secondary)
                                                .frame(width: 44, height: 44)
                                        }
                                        .buttonStyle(.plain)
                                        .accessibilityLabel("\(tag.name)の提案を閉じる")
                                    }
                                }
                            }
                        }
                    } else if viewModel.isLoadingTagSuggestions {
                        HStack(spacing: 6) {
                            ProgressView()
                                .controlSize(.small)
                            Text("タグを提案中...")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    if listViewModel.tagDisplaySnapshots.isEmpty {
                        Text("タグがありません")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    } else {
                        FlowLayout(spacing: 6) {
                            ForEach(listViewModel.tagDisplaySnapshots) { tag in
                                if let id = tag.tagID {
                                    let selected = viewModel.selectedTags.contains(id)
                                    TagSelectionChip(tag: tag, isSelected: selected) {
                                        if selected {
                                            viewModel.selectedTags.remove(id)
                                        } else {
                                            viewModel.selectedTags.insert(id)
                                        }
                                    }
                                }
                            }
                        }
                    }
                }

                Section("その他") {
                    TextField("住所", text: $viewModel.address)
                        .textContentType(.fullStreetAddress)
                        .focused($focusedField, equals: .address)
                        .submitLabel(.next)
                        .onSubmit { focusedField = .website }
                    TextField("Webサイト", text: $viewModel.website)
                        .keyboardType(.URL)
                        .textContentType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($focusedField, equals: .website)
                        .submitLabel(.next)
                        .onSubmit { focusedField = .notes }
                    TextField("メモ", text: $viewModel.notes)
                        .focused($focusedField, equals: .notes)
                        .submitLabel(.done)
                        .onSubmit { focusedField = nil }
                }
                }
                }
                }
            }
            .animation(nil, value: viewModel.isLoadingEditSnapshot)
            .navigationTitle(batchNavigationTitle)
            .navigationBarTitleDisplayMode(.inline)
            .alert(item: cardFormAlertBinding, content: cardFormAlert)
            .background {
                PresentationDismissalObserver(
                    activeID: alertState.active?.id,
                    dismissingID: alertState.dismissing?.id,
                    onDismissalCompleted: completeCardFormAlertDismissal
                )
                .frame(width: 0, height: 0)
            }
            .onChange(of: viewModel.shouldPromptLLMDownload, initial: true) { _, shouldPrompt in
                if shouldPrompt {
                    alertState.request(.llmDownload)
                }
            }
            .onChange(of: viewModel.saveErrorMessage, initial: true) { _, message in
                if let message {
                    alertState.request(.saveFailure(message: message))
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if onSkip != nil {
                        Button("スキップ") {
                            beginExit(.skip)
                        }
                        .disabled(exitLifecycle.isExiting || viewModel.isSaving)
                    } else {
                        Button {
                            beginExit(.close)
                        } label: {
                            Image(systemName: "xmark")
                        }
                        .disabled(exitLifecycle.isExiting || viewModel.isSaving)
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(saveButtonTitle) {
                        saveCurrentForm()
                    }
                    .disabled(
                        viewModel.lastName.trimmingCharacters(in: .whitespaces).isEmpty ||
                        viewModel.isProcessingOCR ||
                        viewModel.isLoadingEditSnapshot ||
                        viewModel.editLoadErrorMessage != nil ||
                        viewModel.isSaving
                    )
                }
                // キーボード上の「完了」ボタン
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("完了") { focusedField = nil }
                }
            }
            .interactiveDismissDisabled(
                viewModel.isProcessingOCR || exitLifecycle.isExiting || viewModel.isSaving
            )
            .onAppear {
                viewLifetimeID = UUID()
                startEditSnapshotLoad()
            }
            .onDisappear {
                viewLifetimeID = nil
                editLoadGeneration = UUID()
                editLoadTask?.cancel()
                editLoadTask = nil
                viewModel.cancelEditSnapshotLoading()
                saveRequestID = nil
                saveTask?.cancel()
                saveTask = nil
                exitTask?.cancel()
                exitTask = nil
                exitLifecycle.invalidate()
                modelDownloadTask?.cancel()
                modelDownloadTask = nil
                modelDownloadRequestID = nil
                viewModel.cancelTagSuggestions()
            }
        }
    }

    // MARK: - バッチモード用ヘルパー

    private var batchNavigationTitle: String {
        if let bp = batchProgress {
            return "\(bp.current) / \(bp.total)"
        }
        return viewModel.isEditing ? "名刺を編集" : "名刺を追加"
    }

    private var saveButtonTitle: String {
        guard let bp = batchProgress else { return "保存" }
        return bp.current < bp.total ? "保存して次へ" : "保存"
    }

    private var isOCRReview: Bool {
        if case .ocrReview = mode { return true }
        return false
    }

    @ViewBuilder
    private var editLoadingShell: some View {
        Section {
            RoundedRectangle(cornerRadius: AppTheme.imageCornerRadius, style: .continuous)
                .fill(AppTheme.auxiliarySurface)
                .frame(maxWidth: .infinity)
                .frame(height: 220)
                .overlay {
                    ProgressView("名刺を読み込んでいます")
                }
        }

        Section("氏名") {
            loadingRow(label: "姓")
            loadingRow(label: "ふりがな")
            loadingRow(label: "名")
            loadingRow(label: "ふりがな")
        }

        Section("所属") {
            loadingRow(label: "会社名")
            loadingRow(label: "ふりがな")
        }
    }

    private func loadingRow(label: String) -> some View {
        HStack {
            Text(label)
            Spacer()
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(.secondary.opacity(0.16))
                .frame(width: 112, height: 16)
        }
        .frame(minHeight: 44)
        .accessibilityHidden(true)
    }

    private func startEditSnapshotLoad(force: Bool = false) {
        guard let lifetimeID = viewLifetimeID,
              editLoadTask == nil,
              force || viewModel.needsEditSnapshotLoad else { return }
        editLoadTask?.cancel()
        let generation = UUID()
        editLoadGeneration = generation
        viewModel.beginEditSnapshotLoading()
        editLoadTask = Task {
            do {
                let snapshot = try await viewModel.loadEditSnapshot()
                guard !Task.isCancelled,
                      viewLifetimeID == lifetimeID,
                      editLoadGeneration == generation else { return }
                viewModel.applyEditSnapshot(snapshot)
            } catch is CancellationError {
                guard editLoadGeneration == generation else { return }
                viewModel.cancelEditSnapshotLoading()
            } catch {
                guard !Task.isCancelled,
                      viewLifetimeID == lifetimeID,
                      editLoadGeneration == generation else { return }
                viewModel.finishEditSnapshotLoading(with: error)
            }
            if editLoadGeneration == generation {
                editLoadTask = nil
            }
        }
    }

    private var cardFormAlertBinding: Binding<QueuedPresentationRequest<CardFormAlertDestination>?> {
        Binding(
            get: { alertState.active },
            set: { newValue in
                guard newValue == nil, let active = alertState.active else { return }

                switch active.destination {
                case .llmDownload:
                    viewModel.shouldPromptLLMDownload = false
                case .saveFailure:
                    viewModel.saveErrorMessage = nil
                }

                _ = alertState.clearActive(requestID: active.id)
            }
        )
    }

    private func completeCardFormAlertDismissal(requestID: UUID) {
        alertState.presentNext(afterDismissing: requestID)
    }

    private func cardFormAlert(
        _ request: QueuedPresentationRequest<CardFormAlertDestination>
    ) -> Alert {
        switch request.destination {
        case .llmDownload:
            return Alert(
                title: Text("読み取り精度を向上しますか？"),
                message: Text("オンデバイスAIモデルを取得すると、名刺の読み取り精度が向上します。Wi-Fi環境を推奨します。"),
                primaryButton: .default(Text("ダウンロード（約300MB）")) {
                    startModelDownload()
                },
                secondaryButton: .cancel(Text("スキップ"))
            )
        case .saveFailure(let message):
            return Alert(
                title: Text("保存に失敗しました"),
                message: Text(message),
                dismissButton: .cancel(Text("閉じる"))
            )
        }
    }

    private func beginExit(_ action: CardFormExitAction) {
        guard let lifetimeID = viewLifetimeID,
              let request = exitLifecycle.begin(action) else { return }
        focusedField = nil
        let shouldCancelOCR = action == .skip || viewModel.isProcessingOCR
        exitTask = Task {
            if shouldCancelOCR {
                await viewModel.cancelOCRAndWait()
            }
            guard !Task.isCancelled,
                  viewLifetimeID == lifetimeID,
                  let completedAction = exitLifecycle.complete(requestID: request.id) else { return }

            exitTask = nil
            switch completedAction {
            case .skip:
                onSkip?()
            case .close:
                dismiss()
            }
        }
    }

    private func saveCurrentForm() {
        guard let lifetimeID = viewLifetimeID, saveTask == nil else { return }
        focusedField = nil
        let requestID = UUID()
        saveRequestID = requestID
        saveTask = Task {
            do {
                try await viewModel.save()
                if !Task.isCancelled,
                   viewLifetimeID == lifetimeID,
                   saveRequestID == requestID {
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                    // 保存後のpresentation終了は、sheetを所有する親状態だけが行う。
                    onSave()
                }
            } catch is CancellationError {
                // 画面終了によるキャンセルではエラー表示を追加しない。
            } catch {
                // ViewModel がエラー表示を保持する。フォームは閉じず入力を維持する。
            }
            if saveRequestID == requestID {
                saveRequestID = nil
                saveTask = nil
            }
        }
    }

    private func startModelDownload() {
        guard let lifetimeID = viewLifetimeID else { return }
        modelDownloadTask?.cancel()
        let requestID = UUID()
        modelDownloadRequestID = requestID
        modelDownloadTask = Task {
            try? await LocalLLMService.shared.downloadModel()
            guard !Task.isCancelled,
                  viewLifetimeID == lifetimeID,
                  modelDownloadRequestID == requestID else { return }
            modelDownloadRequestID = nil
            modelDownloadTask = nil
        }
    }

    @ViewBuilder
    private func readingRow(
        text: Binding<String>,
        focus: FormField,
        nextFocus: FormField?
    ) -> some View {
        HStack {
            Text("ふりがな")
            TextField("未入力", text: text)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .multilineTextAlignment(.trailing)
                .focused($focusedField, equals: focus)
                .submitLabel(nextFocus == nil ? .done : .next)
                .onSubmit { focusedField = nextFocus }
        }
    }
}
