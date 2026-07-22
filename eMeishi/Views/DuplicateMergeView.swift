import SwiftUI
import CoreData
import os

nonisolated private enum DuplicateMergePhase: Equatable, Sendable {
    case selectingValues
    case confirmingMerge
}

// 重複ペアのマージ画面
// 各フィールドについて A / B どちらの値を使うか選択してマージする
struct DuplicateMergeView: View {

    let request: DuplicateMergeRequest
    let onComplete: () -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.managedObjectContext) private var context
    @State private var selections: FieldSelections
    @State private var phase: DuplicateMergePhase = .selectingValues
    @State private var mergeError: String?
    @State private var isMerging = false
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    /// View の State には NSManagedObject ではなく、解決時点の不変値を保持する。
    @State private var cardA: DuplicateMergeCardSnapshot?
    @State private var cardB: DuplicateMergeCardSnapshot?

    init(request: DuplicateMergeRequest, onComplete: @escaping () -> Void) {
        self.request = request
        self.onComplete = onComplete
        _cardA = State(initialValue: request.cardA)
        _cardB = State(initialValue: request.cardB)
        if let cardA = request.cardA, let cardB = request.cardB {
            _selections = State(initialValue: FieldSelections(cardA: cardA, cardB: cardB))
        } else {
            _selections = State(initialValue: FieldSelections())
        }
    }

    private var pair: DuplicatePair { request.pair }

    var body: some View {
        NavigationStack {
            Group {
                if phase == .confirmingMerge, let cardB {
                    mergeConfirmationContent(cardB: cardB)
                } else if let cardA, let cardB {
                    mergeContent(cardA: cardA, cardB: cardB)
                } else {
                    missingCardView
                }
            }
            .navigationTitle(phase == .confirmingMerge ? "マージを確認" : "名刺をマージ")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if phase == .confirmingMerge {
                        Button("戻る", systemImage: "chevron.left") {
                            phase = .selectingValues
                        }
                    } else {
                        Button { dismiss() } label: { Image(systemName: "xmark") }
                    }
                }
                if phase == .selectingValues, cardA != nil, cardB != nil {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("マージ") { phase = .confirmingMerge }
                            .bold()
                            .disabled(isMerging)
                    }
                }
            }
        }
    }

    // MARK: - メインコンテンツ

    @ViewBuilder
    private func mergeContent(cardA: DuplicateMergeCardSnapshot, cardB: DuplicateMergeCardSnapshot) -> some View {
        List {
            if let mergeError {
                Section {
                    Label {
                        Text(mergeError)
                            .foregroundStyle(.primary)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                    }
                }
            }
            headerSection(cardA: cardA, cardB: cardB)
            fieldRows(cardA: cardA, cardB: cardB)
        }
    }

    // 削除済み等で解決失敗した場合の表示
    private var missingCardView: some View {
        ContentUnavailableView(
            "名刺が見つかりません",
            systemImage: "exclamationmark.triangle",
            description: Text("対象の名刺が削除されたため、マージできません。")
        )
    }

    /// 親sheet上に別のconfirmationDialogを重ねず、同じsheet内で最終確認を完結させる。
    private func mergeConfirmationContent(cardB: DuplicateMergeCardSnapshot) -> some View {
        List {
            Section {
                Label {
                    VStack(alignment: .leading, spacing: AppTheme.Spacing.xSmall) {
                        Text("選択した内容で1枚にまとめます")
                            .font(.headline)
                        Text("削除される名刺は元に戻せません。")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                }
            }

            Section("削除される名刺") {
                LabeledContent("名前", value: cardB.fullName.isEmpty ? "（名前なし）" : cardB.fullName)
                if !cardB.company.isEmpty {
                    LabeledContent("会社名", value: cardB.company)
                }
            }

            if let mergeError {
                Section {
                    Label(mergeError, systemImage: "exclamationmark.circle")
                        .foregroundStyle(.red)
                }
            }

            Section {
                Button("マージして1枚にまとめる", role: .destructive) {
                    merge()
                }
                .disabled(isMerging)
                .accessibilityIdentifier("confirmDuplicateMergeButton")

                Button("キャンセル", role: .cancel) {
                    phase = .selectingValues
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    // MARK: - ヘッダー（類似度 + 両カードのサマリー）

    private func headerSection(cardA: DuplicateMergeCardSnapshot, cardB: DuplicateMergeCardSnapshot) -> some View {
        Section {
            Group {
                if dynamicTypeSize.isAccessibilitySize {
                    VStack(alignment: .leading, spacing: AppTheme.Spacing.small) {
                        cardHeader(cardA, side: .a)
                        DuplicateScoreBadge(scoreText: pair.scoreText)
                        cardHeader(cardB, side: .b)
                    }
                } else {
                    HStack(spacing: AppTheme.Spacing.medium) {
                        cardHeader(cardA, side: .a)
                        VStack(spacing: AppTheme.Spacing.xSmall) {
                            Image(systemName: "arrow.left.arrow.right")
                                .foregroundStyle(.secondary)
                            DuplicateScoreBadge(scoreText: pair.scoreText)
                        }
                        cardHeader(cardB, side: .b)
                    }
                }
            }
            .padding(.vertical, AppTheme.Spacing.xSmall)
        } header: {
            Text("残したい値の行をタップしてください")
        }
    }

    @ViewBuilder
    private func cardHeader(_ card: DuplicateMergeCardSnapshot, side: Side) -> some View {
        VStack(alignment: side == .a ? .leading : .trailing, spacing: 2) {
            Text(card.fullName.isEmpty ? "（名前なし）" : card.fullName)
                .font(.subheadline.bold())
                .lineLimit(1)
            if !card.company.isEmpty {
                Text(card.company)
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

    private func fieldRows(cardA: DuplicateMergeCardSnapshot, cardB: DuplicateMergeCardSnapshot) -> some View {
        Group {
            Section {
                Text("異なる項目だけを先に表示しています。残したい値を選んでください。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            mergeRow(label: "名前",   aVal: cardA.fullName,   bVal: cardB.fullName,   binding: $selections.name)
            mergeRow(label: "会社名", aVal: cardA.company,    bVal: cardB.company,    binding: $selections.company)
            mergeRow(label: "部署",   aVal: cardA.department, bVal: cardB.department, binding: $selections.department)
            mergeRow(label: "役職",   aVal: cardA.title,      bVal: cardB.title,      binding: $selections.title)
            mergeRow(
                label: "電話",
                aVal: cardA.phoneList.isEmpty ? nil : cardA.phoneList.joined(separator: "\n"),
                bVal: cardB.phoneList.isEmpty ? nil : cardB.phoneList.joined(separator: "\n"),
                binding: $selections.phone
            )
            mergeRow(label: "メール", aVal: cardA.email,   bVal: cardB.email,   binding: $selections.email)
            mergeRow(label: "住所",   aVal: cardA.address, bVal: cardB.address, binding: $selections.address)
            mergeRow(label: "Web",    aVal: cardA.website, bVal: cardB.website, binding: $selections.website)
            mergeRow(label: "メモ",   aVal: cardA.notes,   bVal: cardB.notes,   binding: $selections.notes)

            Section("統合後プレビュー") {
                previewRow("名前", value: selectedValue(cardA.fullName, cardB.fullName, side: selections.name))
                previewRow("会社名", value: selectedValue(cardA.company, cardB.company, side: selections.company))
                previewRow("電話", value: selectedValue(
                    cardA.phoneList.joined(separator: "、"),
                    cardB.phoneList.joined(separator: "、"),
                    side: selections.phone
                ))
                previewRow("メール", value: selectedValue(cardA.email, cardB.email, side: selections.email))
            }

            Section("削除対象") {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(cardB.fullName.isEmpty ? "（名前なし）" : cardB.fullName)
                        if !cardB.company.isEmpty {
                            Text(cardB.company)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                } icon: {
                    Image(systemName: "trash")
                        .foregroundStyle(.red)
                }
            }
        }
    }

    @ViewBuilder
    private func mergeRow(label: String, aVal: String?, bVal: String?, binding: Binding<Side>) -> some View {
        let a = aVal ?? ""
        let b = bVal ?? ""
        if (!a.isEmpty || !b.isEmpty) && a != b {
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

    private func selectedValue(_ a: String?, _ b: String?, side: Side) -> String {
        side == .a ? (a ?? "") : (b ?? "")
    }

    private func previewRow(_ label: String, value: String) -> some View {
        LabeledContent(label, value: value.isEmpty ? "（なし）" : value)
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
        guard !isMerging else { return }
        guard let snapshotA = cardA, let snapshotB = cardB,
              let a = context.businessCard(forURIString: snapshotA.objectURI),
              let b = context.businessCard(forURIString: snapshotB.objectURI) else {
            mergeError = "対象の名刺が見つかりません。"
            return
        }

        // cardB が既に削除済みの場合はスキップ
        guard !b.isDeleted, b.managedObjectContext != nil else {
            mergeError = "削除対象の名刺が見つかりません。"
            return
        }

        guard snapshotA.matchesCurrentValues(of: a),
              snapshotB.matchesCurrentValues(of: b) else {
            mergeError = "統合対象の名刺が更新されました。画面を開き直して内容を確認してください。"
            return
        }

        isMerging = true
        defer { isMerging = false }

        do {
            try DuplicateMergeService.merge(
                cardA: a,
                cardB: b,
                selection: selections,
                in: context
            )
            onComplete()
        } catch {
            AppLogger.persistence.error("マージの保存に失敗しました: \(error)")
            mergeError = "変更を保存できませんでした。入力内容を確認して、もう一度お試しください。"
        }
    }
}

// MARK: - 選択状態

private typealias Side = DuplicateMergeSelection.Source
private typealias FieldSelections = DuplicateMergeSelection
