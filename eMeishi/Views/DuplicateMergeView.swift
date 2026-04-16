import SwiftUI
import CoreData
import os

// 重複ペアのマージ画面
// 各フィールドについて A / B どちらの値を使うか選択してマージする
struct DuplicateMergeView: View {

    let pair: DuplicatePair
    let onComplete: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var selections = FieldSelections()
    @State private var isShowingMergeConfirm = false

    private let context = PersistenceController.shared.container.viewContext

    var body: some View {
        NavigationStack {
            List {
                headerSection
                fieldRows
            }
            .navigationTitle("名刺をマージ")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: { Image(systemName: "xmark") }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("マージ") { isShowingMergeConfirm = true }
                        .bold()
                }
            }
            .confirmationDialog(
                "名刺をマージ",
                isPresented: $isShowingMergeConfirm,
                titleVisibility: .visible
            ) {
                Button("マージして1枚にまとめる", role: .destructive) { merge() }
                Button("キャンセル", role: .cancel) {}
            } message: {
                Text("「\(pair.cardB.fullName.isEmpty ? "名前なし" : pair.cardB.fullName)」は削除されます。この操作は取り消せません。")
            }
        }
    }

    // MARK: - ヘッダー（類似度 + 両カードのサマリー）

    private var headerSection: some View {
        Section {
            HStack(spacing: 12) {
                cardHeader(pair.cardA, side: .a)
                VStack(spacing: 4) {
                    Image(systemName: "arrow.left.arrow.right")
                        .foregroundStyle(.secondary)
                    Text(pair.scoreText)
                        .font(.caption2.bold())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(scoreColor(pair.score), in: Capsule())
                        .accessibilityLabel("類似度 \(pair.scoreText)")
                }
                cardHeader(pair.cardB, side: .b)
            }
            .padding(.vertical, 4)
        } header: {
            Text("残したい値の行をタップしてください")
        }
    }

    @ViewBuilder
    private func cardHeader(_ card: BusinessCard, side: Side) -> some View {
        VStack(alignment: side == .a ? .leading : .trailing, spacing: 2) {
            Text(card.fullName.isEmpty ? "（名前なし）" : card.fullName)
                .font(.subheadline.bold())
                .lineLimit(1)
            if let company = card.company, !company.isEmpty {
                Text(company)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            if let createdAt = card.createdAt {
                Text(createdAt.formatted(date: .abbreviated, time: .omitted))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: side == .a ? .leading : .trailing)
    }

    // MARK: - フィールド行（縦並び・選択しやすい設計）

    private var fieldRows: some View {
        Group {
            mergeRow(label: "名前",   aVal: pair.cardA.fullName,   bVal: pair.cardB.fullName,   binding: $selections.name)
            mergeRow(label: "会社名", aVal: pair.cardA.company,    bVal: pair.cardB.company,    binding: $selections.company)
            mergeRow(label: "部署",   aVal: pair.cardA.department, bVal: pair.cardB.department, binding: $selections.department)
            mergeRow(label: "役職",   aVal: pair.cardA.title,      bVal: pair.cardB.title,      binding: $selections.title)
            mergeRow(
                label: "電話",
                aVal: pair.cardA.phoneList.isEmpty ? nil : pair.cardA.phoneList.joined(separator: "\n"),
                bVal: pair.cardB.phoneList.isEmpty ? nil : pair.cardB.phoneList.joined(separator: "\n"),
                binding: $selections.phone
            )
            mergeRow(label: "メール", aVal: pair.cardA.email,   bVal: pair.cardB.email,   binding: $selections.email)
            mergeRow(label: "住所",   aVal: pair.cardA.address, bVal: pair.cardB.address, binding: $selections.address)
            mergeRow(label: "Web",    aVal: pair.cardA.website, bVal: pair.cardB.website, binding: $selections.website)
            mergeRow(label: "メモ",   aVal: pair.cardA.notes,   bVal: pair.cardB.notes,   binding: $selections.notes)
        }
    }

    @ViewBuilder
    private func mergeRow(label: String, aVal: String?, bVal: String?, binding: Binding<Side>) -> some View {
        let a = aVal ?? ""
        let b = bVal ?? ""
        if !a.isEmpty || !b.isEmpty {
            Section(label) {
                optionRow(value: a, side: .a, selected: binding.wrappedValue == .a) {
                    binding.wrappedValue = .a
                }
                optionRow(value: b, side: .b, selected: binding.wrappedValue == .b) {
                    binding.wrappedValue = .b
                }
            }
        }
    }

    @ViewBuilder
    private func optionRow(value: String, side: Side, selected: Bool, onTap: @escaping () -> Void) -> some View {
        Button(action: onTap) {
            HStack(spacing: 10) {
                // サイドラベル
                Text(side == .a ? "A" : "B")
                    .font(.caption2.bold())
                    .foregroundStyle(selected ? Color.accentColor : .secondary)
                    .frame(width: 18)

                // 値
                Text(value.isEmpty ? "（なし）" : value)
                    .foregroundStyle(value.isEmpty ? .tertiary : .primary)
                    .font(.subheadline)
                    .frame(maxWidth: .infinity, alignment: .leading)

                // 選択チェックマーク
                if selected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Color.accentColor)
                }
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(selected ? Color.accentColor.opacity(0.08) : nil)
        .accessibilityLabel("カード\(side == .a ? "A" : "B"): \(value.isEmpty ? "値なし" : value)")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityHint(selected ? "選択中" : "タップして選択")
    }

    // MARK: - マージ実行

    private func merge() {
        let a = pair.cardA
        let b = pair.cardB

        // cardB が既に削除済みの場合はスキップ
        guard !b.isDeleted, b.managedObjectContext != nil else {
            onComplete()
            dismiss()
            return
        }

        // 名前フィールドは名前マージ選択に従って両カードから取得
        if selections.name == .b {
            a.lastName        = b.lastName        ?? ""
            a.lastNameReading = b.lastNameReading ?? ""
            a.firstName       = b.firstName       ?? ""
            a.firstNameReading = b.firstNameReading ?? ""
        }
        a.company    = selections.company    == .a ? (a.company    ?? "") : (b.company    ?? "")
        a.department = selections.department == .a ? (a.department ?? "") : (b.department ?? "")
        a.title      = selections.title      == .a ? (a.title      ?? "") : (b.title      ?? "")
        a.phone      = selections.phone      == .a ? (a.phone      ?? "") : (b.phone      ?? "")
        a.email      = selections.email      == .a ? (a.email      ?? "") : (b.email      ?? "")
        a.address    = selections.address    == .a ? (a.address    ?? "") : (b.address    ?? "")
        a.website    = selections.website    == .a ? (a.website    ?? "") : (b.website    ?? "")
        a.notes      = selections.notes      == .a ? (a.notes      ?? "") : (b.notes      ?? "")
        if a.imageData == nil { a.imageData = b.imageData }

        // cardB のタグを cardA に転送（未保持のものだけ追加）
        if let bTags = b.tags as? Set<Tag> {
            for tag in bTags {
                a.addToTags(tag)
            }
        }

        a.updatedAt = Date()

        context.delete(b)

        do {
            try context.save()
        } catch {
            AppLogger.persistence.error("マージの保存に失敗しました: \(error)")
        }

        onComplete()
        dismiss()
    }

    private func scoreColor(_ score: Double) -> Color {
        score >= 0.9 ? .red : score >= 0.8 ? .orange : .mint
    }
}

// MARK: - 選択状態

private enum Side { case a, b }

private struct FieldSelections {
    var name:       Side = .a
    var company:    Side = .a
    var department: Side = .a
    var title:      Side = .a
    var phone:      Side = .a
    var email:      Side = .a
    var address:    Side = .a
    var website:    Side = .a
    var notes:      Side = .a
}
