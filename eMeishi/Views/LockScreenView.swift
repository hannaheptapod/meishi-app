import SwiftUI

// アプリロック画面（生体認証要求）
struct LockScreenView: View {

    @Binding var isUnlocked: Bool
    @State private var isAuthenticating = false
    @State private var authenticationTask: Task<Void, Never>?
    @State private var viewLifetimeID = UUID()
    @State private var biometricType: AuthenticationService.BiometricType = .none

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
            viewLifetimeID = UUID()
            biometricType = authService.refreshAvailableBiometricType()
            authenticate()
        }
        .onDisappear {
            viewLifetimeID = UUID()
            authenticationTask?.cancel()
            authenticationTask = nil
            isAuthenticating = false
        }
    }

    private func authenticate() {
        guard !isAuthenticating else { return }
        isAuthenticating = true
        let lifetimeID = viewLifetimeID
        authenticationTask?.cancel()
        authenticationTask = Task {
            let success = await authService.authenticate(reason: "アプリのロックを解除")
            guard !Task.isCancelled, viewLifetimeID == lifetimeID else { return }
            isAuthenticating = false
            if success {
                isUnlocked = true
            }
            authenticationTask = nil
        }
    }

    private var unlockLabel: String {
        switch biometricType {
        case .faceID:  return "Face IDでロック解除"
        case .touchID: return "Touch IDでロック解除"
        case .none:    return "パスコードでロック解除"
        }
    }

    private var unlockIcon: String {
        switch biometricType {
        case .faceID:  return "faceid"
        case .touchID: return "touchid"
        case .none:    return "lock.open"
        }
    }
}
