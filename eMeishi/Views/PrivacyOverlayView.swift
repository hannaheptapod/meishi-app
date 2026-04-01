import SwiftUI

// App Switcher でコンテンツを隠すオーバーレイ
struct PrivacyOverlayView: View {
    var body: some View {
        ZStack {
            Color(.systemBackground)
                .ignoresSafeArea()
            VStack(spacing: 12) {
                Image("AppIconGray")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 120)

                Text("eMeishi")
                    .font(.system(.title3, design: .serif))
                    .foregroundStyle(.secondary)
            }
        }
    }
}
