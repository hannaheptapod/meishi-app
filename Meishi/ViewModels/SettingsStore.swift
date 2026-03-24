import Foundation
import Combine

// アプリ設定の永続化管理（UserDefaults）
class SettingsStore: ObservableObject {

    static let shared = SettingsStore()

    // MARK: - 重複チェック設定

    /// 重複検出の閾値（0.5〜1.0、デフォルト 0.75）
    @Published var duplicateThreshold: Double {
        didSet { UserDefaults.standard.set(duplicateThreshold, forKey: Keys.duplicateThreshold) }
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

    // MARK: - 初期化

    private init() {
        let ud = UserDefaults.standard

        // 初回起動時のデフォルト値を登録
        ud.register(defaults: [
            Keys.duplicateThreshold: 0.75,
            Keys.csvIncludesBOM: true,
            Keys.vCardVersion: "3.0"
        ])

        duplicateThreshold = ud.double(forKey: Keys.duplicateThreshold)
        csvIncludesBOM     = ud.bool(forKey: Keys.csvIncludesBOM)
        vCardVersion       = ud.string(forKey: Keys.vCardVersion) ?? "3.0"
    }

    // MARK: - UserDefaults キー

    private enum Keys {
        static let duplicateThreshold = "duplicateThreshold"
        static let csvIncludesBOM     = "csvIncludesBOM"
        static let vCardVersion       = "vCardVersion"
    }
}
