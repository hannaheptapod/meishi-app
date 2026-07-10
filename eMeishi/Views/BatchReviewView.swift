import SwiftUI
import UIKit

// 連続撮影後の一括確認画面
// 撮影した画像を順番にCardFormViewで表示し、1枚ずつ確認・保存する
struct BatchReviewView: View {

    @Binding var images: [UIImage]
    let onComplete: () -> Void

    @State private var currentIndex = 0

    var body: some View {
        if currentIndex < images.count {
            CardFormView(
                croppedImage: images[currentIndex],
                batchProgress: CardFormView.BatchProgress(
                    current: currentIndex + 1,
                    total: images.count
                ),
                onSave: {
                    if currentIndex + 1 >= images.count {
                        onComplete()
                    } else {
                        currentIndex += 1
                    }
                }
            )
            .id(currentIndex)
        } else if !images.isEmpty {
            // 全件処理済み
            Color.clear.onAppear { onComplete() }
        }
    }
}
