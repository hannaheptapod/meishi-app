import SwiftUI

nonisolated enum TagManagementPresentation: Identifiable, Equatable, Sendable {
    case create
    case edit(objectURI: String)
    case delete(TagDeletionRequest)

    var id: String {
        switch self {
        case .create: return "create"
        case .edit(let objectURI): return "edit:\(objectURI)"
        case .delete(let request): return "delete:\(request.id)"
        }
    }
}

nonisolated struct TagDeletionRequest: Identifiable, Equatable, Sendable {
    let objectURI: String
    let displayName: String

    var id: String { objectURI }
}

// タグ管理画面（作成・編集・削除）
struct TagManagementView: View {

    @EnvironmentObject private var viewModel: CardListViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var presentationState = QueuedPresentationState<TagManagementPresentation>()
    @State private var deletionCommitState = DismissalCommitState<TagDeletionRequest>()
    @StateObject private var contextMenuInteractionGate = ContextMenuInteractionGate<TagManagementPresentation>()

    // プリセットカラー
    static let presetColors: [(name: String, hex: String)] = [
        ("ブルー",   "#007AFF"),
        ("レッド",   "#FF3B30"),
        ("グリーン", "#34C759"),
        ("オレンジ", "#FF9500"),
        ("パープル", "#AF52DE"),
        ("ピンク",   "#FF2D55"),
        ("ティール", "#5AC8FA"),
        ("イエロー", "#FFCC00"),
    ]

