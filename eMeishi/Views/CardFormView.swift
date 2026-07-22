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
    @State private var isSkipping = false
    @State private var isShowingAdditionalFields = false

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

    // MARK: - 初期化（カメラ撮影画像からOCR）

    init(image: UIImage, batchProgress: BatchProgress? = nil,
         onSave: @escaping () -> Void, onSkip: (() -> Void)? = nil) {
        _viewModel = StateObject(wrappedValue: CardFormViewModel(image: image))
        self.onSave = onSave
        self.onSkip = onSkip
        self.batchProgress = batchProgress
        self.mode = .ocrReview
    }

    // MARK: - 初期化（クロップ済み画像からOCR・矩形検出スキップ）

    init(croppedImage: UIImage, batchProgress: BatchProgress? = nil,
         onSave: @escaping () -> Void, onSkip: (() -> Void)? = nil) {
        _viewModel = StateObject(wrappedValue: CardFormViewModel(croppedImage: croppedImage))
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
                // 撮影画像プレビュー
                if let imageData = viewModel.capturedImageData,
                   let uiImage = UIImage(data: imageData) {
                    Section {
                        Image(uiImage: uiImage)
                            .resizable()
                            .scaledToFit()
                            .frame(maxHeight: 220)
                            .clipShape(.rect(cornerRadius: AppTheme.imageCornerRadius, style: .continuous))
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
                    ForEach(viewModel.phones.indices, id: \.self) { i in
                        HStack {
                            TextField("電話番号", text: $viewModel.phones[i])
                                .keyboardType(.phonePad)
                                .textContentType(.telephoneNumber)
                            if viewModel.phones.count > 1 {
                                Button(role: .destructive) {
                                    viewModel.phones.remove(at: i)
                                } label: {
                                    Image(systemName: "minus.circle.fill")
                                        .foregroundStyle(.red)
                                        .frame(width: 44, height: 44)
                                }
                                .buttonStyle(.borderless)
                                .accessibilityLabel("電話番号\(i + 1)を削除")
                            }
                        }
                    }
                    Button {
                        viewModel.phones.append("")
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
                            if !listViewModel.allTags.isEmpty {
                                VStack(alignment: .leading, spacing: 8) {
                                    Text("タグ")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    FlowLayout(spacing: 6) {
                                        ForEach(listViewModel.allTags) { tag in
                                            if let id = tag.id {
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
                                ForEach(listViewModel.allTags.filter { tag in
                                    tag.id.map { viewModel.suggestedTagIDs.contains($0) } ?? false
                                }) { tag in
                                    HStack(spacing: 4) {
                                        // 承認ボタン
                                        Button {
                                            if let id = tag.id {
                                                viewModel.acceptTagSuggestion(id)
                                            }
                                        } label: {
                                            HStack(spacing: 4) {
                                                Image(systemName: "plus")
                                                    .font(.caption2)
                                                Circle()
                                                    .fill(tag.color)
                                                    .frame(width: 8, height: 8)
                                                Text(tag.tagName)
                                                    .font(.caption)
                                            }
                                            .padding(.horizontal, 10)
                                            .frame(minHeight: 44)
                                            .background(tag.color.opacity(0.12))
                                            .foregroundStyle(tag.color)
                                            .clipShape(Capsule())
                                            .overlay(
                                                Capsule()
                                                    .strokeBorder(tag.color.opacity(0.3), lineWidth: 1)
                                            )
                                        }
                                        .buttonStyle(.plain)
                                        .accessibilityLabel("\(tag.tagName)を追加")
                                        // 却下ボタン
                                        Button {
                                            if let id = tag.id {
                                                viewModel.dismissTagSuggestion(id)
                                            }
                                        } label: {
                                            Image(systemName: "xmark")
                                                .font(.caption2)
                                                .foregroundStyle(.secondary)
                                                .frame(width: 44, height: 44)
                                        }
                                        .buttonStyle(.plain)
                                        .accessibilityLabel("\(tag.tagName)の提案を閉じる")
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

                    if listViewModel.allTags.isEmpty {
                        Text("タグがありません")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    } else {
                        FlowLayout(spacing: 6) {
                            ForEach(listViewModel.allTags) { tag in
                                if let id = tag.id {
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
            .navigationTitle(batchNavigationTitle)
            .navigationBarTitleDisplayMode(.inline)
            .alert("読み取り精度を向上しますか？", isPresented: $viewModel.shouldPromptLLMDownload) {
                Button("ダウンロード（約300MB）") {
                    Task { try? await LocalLLMService.shared.downloadModel() }
                }
                Button("スキップ", role: .cancel) {}
            } message: {
                Text("オンデバイスAIモデルを取得すると、名刺の読み取り精度が向上します。Wi-Fi環境を推奨します。")
            }
            .alert(
                "保存に失敗しました",
                isPresented: Binding(
                    get: { viewModel.saveErrorMessage != nil },
                    set: { if !$0 { viewModel.saveErrorMessage = nil } }
                )
            ) {
                Button("閉じる", role: .cancel) {}
            } message: {
                Text(viewModel.saveErrorMessage ?? "名刺を保存できませんでした。")
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if let onSkip = onSkip {
                        Button("スキップ") {
                            guard !isSkipping else { return }
                            isSkipping = true
                            Task {
                                await viewModel.cancelOCRAndWait()
                                onSkip()
                            }
                        }
                        .disabled(isSkipping)
                    } else {
                        Button {
                            if viewModel.isProcessingOCR {
                                Task {
                                    await viewModel.cancelOCRAndWait()
                                    dismiss()
                                }
                            } else {
                                dismiss()
                            }
                        } label: {
                            Image(systemName: "xmark")
                        }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(saveButtonTitle) {
                        focusedField = nil
                        do {
                            try viewModel.save()
                            UINotificationFeedbackGenerator().notificationOccurred(.success)
                            onSave()
                            if batchProgress == nil {
                                dismiss()
                            }
                        } catch {
                            // ViewModel がエラー表示を保持する。フォームは閉じず入力を維持する。
                        }
                    }
                    .disabled(
                        viewModel.lastName.trimmingCharacters(in: .whitespaces).isEmpty ||
                        viewModel.isProcessingOCR
                    )
                }
                // キーボード上の「完了」ボタン
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("完了") { focusedField = nil }
                }
            }
            .interactiveDismissDisabled(viewModel.isProcessingOCR)
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
