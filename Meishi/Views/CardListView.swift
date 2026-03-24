import SwiftUI

// 名刺一覧画面
struct CardListView: View {

    @StateObject private var viewModel = CardListViewModel()
    @State private var isShowingForm = false

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
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        isShowingForm = true
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .sheet(isPresented: $isShowingForm, onDismiss: viewModel.fetchCards) {
                CardFormView(onSave: { isShowingForm = false })
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
            Button("名刺を追加") {
                isShowingForm = true
            }
            .buttonStyle(.borderedProminent)
        }
    }
}

// MARK: - 一覧行

private struct CardRowView: View {

    let card: BusinessCard

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(card.name ?? "（名前なし）")
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
