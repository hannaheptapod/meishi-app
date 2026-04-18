import Foundation
import StoreKit

// AppTransaction の取得を抽象化する Protocol。
// 本番は StoreKit.AppTransaction.shared をそのまま返し、
// テストでは任意の originalAppVersion を返すモックに差し替える。
protocol AppTransactionProviding: Sendable {
    /// 初回購入／インストール時のアプリマーケティングバージョン。
    /// 取得失敗・未検証（TestFlight 初回 offline 等）は nil。
    func originalAppVersion() async -> String?
}

struct LiveAppTransactionProvider: AppTransactionProviding {
    func originalAppVersion() async -> String? {
        do {
            let result = try await AppTransaction.shared
            switch result {
            case .verified(let tx):
                return tx.originalAppVersion
            case .unverified:
                return nil
            }
        } catch {
            return nil
        }
    }
}

// MARK: - iCloud Key-Value Store 抽象化
// シミュレータ上のテストでは NSUbiquitousKeyValueStore に書き込めないため、
// Grandfather 判定の iCloud 経路を検証できるよう Protocol を切る。

protocol UbiquitousKeyValueStoring {
    func getString(forKey key: String) -> String?
    func setString(_ value: String, forKey key: String)
}

struct LiveUbiquitousKeyValueStore: UbiquitousKeyValueStoring {
    func getString(forKey key: String) -> String? {
        NSUbiquitousKeyValueStore.default.string(forKey: key)
    }
    func setString(_ value: String, forKey key: String) {
        NSUbiquitousKeyValueStore.default.set(value, forKey: key)
        NSUbiquitousKeyValueStore.default.synchronize()
    }
}
