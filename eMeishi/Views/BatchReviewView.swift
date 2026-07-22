import SwiftUI

// 連続撮影後の一括確認画面
// 圧縮済み入力を順番にCardFormViewへ渡し、現在の1枚だけを展開して確認・保存する
struct BatchReviewView: View {

    @Binding var inputs: [CardImageInput]
    let queueID: UUID?
    @Binding var processedCount: Int
    let totalCount: Int
    @Binding var externalWarning: String?
    @Binding var isPendingQueueAvailable: Bool
    let onCardSaved: () -> Void
    let onComplete: () -> Void

    @State private var isAdvancing = false
    @State private var queuePersistenceWarning: String?
    @State private var advanceTask: Task<Void, Never>?
    @State private var advanceTaskGate = SecondaryViewTaskGate()
    @State private var advancingInputID: UUID?

    init(
        inputs: Binding<[CardImageInput]>,
        queueID: UUID?,
        processedCount: Binding<Int>,
        totalCount: Int,
        externalWarning: Binding<String?>,
        isPendingQueueAvailable: Binding<Bool>,
        onCardSaved: @escaping () -> Void = {},
        onComplete: @escaping () -> Void
    ) {
        _inputs = inputs
        self.queueID = queueID
        _processedCount = processedCount
        self.totalCount = totalCount
        _externalWarning = externalWarning
        _isPendingQueueAvailable = isPendingQueueAvailable
        self.onCardSaved = onCardSaved
        self.onComplete = onComplete
    }

    var body: some View {
        if let currentInput = inputs.first {
            ZStack {
                CardFormView(
                    input: currentInput,
                    batchProgress: CardFormView.BatchProgress(
                        current: processedCount + 1,
                        total: totalCount
                    ),
                    onSave: {
                        onCardSaved()
                        advance()
                    },
                    onSkip: { advance() }
                )
                .id(currentInput.id)
                .allowsHitTesting(!isAdvancing)

                if let queuePersistenceWarning {
                    Color.black.opacity(0.18)
                        .ignoresSafeArea()
                    VStack(spacing: AppTheme.Spacing.medium) {
                        Image(systemName: "externaldrive.badge.exclamationmark")
                            .font(.title2)
                            .foregroundStyle(.secondary)
                        Text("再開情報を更新できませんでした")
                            .font(.headline)
                        Text(queuePersistenceWarning)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                        Button("このまま続ける") {
                            self.queuePersistenceWarning = nil
                            if let operationID = advanceTaskGate.currentID,
                               let inputID = advancingInputID {
                                finishAdvance(
                                    operationID: operationID,
                                    expectedInputID: inputID
                                )
                            } else {
                                isAdvancing = false
                            }
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    .padding(AppTheme.Spacing.xLarge)
                    .frame(maxWidth: 360)
                    .background(
                        AppTheme.contentSurface,
                        in: .rect(
                            cornerRadius: AppTheme.contentCornerRadius,
                            style: .continuous
                        )
                    )
                    .padding(AppTheme.Spacing.large)
                    .accessibilityElement(children: .contain)
                } else if isAdvancing {
                    ProgressView()
                        .controlSize(.large)
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if let externalWarning {
                    HStack(alignment: .top, spacing: AppTheme.Spacing.small) {
                        Image(systemName: "exclamationmark.triangle")
                            .foregroundStyle(.secondary)
                        Text(externalWarning)
                            .font(.footnote)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Button {
                            self.externalWarning = nil
                        } label: {
                            Image(systemName: "xmark")
                                .frame(width: 32, height: 32)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("警告を閉じる")
                    }
                    .padding(.horizontal, AppTheme.Spacing.large)
                    .padding(.vertical, AppTheme.Spacing.small)
                    .background(AppTheme.auxiliarySurface)
                    .accessibilityElement(children: .contain)
                }
            }
            // 永続キューの先頭削除中や復旧警告の確認前にシートだけ閉じない。
            // 次回起動時の再開位置と、画面上の先頭入力が食い違うのを防ぐ。
            .interactiveDismissDisabled(
                isAdvancing || queuePersistenceWarning != nil || !isPendingQueueAvailable
            )
            .onDisappear {
                cancelAdvanceForDisappearance()
            }
        }
    }

    private func advance() {
        guard !isAdvancing,
              let expectedInputID = inputs.first?.id,
              let operationID = advanceTaskGate.begin() else { return }
        isAdvancing = true
        advancingInputID = expectedInputID
        guard isPendingQueueAvailable, let queueID else {
            finishAdvance(operationID: operationID, expectedInputID: expectedInputID)
            return
        }
        advanceTask?.cancel()
        advanceTask = Task {
            do {
                try await PendingOCRStore.shared.advance(
                    queueID: queueID,
                    expectedInputID: expectedInputID
                )
                guard acceptsAdvance(
                    operationID: operationID,
                    expectedInputID: expectedInputID
                ) else { return }
                finishAdvance(operationID: operationID, expectedInputID: expectedInputID)
            } catch {
                guard acceptsAdvance(
                    operationID: operationID,
                    expectedInputID: expectedInputID
                ) else { return }
                isPendingQueueAvailable = false
                queuePersistenceWarning = "アプリ終了後は正しい位置から再開できません。現在の確認処理は続けられます。"
                advanceTask = nil
            }
        }
    }

    private func acceptsAdvance(operationID: UUID, expectedInputID: UUID) -> Bool {
        !Task.isCancelled
            && advanceTaskGate.accepts(operationID)
            && advancingInputID == expectedInputID
            && inputs.first?.id == expectedInputID
    }

    private func finishAdvance(operationID: UUID, expectedInputID: UUID) {
        guard advanceTaskGate.accepts(operationID),
              advancingInputID == expectedInputID,
              inputs.first?.id == expectedInputID,
              advanceTaskGate.finish(operationID) else { return }
        isAdvancing = false
        advancingInputID = nil
        advanceTask = nil
        inputs.removeFirst()
        processedCount += 1
        if inputs.isEmpty {
            onComplete()
        }
    }

    private func cancelAdvanceForDisappearance() {
        advanceTaskGate.cancel()
        advanceTask?.cancel()
        advanceTask = nil
        advancingInputID = nil
        queuePersistenceWarning = nil
        isAdvancing = false
    }
}
