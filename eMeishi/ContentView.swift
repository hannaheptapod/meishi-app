import SwiftUI

// ルートビュー：スプラッシュ画面 → メイン画面の遷移を管理
struct ContentView: View {
    @State private var isShowingSplash = true

    var body: some View {
        ZStack {
            CardListView()

            if isShowingSplash {
                LaunchScreenView()
                    .transition(.opacity)
                    .zIndex(1)
            }
        }
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {
                withAnimation(.easeInOut(duration: 0.4)) {
                    isShowingSplash = false
                }
            }
        }
    }
}
