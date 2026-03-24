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
            HStack(spacing: 0) {
                // A 列ヘッダー
                Text(pair.cardA.fullName.isEmpty ? "（名前なし）" : pair.cardA.fullName)
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                Divider()
                // B 列ヘッダー
                Text(pair.cardB.fullName.isEmpty ? "（名前なし）" : pair.cardB.fullName)
                    .font(.headline)
                    .frame(maxWidth: .infinity)
            }
        } header: {
            Text("どちらの値を残しますか？タップで選択")
        }
    }

    // MARK: - フィールド行

    private var fieldRows: some View {
        Group {
            mergeRow(label: "姓",      a: pair.cardA.lastName,  b: pair.cardB.lastName,  binding: $selections.lastName)
            mergeRow(label: "名",      a: pair.cardA.firstName, b: pair.cardB.firstName, binding: $selections.firstName)
            mergeRow(label: "会社名",  a: pair.cardA.company,   b: pair.cardB.company,   binding: $selections.company)
            mergeRow(label: "役職",    a: pair.cardA.title,     b: pair.cardB.title,     binding: $selections.title)
            mergeRow(label: "電話",    a: pair.cardA.phone,     b: pair.cardB.phone,     binding: $selections.phone)
            mergeRow(label: "メール",  a: pair.cardA.email,     b: pair.cardB.email,     binding: $selections.email)
            mergeRow(label: "住所",    a: pair.cardA.address,   b: pair.cardB.address,   binding: $selections.address)
            mergeRow(label: "Web",     a: pair.cardA.website,   b: pair.cardB.website,   binding: $selections.website)
            mergeRow(label: "メモ",    a: pair.cardA.notes,     b: pair.cardB.notes,     binding: $selections.notes)
        }
    }

    @ViewBuilder
    private func mergeRow(label: String, a: String?, b: String?, binding: Binding<Side>) -> some View {
        let aVal = a ?? ""
        let bVal = b ?? ""
        // 両方空なら行を表示しない
        if !aVal.isEmpty || !bVal.isEmpty {
            Section(label) {
                HStack(spacing: 0) {
                    // A 側
                    selectionCell(value: aVal, selected: binding.wrappedValue == .a) {
                        binding.wrappedValue = .a
                    }
                    Divider()
                    // B 側
                    selectionCell(value: bVal, selected: binding.wrappedValue == .b) {
                        binding.wrappedValue = .b
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func selectionCell(value: String, selected: Bool, onTap: @escaping () -> Void) -> some View {
        Button(action: onTap) {
            HStack {
                Text(value.isEmpty ? "（なし）" : value)
                    .foregroundStyle(value.isEmpty ? .secondary : .primary)
                    .font(.subheadline)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if selected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.accentColor)
                }
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
        .background(selected ? Color.accentColor.opacity(0.08) : .clear)
    }

    // MARK: - マージ実行

    private func merge() {
        let a = pair.cardA
        let b = pair.cardB

        // A カードに選択値を書き込む
        a.lastName  = selections.lastName  == .a ? (a.lastName  ?? "") : (b.lastName  ?? "")
        a.firstName = selections.firstName == .a ? (a.firstName ?? "") : (b.firstName ?? "")
        a.company   = selections.company   == .a ? (a.company   ?? "") : (b.company   ?? "")
        a.title     = selections.title     == .a ? (a.title     ?? "") : (b.title     ?? "")
        a.phone     = selections.phone     == .a ? (a.phone     ?? "") : (b.phone     ?? "")
        a.email     = selections.email     == .a ? (a.email     ?? "") : (b.email     ?? "")
        a.address   = selections.address   == .a ? (a.address   ?? "") : (b.address   ?? "")
        a.website   = selections.website   == .a ? (a.website   ?? "") : (b.website   ?? "")
        a.notes     = selections.notes     == .a ? (a.notes     ?? "") : (b.notes     ?? "")
        // 画像は非 nil の方を優先
        if a.imageData == nil { a.imageData = b.imageData }
        a.updatedAt = Date()

        // B カードを削除
        context.delete(b)

        do {
            try context.save()
        } catch {
            print("マージの保存に失敗しました: \(error)")
        }

        onComplete()
        dismiss()
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