    var body: some View {
        NavigationStack {
            List {
                // 既存タグ一覧
                if !viewModel.tagDisplaySnapshots.isEmpty {
                    Section("タグ一覧") {
                        ForEach(viewModel.tagDisplaySnapshots) { tag in
                            Button {
                                guard !contextMenuInteractionGate.blocksCardInteraction else { return }
                                presentEditor(for: tag)
                            } label: {
                                HStack(spacing: 10) {
                                    Circle()
                                        .fill(Color(hex: tag.colorHex))
                                        .frame(width: 12, height: 12)
                                    Text(tag.name)
                                        .foregroundStyle(.primary)
                                    Spacer()
                                    Text("\(tag.usageCount)件")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .buttonStyle(TagManagementRowButtonStyle())
                            .accessibilityElement(children: .combine)
                            .contextMenu {
                                Button {
                                    requestContextMenuPresentation(
                                        .edit(objectURI: tag.objectURI)
                                    )
                                } label: {
                                    Label("編集", systemImage: "pencil")
                                }
                                Button(role: .destructive) {
                                    requestContextMenuPresentation(
                                        .delete(deletionRequest(for: tag))
                                    )
                                } label: {
                                    Label("削除", systemImage: "trash")
                                }
                            } preview: {
                                tagContextPreview(tag)
                                    .background {
                                        ContextMenuPreviewLifecycleObserver(
                                            onPreviewPresented: {
                                                contextMenuInteractionGate.previewDidAppear()
                                            },
                                            onDismissalBegan: { sessionID in
                                                contextMenuInteractionGate.previewDidDisappear(
                                                    sessionID: sessionID
                                                )
                                            },
                                            onDismissalCompleted: { sessionID in
                                                completeContextMenuDismissal(sessionID: sessionID)
                                            },
                                            onDismissalCancelled: { sessionID in
                                                contextMenuInteractionGate.dismissalWasCancelled(
                                                    sessionID: sessionID
                                                )
                                            }
                                        )
                                        .frame(width: 0, height: 0)
                                    }
                            }
                        }
                        .onDelete { offsets in
                            if let idx = offsets.first {
                                requestDeletion(of: viewModel.tagDisplaySnapshots[idx])
                            }
                        }
                        .onMove { source, destination in
                            viewModel.moveTag(from: source, to: destination)
                        }
                    }
                }
            }
            .navigationTitle("タグ管理")
            .navigationBarTitleDisplayMode(.inline)
            .scrollContentBackground(.hidden)
            .background(AppTheme.background)
            .overlay {
                if viewModel.tagDisplaySnapshots.isEmpty {
                    ContentUnavailableView(
                        "タグがありません",
                        systemImage: "tag",
                        description: Text("右上の追加ボタンからタグを作成できます。")
                    )
                }
            }
            .overlay {
                if contextMenuInteractionGate.blocksCardInteraction {
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture { }
                        .accessibilityHidden(true)
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("完了") { dismiss() }
                }
                ToolbarItemGroup(placement: .primaryAction) {
                    if !viewModel.tagDisplaySnapshots.isEmpty {
                        EditButton()
                    }
                    Button {
                        requestPresentation(.create)
                    } label: {
                        Label("タグを追加", systemImage: "plus")
                    }
                }
            }
            .background {
                ZStack {
                    PresentationDismissalObserver(
                        activeID: activeConfirmationRequestID,
                        dismissingID: dismissingConfirmationRequestID,
                        onDismissalCompleted: completeConfirmationDismissal
                    )
                }
                .frame(width: 0, height: 0)
            }
            .confirmationDialog(
                "タグを削除",
                isPresented: deletionConfirmationBinding,
                titleVisibility: .visible,
                presenting: deletionRequest
            ) { request in
                Button("削除", role: .destructive) {
                    scheduleDeletionCommit(request)
                }
                Button("キャンセル", role: .cancel) {}
            } message: { request in
                Text(deletionMessage(for: request))
            }
            .sheet(item: sheetPresentationBinding, onDismiss: {
                completeSheetDismissal()
            }) { request in
                presentationView(request.destination)
            }
        }
    }

    @ViewBuilder
    private func presentationView(_ destination: TagManagementPresentation) -> some View {
        switch destination {
        case .create:
            TagCreateSheet()
                .environmentObject(viewModel)
        case .edit(let objectURI):
            if let resolvedTag = tagSnapshot(forURIString: objectURI) {
                TagEditSheet(
                    initialName: resolvedTag.name,
                    initialColor: resolvedTag.colorHex
                ) { name, colorHex in
                    viewModel.updateTag(
                        objectURI: objectURI,
                        name: name,
                        colorHex: colorHex
                    )
                }
            } else {
                TagUnavailableSheet()
            }
        case .delete:
            EmptyView()
        }
    }

    private func deletionMessage(for request: TagDeletionRequest) -> String {
        "「\(request.displayName)」を削除します。ひもづく名刺からもタグが外れます。"
    }

    private func presentEditor(for tag: TagDisplaySnapshot) {
        guard !contextMenuInteractionGate.blocksCardInteraction else { return }
        requestPresentation(.edit(objectURI: tag.objectURI))
    }

    private func tagContextPreview(_ tag: TagDisplaySnapshot) -> some View {
        HStack(spacing: AppTheme.Spacing.medium) {
            Circle()
                .fill(Color(hex: tag.colorHex))
                .frame(width: 14, height: 14)
            VStack(alignment: .leading, spacing: AppTheme.Spacing.xSmall) {
                Text(tag.name)
                    .font(.headline)
                Text("\(tag.usageCount)件の名刺")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(AppTheme.Spacing.large)
        .frame(minWidth: 220, alignment: .leading)
        .background(AppTheme.contentSurface)
    }

    private func requestDeletion(of tag: TagDisplaySnapshot) {
        requestPresentation(.delete(deletionRequest(for: tag)))
    }

    private func deletionRequest(for tag: TagDisplaySnapshot) -> TagDeletionRequest {
        TagDeletionRequest(
            objectURI: tag.objectURI,
            displayName: tag.name
        )
    }

    private func requestContextMenuPresentation(_ destination: TagManagementPresentation) {
        guard let immediateDestination = contextMenuInteractionGate.deferUntilDismissal(destination) else {
            return
        }
        presentContextMenuDestination(immediateDestination)
    }

    private func completeContextMenuDismissal(sessionID: UUID) {
        guard let destination = contextMenuInteractionGate.dismissalDidComplete(
            sessionID: sessionID
        ) else { return }
        presentContextMenuDestination(destination)
    }

    private func presentContextMenuDestination(_ destination: TagManagementPresentation) {
        requestPresentation(destination)
    }

    private var deletionRequest: TagDeletionRequest? {
        guard let active = presentationState.active,
              case .delete(let request) = active.destination else { return nil }
        return request
    }

    private var deletionConfirmationBinding: Binding<Bool> {
        Binding(
            get: { deletionRequest != nil },
            set: { isPresented in
                guard !isPresented, deletionRequest != nil else { return }
                beginActivePresentationDismissal()
            }
        )
    }

    /// sheet と削除確認を同じ排他状態から射影し、同時提示を防ぐ。
    private var sheetPresentationBinding: Binding<QueuedPresentationRequest<TagManagementPresentation>?> {
        Binding(
            get: {
                guard let active = presentationState.active else { return nil }
                switch active.destination {
                case .create, .edit:
                    return active
                case .delete:
                    return nil
                }
            },
            set: { newValue in
                guard newValue == nil,
                      let active = presentationState.active else { return }
                switch active.destination {
                case .create, .edit:
                    _ = presentationState.clearActive(requestID: active.id)
                case .delete:
                    break
                }
            }
        )
    }

    private func requestPresentation(_ destination: TagManagementPresentation) {
        presentationState.request(destination)
    }

    private func beginActivePresentationDismissal() {
        guard let active = presentationState.active else { return }
        _ = presentationState.clearActive(requestID: active.id)
    }

    private var activeConfirmationRequestID: UUID? {
        guard let active = presentationState.active,
              case .delete = active.destination else { return nil }
        return active.id
    }

    private var dismissingConfirmationRequestID: UUID? {
        guard let dismissing = presentationState.dismissing,
              case .delete = dismissing.destination else { return nil }
        return dismissing.id
    }

    private func completeConfirmationDismissal(requestID: UUID) {
        let deletion = deletionCommitState.take(afterDismissing: requestID)
        if let deletion {
            viewModel.deleteTag(objectURI: deletion.objectURI)
        }
        presentationState.presentNext(afterDismissing: requestID)
    }

    private func scheduleDeletionCommit(_ deletion: TagDeletionRequest) {
        guard let active = presentationState.active,
              case .delete = active.destination,
              deletionCommitState.schedule(deletion, for: active.id) else { return }
        beginActivePresentationDismissal()
    }

    private func completeSheetDismissal() {
        guard let requestID = presentationState.dismissing?.id else { return }
        presentationState.presentNext(afterDismissing: requestID)
    }

    private func tagSnapshot(forURIString uri: String) -> TagDisplaySnapshot? {
        viewModel.tagDisplaySnapshots.first { $0.objectURI == uri }
    }

    // MARK: - カラーピッカー（共通）

    static func colorPicker(selected: Binding<String>) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(presetColors, id: \.hex) { preset in
                    Button {
                        selected.wrappedValue = preset.hex
                    } label: {
                        Circle()
                            .fill(Color(hex: preset.hex))
                            .frame(width: 30, height: 30)
                            .overlay {
                                if selected.wrappedValue == preset.hex {
                                    Image(systemName: "checkmark")
                                        .font(.caption.bold())
                                        .foregroundStyle(preset.hex == "#FFCC00" ? .black : .white)
                                }
                            }
                            .frame(width: 44, height: 44)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(preset.name)
                    .accessibilityAddTraits(selected.wrappedValue == preset.hex ? .isSelected : [])
                }
            }
            .padding(.vertical, 4)
        }
    }
}

private struct TagManagementRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
    }
}

