import SwiftUI
import UIKit

// 名刺一覧画面
struct CardListView: View {

    @StateObject private var viewModel = CardListViewModel()
    @State private var isShowingForm = false
    @State private var isShowingCamera = false
    @State private var capturedImage: UIImage? = nil

    var body: some View {
        NavigationStack {
            Group {
                if viewModel.cards.isEmpty {
                    emptyState
                } else {
                    cardList
                }
            }
            .navigationTitle("名刺")
            .toolbar {
                ToolbarItemGroup(placement: .navigationBarTrailing) {
                    // カメラで撮影して登録
                    Button {
                        isShowingCamera = true
                    } label: {
                        Image(systemName: "camera")
                    }
                    // 手動入力で登録
                    Button {
                        isShowingForm = true
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            // 手動入力フォーム
            .sheet(isPresented: $isShowingForm, onDismiss: viewModel.fetchCards) {
                CardFormView(onSave: { isShowingForm = false })
            }
            // カメラ撮影
            .fullScreenCover(isPresented: $isShowingCamera) {
                CameraView(capturedImage: $capturedImage)
                    .ignoresSafeArea()
            }
            // 撮影完了後にOCRフォームを表示
            .sheet(item: $capturedImage, onDismiss: viewModel.fetchCards) { image in
                CardFormView(image: image, onSave: { capturedImage = nil })
            }
            .onAppear(perform: viewModel.fetchCards)
        }
    }

    // MARK: - サブビュー

    private var cardList: some View {
        List {
            ForEach(viewModel.cards) { card in
                NavigationLink {
                    CardDetailView(card: card, onUpdate: viewModel.fetchCards)
                } label: {
                    CardRowView(card: card)
                }
            }
            .onDelete(perform: viewModel.deleteCards)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "rectangle.portrait.on.rectangle.portrait.slash")
                .font(.system(size: 60))
                .foregroundColor(.secondary)
            Text("名刺がありません")
                .font(.title3)
                .foregroundColor(.secondary)
            HStack(spacing: 12) {
                Button {
                    isShowingCamera = true
                } label: {
                    Label("カメラで撮影", systemImage: "camera")
                }
                .buttonStyle(.borderedProminent)

                Button {
                    isShowingForm = true
                } label: {
                    Label("手動で追加", systemImage: "plus")
                }
                .buttonStyle(.bordered)
            }
        }
    }
}

// MARK: - 一覧行

private struct CardRowView: View {

    let card: BusinessCard

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            let fullName = card.fullName
            Text(fullName.isEmpty ? "（名前なし）" : fullName)
                .font(.headline)
            if let company = card.company, !company.isEmpty {
                Text(company)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
            if let title = card.title, !title.isEmpty {
                Text(title)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

// UIImage を sheet(item:) で使えるように Identifiable に準拠させる拡張
extension UIImage: @retroactive Identifiable {
    public var id: ObjectIdentifier { ObjectIdentifier(self) }
}
