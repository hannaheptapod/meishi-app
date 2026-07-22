import SwiftUI

nonisolated enum BulkTagAssignPresentation: String, Identifiable, Sendable {
    case tagManager
    case paywall

    var id: String { rawValue }
}

nonisolated struct BulkTagAssignmentSummary: Equatable, Sendable {
    enum Assignment: Equatable, Sendable {
        case none
        case some
        case all
    }

    let selectedCardCount: Int
    let countsByTagID: [UUID: Int]

    func assignment(for tagID: UUID?) -> Assignment {
        guard selectedCardCount > 0, let tagID else { return .none }
        let count = countsByTagID[tagID, default: 0]
        if count == selectedCardCount { return .all }
        return count > 0 ? .some : .none
    }
}

// 一括タグ付けシート（選択モードから呼び出し）
struct BulkTagAssignView: View {

    let selectedCardURIs: Set<URL>
    let onDismiss: () -> Void

    @EnvironmentObject private var viewModel: CardListViewModel
    @EnvironmentObject private var entitlementStore: EntitlementStore
    @State private var presentation: BulkTagAssignPresentation?
    @State private var isAutoTagging = false
    @State private var autoTagResult: String? = nil
    @State private var autoTagTask: Task<Void, Never>?
    @State private var autoTagTaskGate = SecondaryViewTaskGate()
    @State private var assignmentSummary = BulkTagAssignmentSummary(
        selectedCardCount: 0,
        countsByTagID: [:]
    )

    var body: some View {
        NavigationStack {
            List {
                aiAutoTagSection
                if viewModel.tagDisplaySnapshots.isEmpty {
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
                    ForEach(viewModel.tagDisplaySnapshots) { tag in
                        let assignment = assignmentSummary.assignment(for: tag.tagID)
                        let allAssigned = assignment == .all
                        let someAssigned = assignment == .some

                        Button {
                            if allAssigned {
                                viewModel.removeTagFromCards(
                                    tagObjectURI: tag.objectURI,
                                    cardObjectURIs: selectedCardURIs
                                )
                            } else {
                                viewModel.addTagToCards(
                                    tagObjectURI: tag.objectURI,
                                    cardObjectURIs: selectedCardURIs
                                )
                            }
                            refreshAssignmentSummary()
                        } label: {
                            HStack(spacing: 10) {
                                Circle()
                                    .fill(Color(hex: tag.colorHex))
                                    .frame(width: 12, height: 12)
                                Text(tag.name)
                                    .foregroundStyle(.primary)
                                Spacer()
                                Group {
                                    if allAssigned {
                                        Image(systemName: "checkmark")
                                    } else if someAssigned {
                                        Image(systemName: "minus")
                                    }
                                }
                                .foregroundStyle(Color(hex: tag.colorHex))
                                .fontWeight(.semibold)
                            }
                            .accessibilityElement(children: .combine)
                            .accessibilityLabel("\(tag.name)、\(allAssigned ? "付与済み" : someAssigned ? "一部付与" : "未付与")")
                        }
                        .disabled(isAutoTagging || tag.tagID == nil)
                    }
                }

                Button {
                    presentation = .tagManager
                } label: {
                    Label("新規タグを作成", systemImage: "plus")
                }
                .disabled(isAutoTagging)
            }
            .navigationTitle("タグを付ける（\(selectedCardURIs.count)件）")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完了") {
                        onDismiss()
                    }
                    .fontWeight(.semibold)
                    .disabled(isAutoTagging)
                }
            }
            .sheet(item: $presentation) { destination in
                switch destination {
                case .tagManager:
                    TagManagementView()
                        .environmentObject(viewModel)
                case .paywall:
                    PaywallView(context: .bulkRetag)
                        .environmentObject(entitlementStore)
                }
            }
            // Core Data更新の途中でシートだけ消え、背面へ遅れて反映される状態を作らない。
            .interactiveDismissDisabled(isAutoTagging)
            .onAppear(perform: refreshAssignmentSummary)
            .onChange(of: selectedCardURIs) { _, _ in
                refreshAssignmentSummary()
            }
            .onChange(of: viewModel.cardsContentRevision) { _, _ in
                refreshAssignmentSummary()
            }
            .onChange(of: viewModel.tagDisplaySnapshots) { _, _ in
                refreshAssignmentSummary()
            }
            .onDisappear(perform: cancelViewOwnedTasks)
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
                        if viewModel.tagDisplaySnapshots.isEmpty {
                            autoTagResult = "先にタグを 1 件以上作成してください"
                        } else {
                            // Task生成前に操作を閉じ、連続タップによる二重起動を防ぐ。
                            startAutoTag()
                        }
                    } else {
                        presentation = .paywall
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
                                 ? "選択した \(selectedCardURIs.count) 件に既存タグを自動で振り分けます"
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
        .interactiveDismissDisabled(isAutoTagging)
    }

    private func startAutoTag() {
        guard let operationID = autoTagTaskGate.begin() else { return }
        isAutoTagging = true
        autoTagResult = nil

        autoTagTask = Task { @MainActor in
            let result = await viewModel.bulkAutoTag(objectURIs: selectedCardURIs)
            guard !Task.isCancelled,
                  autoTagTaskGate.finish(operationID) else { return }
            autoTagTask = nil
            isAutoTagging = false
            refreshAssignmentSummary()
            if result.processed == 0 {
                autoTagResult = "対象の名刺がありません"
            } else {
                autoTagResult = "\(result.processed) 件のうち \(result.tagged) 件にタグを追加しました"
            }
        }
    }

    private func cancelViewOwnedTasks() {
        autoTagTaskGate.cancel()
        autoTagTask?.cancel()
        autoTagTask = nil
        isAutoTagging = false
        presentation = nil
    }

    private func refreshAssignmentSummary() {
        assignmentSummary = viewModel.bulkTagAssignmentSummary(for: selectedCardURIs)
    }
}
