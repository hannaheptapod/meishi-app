import Foundation

// 1.1.0 より前のバージョンで初回起動したユーザーは AI 自然言語検索を Pro なしで利用できる。
// firstLaunchMarketingVersion を UserDefaults + iCloud Key-Value Store に保存し、
// 機種変更後も復元できるようにする。
@MainActor
final class GrandfatherStore {

    static let shared = GrandfatherStore()

    private let proReleaseVersion = "1.1.0"
    private let udKey = "firstLaunchMarketingVersion"

    private(set) var isGrandfathered = false

    private init() {}

    func evaluate() {
        let first = resolvedFirstLaunchVersion()
        isGrandfathered = isBefore(first, proReleaseVersion)
    }

    // MARK: - Private

    private func resolvedFirstLaunchVersion() -> String {
        let ud = UserDefaults.standard
        let iCloud = NSUbiquitousKeyValueStore.default
        let current = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"

        if let local = ud.string(forKey: udKey) {
            return local
        }
        if let remote = iCloud.string(forKey: udKey) {
            ud.set(remote, forKey: udKey)
            return remote
        }
        // 初回記録
        ud.set(current, forKey: udKey)
        iCloud.set(current, forKey: udKey)
        iCloud.synchronize()
        return current
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
