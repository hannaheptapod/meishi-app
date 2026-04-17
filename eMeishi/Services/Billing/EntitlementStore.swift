import StoreKit
import Combine

@MainActor
final class EntitlementStore: ObservableObject {

    static let shared = EntitlementStore()

    @Published private(set) var hasPro = false
    @Published private(set) var isGrandfathered = false

    /// Pro 機能へのアクセス可否（Pro 購入済み OR Grandfather 対象）
    var hasAccess: Bool { hasPro || isGrandfathered }

    private init() {}

    func setup(isGrandfathered: Bool) {
        self.isGrandfathered = isGrandfathered
    }

    func refresh() async {
        var hasActive = false
        for await result in Transaction.currentEntitlements {
            guard case .verified(let transaction) = result else { continue }
            guard ProductIdentifier(rawValue: transaction.productID) != nil else { continue }
            guard transaction.revocationDate == nil else { continue }
            hasActive = true
            break
        }
        hasPro = hasActive
    }
}
