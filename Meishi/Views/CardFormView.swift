import SwiftUI
import UIKit

// 名刺の新規作成・編集フォーム画面
struct CardFormView: View {

    @StateObject private var viewModel: CardFormViewModel
    let onSave: () -> Void

    @Environment(\.dismiss) private var dismiss

    // MARK: - 初期化（手動入力・新規作成）

    init(onSave: @escaping () -> Void) {
        _viewModel = StateObject(wrappedValue: CardFormViewModel())
        self.onSave = onSave
    }

    // MARK: - 初期化（カメラ撮影画像からOCR）

    init(image: UIImage, onSave: @escaping () -> Void) {
        _viewModel = StateObject(wrappedValue: CardFormViewModel(image: image))
        self.onSave = onSave
    }

    // MARK: - 初期化（既存カードの編集）

    init(card: BusinessCard, onSave: @escaping () -> Void) {
        _viewModel = StateObject(wrappedValue: CardFormViewModel(card: card))
        self.onSave = onSave
    }

    var body: some View {
        NavigationStack {
            Form {
                // OCR処理中インジケーター
                if viewModel.isProcessingOCR {
                    Section {
                        HStack(spacing: 12) {
                            ProgressView()
                            Text("名刺を読み取り中...")
                                .foregroundColor(.secondary)
                        }
                        .padding(.vertical, 4)
                    }
                }

                // OCRエラー表示
                if let errorMessage = viewModel.ocrErrorMessage {
                    Section {
                        Text(errorMessage)
                            .foregroundColor(.red)
                            .font(.footnote)
                    }
                }

                Section("氏名") {
                    TextField("姓", text: $viewModel.lastName)
                    TextField("名", text: $viewModel.firstName)
                }
                Section("所属") {
                    TextField("会社名", text: $viewModel.company)
                    TextField("役職", text: $viewModel.title)
                }
                Section("連絡先") {
                    TextField("電話番号", text: $viewModel.phone)
                        .keyboardType(.phonePad)
                    TextField("メールアドレス", text: $viewModel.email)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                }
                Section("その他") {
                    TextField("住所", text: $viewModel.address)
                    TextField("Webサイト", text: $viewModel.website)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                    TextField("メモ", text: $viewModel.notes)
                }
            }
            .navigationTitle(viewModel.isEditing ? "名刺を編集" : "名刺を追加")
            .navigationBarTitleDisplayMode(.inline)
            .alert("読み取り精度を向上しますか？", isPresented: $viewModel.shouldPromptLLMDownload) {
                Button("ダウンロード（約300MB）") {
                    Task { try? await LocalLLMService.shared.downloadModel { _ in } }
                }
                Button("スキップ", role: .cancel) {}
            } message: {
                Text("オンデバイスAIモデルを取得すると、名刺の読み取り精度が向上します。Wi-Fi環境を推奨します。")
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("キャンセル") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        viewModel.save()
                        onSave()
                        dismiss()
                    }
                    // 姓が空またはOCR処理中は保存不可
                    .disabled(
                        viewModel.lastName.trimmingCharacters(in: .whitespaces).isEmpty ||
                        viewModel.isProcessingOCR
                    )
                }
            }
        }
    }
}
