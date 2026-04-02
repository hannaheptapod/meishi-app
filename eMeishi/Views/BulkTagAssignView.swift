import SwiftUI

// 一括タグ付けシート（選択モードから呼び出し）
struct BulkTagAssignView: View {

    let selectedCardIDs: Set<BusinessCard.ID>
    let onDismiss: () -> Void

    @EnvironmentObject private var viewModel: CardListViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var isShowingTagManager = false

    var body: some View {
        NavigationStack {
            List {
                if viewModel.allTags.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "tag.slash")
                            .font(.system(size: 40))
                            .foregroundStyle(.secondary)
                        Text("タグがありません")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 32)
                    .listRowSeparator(.hidden)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("タグがありません")
                } else {
                    let selectedCards = viewModel.selectedCards(from: selectedCardIDs)
                    ForEach(viewModel.allTags) { tag in
                        let assignedCount = selectedCards.filter { card in
                            (card.tags as? Set<Tag>)?.contains(tag) == true
                        }.count
                        let allAssigned = assignedCount == selectedCards.count
                        let someAssigned = assignedCount > 0 && !allAssigned

                        Button {
                            if allAssigned {
                                viewModel.removeTagFromCards(tag: tag, ids: selectedCardIDs)
                            } else {
                                viewModel.addTagToCards(tag: tag, ids: selectedCardIDs)
                            }
                        } label: {
                            HStack(spacing: 10) {
                                Circle()
                                    .fill(tag.color)
                                    .frame(width: 12, height: 12)
                                Text(tag.tagName)
                                    .foregroundStyle(.primary)
                                Spacer()
                                Group {
                                    if allAssigned {
                                        Image(systemName: "checkmark")
                                    } else if someAssigned {
                                        Image(systemName: "minus")
                                    }
                                }
                                .foregroundStyle(tag.color)
                                .fontWeight(.semibold)
                            }
                            .accessibilityElement(children: .combine)
                            .accessibilityLabel("\(tag.tagName)、\(allAssigned ? "付与済み" : someAssigned ? "一部付与" : "未付与")")
                        }
                    }
                }

                Button {
                    isShowingTagManager = true
                } label: {
                    Label("新規タグを作成", systemImage: "plus")
                }
            }
            .navigationTitle("タグを付ける（\(selectedCardIDs.count)件）")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完了") {
                        onDismiss()
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
            .sheet(isPresented: $isShowingTagManager) {
                TagManagementView()
                    .environmentObject(viewModel)
            }
        }
    }
}
