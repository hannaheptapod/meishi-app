import Foundation
import Combine

// 読み取り方法の選択肢
enum ReadingMethod: String, CaseIterable, Identifiable {
    case automatic          = "automatic"
    case appleIntelligence  = "appleIntelligence"
    case localLLM           = "localLLM"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .automatic:         return "自動（推奨）"
        case .appleIntelligence: return "Apple Intelligence"
        case .localLLM:          return "AIアシスト"
        }
    }

    var description: String {
        switch self {
        case .automatic:
            return "利用できる最高精度のエンジンを自動で選択します"
        case .appleIntelligence:
            return "Apple Intelligence を使用します（iPhone 15 Pro 以降・要 Apple Intelligence 有効）"
        case .localLLM:
            return "ダウンロード済みのAIモデルを使用します（要ダウンロード）"
        }
    }
}

// アプリ設定の永続化管理（UserDefaults）
@MainActor
class SettingsStore: ObservableObject {

    @MainActor static let shared = SettingsStore()

    // MARK: - 読み取り方法

    @Published var readingMethod: ReadingMethod {
        didSet { UserDefaults.standard.set(readingMethod.rawValue, forKey: Keys.readingMethod) }
    }

    // MARK: - 重複チェック設定

    /// 重複検出の閾値（0.5〜1.0、デフォルト 0.75）
    @Published var duplicateThreshold: Double {
        didSet { UserDefaults.standard.set(duplicateThreshold, forKey: Keys.duplicateThreshold) }
    }

    // MARK: - ソート設定

    @Published var sortKey: String {
        didSet { UserDefaults.standard.set(sortKey, forKey: Keys.sortKey) }
    }

    @Published var sortAscending: Bool {
        didSet { UserDefaults.standard.set(sortAscending, forKey: Keys.sortAscending) }
    }

    // MARK: - エクスポート設定

    /// CSV に BOM（UTF-8 BOM）を付与するか（デフォルト: true）
    @Published var csvIncludesBOM: Bool {
        didSet { UserDefaults.standard.set(csvIncludesBOM, forKey: Keys.csvIncludesBOM) }
    }

    /// vCard バージョン（"3.0" or "4.0"、デフォルト: "3.0"）
    @Published var vCardVersion: String {
        didSet { UserDefaults.standard.set(vCardVersion, forKey: Keys.vCardVersion) }
    }

    // MARK: - iCloud 同期設定

    /// iCloud 同期の有効/無効（変更後はアプリの再起動が必要）
    @Published var iCloudSyncEnabled: Bool {
        didSet { UserDefaults.standard.set(iCloudSyncEnabled, forKey: Keys.iCloudSyncEnabled) }
    }

    // MARK: - セキュリティ設定

    /// アプリロック（Face ID / Touch ID）の有効/無効
    @Published var isAppLockEnabled: Bool {
        didSet { UserDefaults.standard.set(isAppLockEnabled, forKey: Keys.isAppLockEnabled) }
    }

    /// バックグラウンドからの復帰時にロックするまでの猶予（秒）
    @Published var lockGracePeriodSeconds: Int {
        didSet { UserDefaults.standard.set(lockGracePeriodSeconds, forKey: Keys.lockGracePeriodSeconds) }
    }

    // MARK: - 初回起動フラグ

    /// Foundation Models 非対応端末向けの初回 Qwen ダウンロードプロンプトを表示済みかどうか
    @Published var hasPromptedInitialQwenDownload: Bool {
        didSet { UserDefaults.standard.set(hasPromptedInitialQwenDownload, forKey: Keys.hasPromptedInitialQwenDownload) }
    }

    /// Grandfather ユーザーへの Pro リリース初回告知を表示済みかどうか
    @Published var didShowProAnnouncement: Bool {
        didSet { UserDefaults.standard.set(didShowProAnnouncement, forKey: Keys.didShowProAnnouncement) }
    }

    // MARK: - 初期化

    private init() {
        let ud = UserDefaults.standard

        // UITest モード起動時はアプリの永続化ドメインを消去し、シミュレータ残留状態
        // （例: 前回実行でソートを昇順に切り替えた状態）の持ち込みを防ぐ。
        // 本アプリのユーザー設定には影響しない（-UITestMode 引数は XCUITest 専用）。
        if ProcessInfo.processInfo.arguments.contains("-UITestMode"),
           let bundleID = Bundle.main.bundleIdentifier {
            ud.removePersistentDomain(forName: bundleID)
        }

        ud.register(defaults: [
            Keys.readingMethod:                    ReadingMethod.automatic.rawValue,
            Keys.duplicateThreshold:               0.75,
            Keys.csvIncludesBOM:                   true,
            Keys.vCardVersion:                     "3.0",
            Keys.sortKey:                          CardSortKey.createdAt.rawValue,
            Keys.sortAscending:                    false,
            Keys.iCloudSyncEnabled:                false,
            Keys.isAppLockEnabled:                 false,
            Keys.lockGracePeriodSeconds:           0,
            Keys.hasPromptedInitialQwenDownload:   false,
            Keys.didShowProAnnouncement:           false
        ])

        let methodRaw = ud.string(forKey: Keys.readingMethod) ?? ReadingMethod.automatic.rawValue
        readingMethod  = ReadingMethod(rawValue: methodRaw) ?? .automatic
        duplicateThreshold = ud.double(forKey: Keys.duplicateThreshold)
        csvIncludesBOM     = ud.bool(forKey: Keys.csvIncludesBOM)
        vCardVersion       = ud.string(forKey: Keys.vCardVersion) ?? "3.0"
        let sortKeyRaw = ud.string(forKey: Keys.sortKey) ?? CardSortKey.createdAt.rawValue
        sortKey        = CardSortKey(rawValue: sortKeyRaw)?.rawValue ?? CardSortKey.createdAt.rawValue
        sortAscending  = ud.bool(forKey: Keys.sortAscending)
        iCloudSyncEnabled                  = ud.bool(forKey: Keys.iCloudSyncEnabled)
        isAppLockEnabled                   = ud.bool(forKey: Keys.isAppLockEnabled)
        lockGracePeriodSeconds             = ud.integer(forKey: Keys.lockGracePeriodSeconds)
        hasPromptedInitialQwenDownload     = ud.bool(forKey: Keys.hasPromptedInitialQwenDownload)
        didShowProAnnouncement             = ud.bool(forKey: Keys.didShowProAnnouncement)
    }

    // MARK: - UserDefaults キー

    private enum Keys {
        static let readingMethod                    = "readingMethod"
        static let duplicateThreshold               = "duplicateThreshold"
        static let csvIncludesBOM                   = "csvIncludesBOM"
        static let vCardVersion                     = "vCardVersion"
        static let sortKey                          = "sortKey"
        static let sortAscending                    = "sortAscending"
        static let iCloudSyncEnabled                = "iCloudSyncEnabled"
        static let isAppLockEnabled                 = "isAppLockEnabled"
        static let lockGracePeriodSeconds           = "lockGracePeriodSeconds"
        static let hasPromptedInitialQwenDownload   = "hasPromptedInitialQwenDownload"
        static let didShowProAnnouncement           = "didShowProAnnouncement"
    }
}
