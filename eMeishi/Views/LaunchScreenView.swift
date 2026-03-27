import SwiftUI

// アプリ起動時のスプラッシュ画面
struct LaunchScreenView: View {
    @State private var iconScale: CGFloat = 0.7
    @State private var iconOpacity: Double = 0
    @State private var textOpacity: Double = 0

    var body: some View {
        ZStack {
            // 背景: 深い青のグラデーション（アプリアイコンに合わせた配色）
            LinearGradient(
                gradient: Gradient(colors: [
                    Color(red: 0.0, green: 0.35, blue: 0.85),
                    Color(red: 0.0, green: 0.2, blue: 0.55)
                ]),
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            VStack(spacing: 20) {
                // 名刺スタックアイコン
                Image(systemName: "person.crop.rectangle.stack")
                    .font(.system(size: 72, weight: .thin))
                    .foregroundStyle(.white)
                    .scaleEffect(iconScale)
                    .opacity(iconOpacity)

                // アプリ名
                Text("eMeishi")
                    .font(.system(size: 36, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .opacity(textOpacity)
            }
        }
        .onAppear {
            withAnimation(.easeOut(duration: 0.6)) {
                iconScale = 1.0
                iconOpacity = 1.0
            }
            withAnimation(.easeOut(duration: 0.6).delay(0.2)) {
                textOpacity = 1.0
            }
        }
    }
}
