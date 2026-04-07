import SwiftUI
import UIKit

// 名刺の新規作成・編集フォーム画面
struct CardFormView: View {

    @StateObject private var viewModel: CardFormViewModel
    let onSave: () -> Void
    let onSkip: (() -> Void)?
    let batchProgress: BatchProgress?

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var listViewModel: CardListViewModel
    @FocusState private var focusedField: FormField?

    // 連続撮影時のバッチ進捗
    struct BatchProgress {
        let current: Int
        let total: Int
    }

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
    }

    // MARK: - 初期化（カメラ撮影画像からOCR）

    init(image: UIImage, batchProgress: BatchProgress? = nil,
         onSave: @escaping () -> Void, onSkip: (() -> Void)? = nil) {
        _viewModel = StateObject(wrappedValue: CardFormViewModel(image: image))
        self.onSave = onSave
        self.onSkip = onSkip
        self.batchProgress = batchProgress
    }

    // MARK: - 初期化（クロップ済み画像からOCR・矩形検出スキップ）

    init(croppedImage: UIImage, batchProgress: BatchProgress? = nil,
         onSave: @escaping () -> Void, onSkip: (() -> Void)? = nil) {
        _viewModel = StateObject(wrappedValue: CardFormViewModel(croppedImage: croppedImage))
        self.onSave = onSave
        self.onSkip = onSkip
        self.batchProgress = batchProgress
    }

    // MARK: - 初期化（既存カードの編集）

    init(card: BusinessCard, onSave: @escaping () -> Void) {
        _viewModel = StateObject(wrappedValue: CardFormViewModel(card: card))
        self.onSave = onSave
        self.onSkip = nil
        self.batchProgress = nil
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
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                }

                // OCR処理中インジケーター
                if viewModel.isProcessingOCR {
                    Section {
                        HStack(spacing: 12) {
                            ProgressView()
                            VStack(alignment: .leading, spacing: 2) {
                                Text(viewModel.ocrStage)
                                    .foregroundStyle(.secondary)
                                if viewModel.ocrStage == "AIモデルで分析中..." {
                                    Text("初回はモデルのロードに時間がかかります")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
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

                Section("氏名") {
                    TextField("姓", text: $viewModel.lastName)
                        .textContentType(.familyName)
                        .autocorrectionDisabled()
                        .focused($focusedField, equals: .lastName)
                        .submitLabel(.next)
                        .onSubmit { focusedField = .lastNameReading }
                    TextField("姓（ふりがな）", text: $viewModel.lastNameReading)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($focusedField, equals: .lastNameReading)
                        .submitLabel(.next)
                        .onSubmit { focusedField = .firstName }
                    TextField("名", text: $viewModel.firstName)
                        .textContentType(.givenName)
                        .autocorrectionDisabled()
                        .focused($focusedField, equals: .firstName)
                        .submitLabel(.next)
                        .onSubmit { focusedField = .firstNameReading }
                    TextField("名（ふりがな）", text: $viewModel.firstNameReading)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($focusedField, equals: .firstNameReading)
                        .submitLabel(.next)
                        .onSubmit { focusedField = .company }
                }

                Section("所属") {
                    TextField("会社名", text: $viewModel.company)
                        .textContentType(.organizationName)
                        .autocorrectionDisabled()
                        .focused($focusedField, equals: .company)
                        .submitLabel(.next)
                        .onSubmit { focusedField = .companyReading }
                    TextField("会社名（ふりがな）", text: $viewModel.companyReading)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($focusedField, equals: .companyReading)
                        .submitLabel(.next)
                        .onSubmit { focusedField = .department }
                    TextField("部署", text: $viewModel.department)
                        .autocorrectionDisabled()
                        .focused($focusedField, equals: .department)
                        .submitLabel(.next)
                        .onSubmit { focusedField = .title }
                    TextField("役職", text: $viewModel.title)
                        .textContentType(.jobTitle)
                        .autocorrectionDisabled()
                        .focused($focusedField, equals: .title)
                        .submitLabel(.next)
                        .onSubmit { focusedField = nil }
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
                                }
                                .buttonStyle(.borderless)
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

                // タグ選択セクション
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
                                ForEach(listViewModel.allTags.filter { viewModel.suggestedTagIDs.contains($0.id ?? UUID()) }) { tag in
                                    HStack(spacing: 4) {
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
                                            .padding(.vertical, 6)
                                            .background(tag.color.opacity(0.12))
                                            .foregroundStyle(tag.color)
                                            .clipShape(Capsule())
                                            .overlay(
                                                Capsule()
                                                    .strokeBorder(tag.color.opacity(0.3), lineWidth: 1)
                                            )
                                        }
                                        .buttonStyle(.plain)
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
                                let selected = viewModel.selectedTags.contains(tag.id ?? UUID())
                                Button {
                                    if let id = tag.id {
                                        if selected {
                                            viewModel.selectedTags.remove(id)
                                        } else {
                                            viewModel.selectedTags.insert(id)
                                        }
                                    }
                                } label: {
                                    HStack(spacing: 4) {
                                        Image(systemName: "checkmark")
                                            .font(.caption2)
                                            .opacity(selected ? 1 : 0)
                                        Circle()
                                            .fill(tag.color)
                                            .frame(width: 8, height: 8)
                                        Text(tag.tagName)
                                            .font(.caption)
                                    }
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 6)
                                    .background(selected ? tag.color.opacity(0.2) : Color(.systemGray6))
                                    .foregroundStyle(selected ? tag.color : .secondary)
                                    .clipShape(Capsule())
                                }
                                .buttonStyle(.plain)
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
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if let onSkip = onSkip {
                        Button("スキップ") { onSkip() }
                    } else {
                        Button { dismiss() } label: { Image(systemName: "xmark") }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(saveButtonTitle) {
                        focusedField = nil
                        viewModel.save()
                        onSave()
                        if batchProgress == nil {
                            dismiss()
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
        }
    }

    // MARK: - バッチモード用ヘルパー

    private var batchNavigationTitle: String {
        if let bp = batchProgress {
            return "\(bp.current)/\(bp.total) 名刺を追加"
        }
        return viewModel.isEditing ? "名刺を編集" : "名刺を追加"
    }

    private var saveButtonTitle: String {
        guard let bp = batchProgress else { return "保存" }
        return bp.current < bp.total ? "保存して次へ" : "保存"
    }
}
