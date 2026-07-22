import SwiftUI
import UIKit

// 連続撮影後の一括確認画面
// 撮影した画像を順番にCardFormViewで表示し、1枚ずつ確認・保存する
struct BatchReviewView: View {

    @Binding var images: [UIImage]
    let onComplete: () -> Void

    @State private var currentIndex = 0
    @State private var isAdvancing = false
    @State private var queuePersistenceWarning: String?

    var body: some View {
        if currentIndex < images.count {
            CardFormView(
                croppedImage: images[currentIndex],
                batchProgress: CardFormView.BatchProgress(
                    current: currentIndex + 1,
                    total: images.count
                ),
                onSave: {
                    advance()
                },
                onSkip: { advance() }
            )
            .id(currentIndex)
            .allowsHitTesting(!isAdvancing)
            .overlay {
                if isAdvancing {
                    ProgressView()
                        .controlSize(.large)
                }
            }
            .alert(
                "再開情報を更新できませんでした",
                isPresented: Binding(
                    get: { queuePersistenceWarning != nil },
                    set: { if !$0 { queuePersistenceWarning = nil } }
                )
            ) {
                Button("このまま続ける") {
                    queuePersistenceWarning = nil
                    finishAdvance()
                }
            } message: {
                Text(queuePersistenceWarning ?? "")
            }
        }
    }

    private func advance() {
        guard !isAdvancing else { return }
        isAdvancing = true
        Task {
            do {
                try await PendingOCRStore.shared.removeFirst()
                finishAdvance()
            } catch {
                isAdvancing = false
                queuePersistenceWarning = "アプリ終了後は正しい位置から再開できません。現在の確認処理は続けられます。"
            }
        }
    }

    private func finishAdvance() {
        isAdvancing = false
        if currentIndex + 1 >= images.count {
            onComplete()
        } else {
            currentIndex += 1
        }
    }
}
