import LocalAuthentication

// 生体認証（Face ID / Touch ID）の管理
class AuthenticationService {

    static let shared = AuthenticationService()

    enum BiometricType {
        case faceID
        case touchID
        case none
    }

    // 利用可能な生体認証の種類を返す
    func availableBiometricType() -> BiometricType {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else {
            return .none
        }
        switch context.biometryType {
        case .faceID:  return .faceID
        case .touchID: return .touchID
        default:       return .none
        }
    }

    // 生体認証を実行（パスコードフォールバック付き）
    func authenticate(reason: String) async -> Bool {
        let context = LAContext()
        do {
            return try await context.evaluatePolicy(
                .deviceOwnerAuthentication,
                localizedReason: reason
            )
        } catch {
            return false
        }
    }
}
