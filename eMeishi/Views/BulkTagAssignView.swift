import SwiftUI

// 一括タグ付けシート（選択モードから呼び出し）
struct BulkTagAssignView: View {

    let selectedCardIDs: Set<BusinessCard.ID>
    let onDismiss: () -> Void

    @EnvironmentObject private var viewModel: CardListViewModel
    @EnvironmentObject private var entitlementStore: EntitlementStore
    @Environment(\.dismiss) private var dismiss
    @State private var isShowingTagManager = false
    @State private var isShowingPaywall = false
    @State private var isAutoTagging = false
    @State private var autoTagResult: String? = nil

    var body: some View {
        NavigationStack {
            List {
                aiAutoTagSection
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
            .sheet(isPresented: $isShowingPaywall) {
                PaywallView(context: .bulkRetag)
                    .environmentObject(entitlementStore)
            }
        }
    }

    // MARK: - AI 一括リタグ（Pro 機能）

    @ViewBuilder
    private var aiAutoTagSection: some View {
        Section {
            if isAutoTagging {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("AI がタグを判定中...")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            } else {
                Button {
                    if entitlementStore.hasAccess {
                        if viewModel.allTags.isEmpty {
                            autoTagResult = "先にタグを 1 件以上作成してください"
                        } else {
                            Task { await runAutoTag() }
                        }
                    } else {
                        isShowingPaywall = true
                    }
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "sparkles")
                            .foregroundStyle(.tint)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("AI でタグを提案")
                                .font(.subheadline.bold())
                                .foregroundStyle(.primary)
                            Text(entitlementStore.hasAccess
                                 ? "選択した \(selectedCardIDs.count) 件に既存タグを自動で振り分けます"
                                 : "eMeishi Pro でご利用いただけます")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .foregroundStyle(.secondary)
                            .font(.caption)
                    }
                }
            }
            if let autoTagResult {
                Text(autoTagResult)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func runAutoTag() async {
        isAutoTagging = true
        autoTagResult = nil
        defer { isAutoTagging = false }
        let result = await viewModel.bulkAutoTag(ids: selectedCardIDs)
        if result.processed == 0 {
            autoTagResult = "対象の名刺がありません"
        } else {
            autoTagResult = "\(result.processed) 件のうち \(result.tagged) 件にタグを追加しました"
        }
    }
}
