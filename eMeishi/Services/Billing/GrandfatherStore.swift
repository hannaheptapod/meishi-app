import Foundation
import StoreKit

// 1.1.0 より前のバージョンで初回起動したユーザーは AI 自然言語検索を Pro なしで利用できる。
//
// ⚠️ 1.0.x には firstLaunchMarketingVersion を記録するコードが入っていなかった。
// そのため 1.1.0 初回起動時点では UserDefaults は空になる。
// この前提の上で「1.1.0 より前から使っていたか」を複数の信号から推定する：
//
//   1. UserDefaults に過去の判定結果が pin されていれば採用（冪等性）
//   2. AppTransaction.originalAppVersion が取れれば真実の値として採用
//   3. AppTransaction が未検証／取得失敗なら、ローカル痕跡（名刺・設定書き込み）で判定
//   4. どれも該当しなければ現バージョンを pin（= 新規扱い）
//
// sentinel "0.0.0" は「既存ユーザー（Grandfather 付与対象）」を示す pin 値。
// iCloud KVS は entitlement 未設定のため使わず、UserDefaults のみを pin 先として使う。
// 機種変後の復元は CloudKit Private DB の GrandfatherMark レコードで担う。
@MainActor
final class GrandfatherStore {

    static let shared = GrandfatherStore(
        transactionProvider: LiveAppTransactionProvider(),
        detector: LiveExistingUserDetector(persistenceController: .shared),
        currentVersionProvider: {
            Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
        }
    )

    private let proReleaseVersion = "1.1.0"
    private let udKey = "firstLaunchMarketingVersion"
    private let grandfatherSentinel = "0.0.0"

    private let transactionProvider: AppTransactionProviding
    private let detector: ExistingUserDetector
    private let currentVersionProvider: () -> String

    private(set) var isGrandfathered = false

    init(
        transactionProvider: AppTransactionProviding,
        detector: ExistingUserDetector,
        currentVersionProvider: @escaping () -> String
    ) {
        self.transactionProvider = transactionProvider
        self.detector = detector
        self.currentVersionProvider = currentVersionProvider
    }

    func evaluate() async {
        let resolved = await resolvedFirstLaunchVersion()
        isGrandfathered = isBefore(resolved, proReleaseVersion)
    }

    // MARK: - Private

    private func resolvedFirstLaunchVersion() async -> String {
        let ud = UserDefaults.standard

        // 1. UserDefaults に pin 済み → そのまま採用
        if let local = ud.string(forKey: udKey) {
            return local
        }

        // 2. AppTransaction.originalAppVersion で真実を取得
        if let original = await transactionProvider.originalAppVersion() {
            if isBefore(original, proReleaseVersion) {
                pin(grandfatherSentinel, ud: ud)
                return grandfatherSentinel
            } else {
                pin(original, ud: ud)
                return original
            }
        }

        // 3. フォールバック: ローカルに既存ユーザー痕跡があれば Grandfather 扱い
        if detector.hasExistingUserSignals() {
            pin(grandfatherSentinel, ud: ud)
            return grandfatherSentinel
        }

        // 4. どの信号もなければ新規ユーザー。現バージョンを pin
        let current = currentVersionProvider()
        pin(current, ud: ud)
        return current
    }

    private func pin(_ version: String, ud: UserDefaults) {
        ud.set(version, forKey: udKey)
    }

    private func isBefore(_ version: String, _ threshold: String) -> Bool {
        let a = version.split(separator: ".").compactMap { Int($0) }
        let b = threshold.split(separator: ".").compactMap { Int($0) }
        let count = max(a.count, b.count)
        for i in 0..<count {
            let ai = i < a.count ? a[i] : 0
            let bi = i < b.count ? b[i] : 0
            if ai < bi { return true }
            if ai > bi { return false }
        }
        return false
    }
}
