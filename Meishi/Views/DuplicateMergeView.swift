import SwiftUI
import CoreData

// 重複ペアのマージ画面
// 各フィールドについて A / B どちらの値を使うか選択してマージする
struct DuplicateMergeView: View {

    let pair: DuplicatePair
    let onComplete: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var selections = FieldSelections()

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
                    Button("キャンセル") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("マージ") { merge() }
                        .bold()
                }
            }
        }
    }

    // MARK: - ヘッダー

    private var headerSection: some View {
        Section {
            HStack(spacing: 12) {
                cardHeader(pair.cardA, side: .a)
                // 類似度バッジ
                VStack(spacing: 4) {
                    Image(systemName: "arrow.left.arrow.right")
                        .foregroundStyle(.secondary)
                    Text(pair.scoreText)
                        .font(.caption2.bold())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(scoreColor(pair.score), in: Capsule())
                }
                cardHeader(pair.cardB, side: .b)
            }
            .padding(.vertical, 4)
        } header: {
            Text("残したい値をタップして選択してください")
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

    // MARK: - フィールド行

    private var fieldRows: some View {
        Group {
            mergeRow(label: "姓",     a: pair.cardA.lastName,  b: pair.cardB.lastName,  binding: $selections.lastName)
            mergeRow(label: "名",     a: pair.cardA.firstName, b: pair.cardB.firstName, binding: $selections.firstName)
            mergeRow(label: "会社名", a: pair.cardA.company,   b: pair.cardB.company,   binding: $selections.company)
            mergeRow(label: "役職",   a: pair.cardA.title,     b: pair.cardB.title,     binding: $selections.title)
            mergeRow(
                label: "電話",
                a: pair.cardA.phoneList.isEmpty ? nil : pair.cardA.phoneList.joined(separator: "\n"),
                b: pair.cardB.phoneList.isEmpty ? nil : pair.cardB.phoneList.joined(separator: "\n"),
                binding: $selections.phone
            )
            mergeRow(label: "メール", a: pair.cardA.email,   b: pair.cardB.email,   binding: $selections.email)
            mergeRow(label: "住所",   a: pair.cardA.address, b: pair.cardB.address, binding: $selections.address)
            mergeRow(label: "Web",    a: pair.cardA.website, b: pair.cardB.website, binding: $selections.website)
            mergeRow(label: "メモ",   a: pair.cardA.notes,   b: pair.cardB.notes,   binding: $selections.notes)
        }
    }

    @ViewBuilder
    private func mergeRow(label: String, a: String?, b: String?, binding: Binding<Side>) -> some View {
        let aVal = a ?? ""
        let bVal = b ?? ""
        if !aVal.isEmpty || !bVal.isEmpty {
            Section(label) {
                HStack(spacing: 0) {
                    selectionCell(value: aVal, side: .a, selected: binding.wrappedValue == .a) {
                        binding.wrappedValue = .a
                    }
                    Divider()
                    selectionCell(value: bVal, side: .b, selected: binding.wrappedValue == .b) {
                        binding.wrappedValue = .b
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func selectionCell(value: String, side: Side, selected: Bool, onTap: @escaping () -> Void) -> some View {
        Button(action: onTap) {
            HStack(alignment: .top) {
                if side == .b {
                    Spacer()
                }
                Text(value.isEmpty ? "（なし）" : value)
                    .foregroundStyle(value.isEmpty ? .tertiary : .primary)
                    .font(.subheadline)
                    .multilineTextAlignment(side == .a ? .leading : .trailing)
                    .frame(maxWidth: .infinity, alignment: side == .a ? .leading : .trailing)
                if selected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Color.accentColor)
                        .font(.body)
                }
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
        .background(
            selected
                ? Color.accentColor.opacity(0.12)
                : (value.isEmpty ? Color.clear : Color.clear)
        )
    }

    // MARK: - マージ実行

    private func merge() {
        let a = pair.cardA
        let b = pair.cardB

        a.lastName  = selections.lastName  == .a ? (a.lastName  ?? "") : (b.lastName  ?? "")
        a.firstName = selections.firstName == .a ? (a.firstName ?? "") : (b.firstName ?? "")
        a.company   = selections.company   == .a ? (a.company   ?? "") : (b.company   ?? "")
        a.title     = selections.title     == .a ? (a.title     ?? "") : (b.title     ?? "")
        a.phone     = selections.phone     == .a ? (a.phone     ?? "") : (b.phone     ?? "")
        a.email     = selections.email     == .a ? (a.email     ?? "") : (b.email     ?? "")
        a.address   = selections.address   == .a ? (a.address   ?? "") : (b.address   ?? "")
        a.website   = selections.website   == .a ? (a.website   ?? "") : (b.website   ?? "")
        a.notes     = selections.notes     == .a ? (a.notes     ?? "") : (b.notes     ?? "")
        if a.imageData == nil { a.imageData = b.imageData }
        a.updatedAt = Date()

        context.delete(b)

        do {
            try context.save()
        } catch {
            print("マージの保存に失敗しました: \(error)")
        }

        onComplete()
        dismiss()
    }

    private func scoreColor(_ score: Double) -> Color {
        score >= 0.9 ? .red : score >= 0.8 ? .orange : .yellow
    }
}

// MARK: - 選択状態

private enum Side { case a, b }

private struct FieldSelections {
    var lastName:  Side = .a
    var firstName: Side = .a
    var company:   Side = .a
    var title:     Side = .a
    var phone:     Side = .a
    var email:     Side = .a
    var address:   Side = .a
    var website:   Side = .a
    var notes:     Side = .a
}
