import SwiftUI

// タグ管理画面（作成・削除・色変更）
struct TagManagementView: View {

    @EnvironmentObject private var viewModel: CardListViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var newTagName: String = ""
    @State private var selectedColor: String = "#007AFF"
    @State private var isShowingDeleteConfirm = false
    @State private var tagToDelete: Tag? = nil

    // プリセットカラー
    private static let presetColors: [(name: String, hex: String)] = [
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
                // 新規タグ作成
                Section("タグを追加") {
                    TextField("タグ名", text: $newTagName)
                        .autocorrectionDisabled()

                    // カラー選択
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 10) {
                            ForEach(Self.presetColors, id: \.hex) { preset in
                                Button {
                                    selectedColor = preset.hex
                                } label: {
                                    Circle()
                                        .fill(Color(hex: preset.hex))
                                        .frame(width: 30, height: 30)
                                        .overlay {
                                            if selectedColor == preset.hex {
                                                Image(systemName: "checkmark")
                                                    .font(.caption.bold())
                                                    .foregroundStyle(.white)
                                            }
                                        }
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel(preset.name)
                                .accessibilityAddTraits(selectedColor == preset.hex ? .isSelected : [])
                            }
                        }
                        .padding(.vertical, 4)
                    }

                    Button {
                        let name = newTagName.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !name.isEmpty else { return }
                        viewModel.createTag(name: name, colorHex: selectedColor)
                        newTagName = ""
                    } label: {
                        Label("追加", systemImage: "plus.circle.fill")
                    }
                    .disabled(newTagName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }

                // 既存タグ一覧
                if !viewModel.allTags.isEmpty {
                    Section("タグ一覧") {
                        ForEach(viewModel.allTags) { tag in
                            HStack(spacing: 10) {
                                Circle()
                                    .fill(tag.color)
                                    .frame(width: 12, height: 12)
                                Text(tag.tagName)
                                Spacer()
                                Text("\(tag.cardArray.count)件")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .accessibilityElement(children: .combine)
                        }
                        .onDelete { offsets in
                            if let idx = offsets.first {
                                tagToDelete = viewModel.allTags[idx]
                                isShowingDeleteConfirm = true
                            }
                        }
                    }
                }
            }
            .navigationTitle("タグ管理")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
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
                Text("「\(tagToDelete?.tagName ?? "")」を削除します。紐づく名刺からもタグが外れます。")
            }
        }
    }
}
