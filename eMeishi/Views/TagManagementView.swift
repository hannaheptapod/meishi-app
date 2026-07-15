import SwiftUI

// タグ管理画面（作成・編集・削除）
struct TagManagementView: View {

    @EnvironmentObject private var viewModel: CardListViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var isShowingCreateSheet = false
    @State private var isShowingDeleteConfirm = false
    @State private var tagToDelete: Tag? = nil
    @State private var tagToEdit: Tag? = nil

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
                if !viewModel.allTags.isEmpty {
                    Section("タグ一覧") {
                        ForEach(viewModel.allTags) { tag in
                            Button {
                                tagToEdit = tag
                            } label: {
                                HStack(spacing: 10) {
                                    Circle()
                                        .fill(tag.color)
                                        .frame(width: 12, height: 12)
                                    Text(tag.tagName)
                                        .foregroundStyle(.primary)
                                    Spacer()
                                    Text("\(tag.cardArray.count)件")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .accessibilityElement(children: .combine)
                            .contextMenu {
                                Button {
                                    tagToEdit = tag
                                } label: {
                                    Label("編集", systemImage: "pencil")
                                }
                                Button(role: .destructive) {
                                    tagToDelete = tag
                                    isShowingDeleteConfirm = true
                                } label: {
                                    Label("削除", systemImage: "trash")
                                }
                            }
                        }
                        .onDelete { offsets in
                            if let idx = offsets.first {
                                tagToDelete = viewModel.allTags[idx]
                                isShowingDeleteConfirm = true
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
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    EditButton()
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        isShowingCreateSheet = true
                    } label: {
                        Label("タグを追加", systemImage: "plus")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完了") { dismiss() }
                }
            }
            .confirmationDialog(
                "タグを削除",
                isPresented: $isShowingDeleteConfirm,
                titleVisibility: .visible
            ) {
                Button("削除", role: .destructive) {
                    if let tag = tagToDelete {
                        viewModel.deleteTag(tag)
                    }
                    tagToDelete = nil
                }
                Button("キャンセル", role: .cancel) {
                    tagToDelete = nil
                }
            } message: {
                Text("「\(tagToDelete?.tagName ?? "")」を削除します。ひもづく名刺からもタグが外れます。")
            }
            .sheet(item: $tagToEdit) { tag in
                TagEditSheet(tag: tag)
                    .environmentObject(viewModel)
            }
            .sheet(isPresented: $isShowingCreateSheet) {
                TagCreateSheet()
                    .environmentObject(viewModel)
            }
        }
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
                                        .foregroundStyle(.white)
                                }
                            }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(preset.name)
                    .accessibilityAddTraits(selected.wrappedValue == preset.hex ? .isSelected : [])
                }
            }
            .padding(.vertical, 4)
        }
    }

    // インスタンスメソッド版（body 内で呼ぶ用）
    private func colorPicker(selected: Binding<String>) -> some View {
        Self.colorPicker(selected: selected)
    }
}

private struct TagCreateSheet: View {
    @EnvironmentObject private var viewModel: CardListViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var color = "#007AFF"

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
                        viewModel.createTag(name: trimmed, colorHex: color)
                        dismiss()
                    }
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .presentationDetents([.medium])
    }
}

// MARK: - タグ編集シート

struct TagEditSheet: View {

    @ObservedObject var tag: Tag
    @EnvironmentObject private var viewModel: CardListViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var editName: String = ""
    @State private var editColor: String = ""

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
                        viewModel.updateTag(tag, name: name, colorHex: editColor)
                        dismiss()
                    }
                    .fontWeight(.semibold)
                    .disabled(editName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .onAppear {
                editName = tag.tagName
                editColor = tag.colorHex ?? "#007AFF"
            }
        }
    }
}