private struct TagUnavailableSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ContentUnavailableView(
                "タグが見つかりません",
                systemImage: "tag.slash",
                description: Text("対象のタグは削除されました。")
            )
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("閉じる") { dismiss() }
                }
            }
        }
    }
}

private struct TagCreateSheet: View {
    @EnvironmentObject private var viewModel: CardListViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var color = "#007AFF"
    @State private var saveError: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("タグ名") {
                    TextField("タグ名", text: $name)
                        .autocorrectionDisabled()
                }
                Section("カラー") {
                    TagManagementView.colorPicker(selected: $color)
                }
            }
            .navigationTitle("タグを追加")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("キャンセル") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("追加") {
                        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !trimmed.isEmpty else { return }
                        switch viewModel.createTag(name: trimmed, colorHex: color) {
                        case .success:
                            dismiss()
                        case .failure(let message):
                            saveError = message
                        }
                    }
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .presentationDetents([.medium])
        .alert("タグを追加できません", isPresented: Binding(
            get: { saveError != nil },
            set: { if !$0 { saveError = nil } }
        )) {
            Button("OK", role: .cancel) { saveError = nil }
        } message: {
            Text(saveError ?? "")
        }
    }
}

// MARK: - タグ編集シート

struct TagEditSheet: View {

    @Environment(\.dismiss) private var dismiss

    @State private var editName: String
    @State private var editColor: String
    @State private var saveError: String?
    private let save: (String, String) -> CardListViewModel.TagMutationResult

    init(
        initialName: String,
        initialColor: String,
        save: @escaping (String, String) -> CardListViewModel.TagMutationResult
    ) {
        _editName = State(initialValue: initialName)
        _editColor = State(initialValue: initialColor)
        self.save = save
    }

    var body: some View {
        NavigationStack {
            List {
                Section("タグ名") {
                    TextField("タグ名", text: $editName)
                        .autocorrectionDisabled()
                }

                Section("カラー") {
                    TagManagementView.colorPicker(selected: $editColor)
                }
            }
            .navigationTitle("タグを編集")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("キャンセル") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        let name = editName.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !name.isEmpty else { return }
                        switch save(name, editColor) {
                        case .success:
                            dismiss()
                        case .failure(let message):
                            saveError = message
                        }
                    }
                    .fontWeight(.semibold)
                    .disabled(editName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .alert("タグを保存できません", isPresented: Binding(
            get: { saveError != nil },
            set: { if !$0 { saveError = nil } }
        )) {
            Button("OK", role: .cancel) { saveError = nil }
        } message: {
            Text(saveError ?? "")
        }
    }
}
