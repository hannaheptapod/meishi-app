import SwiftUI

// 一括タグ付けシート（選択モードから呼び出し）
struct BulkTagAssignView: View {

    let selectedCardIDs: Set<BusinessCard.ID>
    let onDismiss: () -> Void

    @EnvironmentObject private var viewModel: CardListViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if viewModel.allTags.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "tag.slash")
                            .font(.system(size: 40))
                            .foregroundStyle(.secondary)
                        Text("タグがありません")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Text("タグ管理画面で作成してください")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("タグがありません。タグ管理画面で作成してください。")
                } else {
                    List {
                        ForEach(viewModel.allTags) { tag in
                            Button {
                                viewModel.addTagToCards(tag: tag, ids: selectedCardIDs)
                            } label: {
                                HStack(spacing: 10) {
                                    Circle()
                                        .fill(tag.color)
                                        .frame(width: 12, height: 12)
                                    Text(tag.tagName)
                                        .foregroundStyle(.primary)
                                    Spacer()
                                    Image(systemName: "plus.circle")
                                        .foregroundStyle(.secondary)
                                }
                                .accessibilityElement(children: .combine)
                                .accessibilityLabel("\(tag.tagName)タグを付ける")
                            }
                        }
                    }
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
                }
            }
        }
    }
}
