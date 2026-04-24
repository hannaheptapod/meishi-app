import Foundation

// 1.1.0 より前から使っていたかの「既存ユーザー性」をローカル痕跡から推定する。
// AppTransaction が取得できない（TestFlight 初回 offline 等）フォールバック経路。
// register(defaults:) の初期値は対象外とし、didSet で実際に書き込まれたキーのみ見る。
protocol ExistingUserDetector {
    func hasExistingUserSignals() -> Bool
}

@MainActor
struct LiveExistingUserDetector: ExistingUserDetector {

    let persistenceController: PersistenceController

    // SettingsStore の didSet で書き込まれる UserDefaults キー。
    // register(defaults:) の初期値は永続化ドメインに書かれないためここで検出される。
    private static let settingsWriteKeys: [String] = [
        "readingMethod",
        "duplicateThreshold",
        "csvIncludesBOM",
        "vCardVersion",
        "sortKey",
        "sortAscending",
        "iCloudSyncEnabled",
        "isAppLockEnabled",
        "lockGracePeriodSeconds",
        "hasPromptedInitialQwenDownload",
        "didShowProAnnouncement"
    ]

    func hasExistingUserSignals() -> Bool {
        if persistenceController.businessCardCount() >= 1 { return true }

        // 永続化ドメインを直接見て、register(defaults:) の初期値で誤判定しないようにする
        let bundleID = Bundle.main.bundleIdentifier ?? "com.jinks.emeishi"
        let domain = UserDefaults.standard.persistentDomain(forName: bundleID) ?? [:]
        for key in Self.settingsWriteKeys where domain[key] != nil {
            return true
        }
        return false
    }
}
