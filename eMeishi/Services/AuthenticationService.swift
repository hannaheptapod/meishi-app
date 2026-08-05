import LocalAuthentication

// 生体認証（Face ID / Touch ID）の管理
@MainActor
class AuthenticationService {

    static let shared = AuthenticationService()

    enum BiometricType: Equatable, Sendable {
        case faceID
        case touchID
        case none
    }

    private var cachedBiometricType: BiometricType?

    // 利用可能な生体認証の種類を返す
    func availableBiometricType() -> BiometricType {
        if let cachedBiometricType {
            return cachedBiometricType
        }
        return refreshAvailableBiometricType()
    }

    /// 端末設定が変わり得るforeground復帰時だけ、利用可否を再評価する。
    @discardableResult
    func refreshAvailableBiometricType() -> BiometricType {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else {
            cachedBiometricType = BiometricType.none
            return BiometricType.none
        }
        let type: BiometricType
        switch context.biometryType {
        case .faceID:  type = .faceID
        case .touchID: type = .touchID
        default:       type = .none
        }
        cachedBiometricType = type
        return type
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
