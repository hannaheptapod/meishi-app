import StoreKit

@MainActor
final class StoreService {

    enum PurchaseRestoreResult: Sendable {
        case restored
        case nothingToRestore
    }

    static let shared = StoreService()

    private var transactionListener: Task<Void, Error>?
    private var cachedProducts: [Product] = []

    private init() {}

    // MARK: - 起動時

    func startTransactionListener() {
        transactionListener = Task {
            for await result in Transaction.updates {
                guard case .verified(let transaction) = result else { continue }
                await transaction.finish()
                await EntitlementStore.shared.refresh()
            }
        }
    }

    func prefetch() async {
        guard cachedProducts.isEmpty else { return }
        cachedProducts = await loadFromStore()
    }

    // MARK: - 商品取得

    func fetchProducts() async -> [Product] {
        if !cachedProducts.isEmpty { return cachedProducts }
        cachedProducts = await loadFromStore()
        return cachedProducts
    }

    private func loadFromStore() async -> [Product] {
        let ids = Set(ProductIdentifier.allCases.map(\.rawValue))
        return (try? await Product.products(for: ids)) ?? []
    }

    // MARK: - 購入

    /// - Returns: 購入完了なら true、キャンセル・保留なら false
    @discardableResult
    func purchase(_ product: Product) async throws -> Bool {
        let result = try await product.purchase()
        switch result {
        case .success(let verification):
            guard case .verified(let transaction) = verification else { return false }
            await transaction.finish()
            await EntitlementStore.shared.refresh()
            return true
        case .pending, .userCancelled:
            return false
        @unknown default:
            return false
        }
    }

    // MARK: - 復元

    func restorePurchases() async throws -> PurchaseRestoreResult {
        try await AppStore.sync()
        await EntitlementStore.shared.refresh()
        return EntitlementStore.shared.hasPro ? .restored : .nothingToRestore
    }
}
