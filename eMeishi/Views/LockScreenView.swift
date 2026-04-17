import SwiftUI

// アプリロック画面（生体認証要求）
struct LockScreenView: View {

    @Binding var isUnlocked: Bool
    @State private var isAuthenticating = false

    private let authService = AuthenticationService.shared

    var body: some View {
        ZStack {
            Color(.systemBackground)
                .ignoresSafeArea()

            VStack(spacing: 32) {
                Image("AppIconGray")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 120)

                Text("eMeishi")
                    .font(.system(.title3, design: .serif))
                    .foregroundStyle(.secondary)

                Button {
                    authenticate()
                } label: {
                    Label(unlockLabel, systemImage: unlockIcon)
                        .font(.body)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .disabled(isAuthenticating)
            }
        }
        .onAppear {
            authenticate()
        }
    }

    private func authenticate() {
        guard !isAuthenticating else { return }
        isAuthenticating = true
        Task {
            let success = await authService.authenticate(reason: "アプリのロックを解除")
            isAuthenticating = false
            if success {
                withAnimation(.easeOut(duration: 0.2)) {
                    isUnlocked = true
                }
            }
        }
    }

    private var unlockLabel: String {
        switch authService.availableBiometricType() {
        case .faceID:  return "Face IDでロック解除"
        case .touchID: return "Touch IDでロック解除"
        case .none:    return "パスコードでロック解除"
        }
    }

    private var unlockIcon: String {
        switch authService.availableBiometricType() {
        case .faceID:  return "faceid"
        case .touchID: return "touchid"
        case .none:    return "lock.open"
        }
    }
}
