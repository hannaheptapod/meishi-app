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
