import SwiftUI
import StoreKit
#if canImport(FoundationModels)
import FoundationModels
#endif

struct PaywallView: View {

    let context: PaywallContext

    @EnvironmentObject private var entitlementStore: EntitlementStore
    @Environment(\.dismiss) private var dismiss

    @State private var products: [Product] = []
    @State private var isPurchasing = false
    @State private var isRestoring = false
    @State private var errorMessage: String? = nil
    @State private var selectedProductID: String? = nil
    @State private var loadFailed = false

    private var yearlyProduct: Product? { products.first { $0.id == ProductIdentifier.proYearly.rawValue } }
    private var monthlyProduct: Product? { products.first { $0.id == ProductIdentifier.proMonthly.rawValue } }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    headerSection
                    deviceWarningSection
                    featureSection
                    productSection
                    footerSection
                }
                .padding()
            }
            .navigationTitle("eMeishi Pro")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("閉じる") { dismiss() }
                }
            }
        }
        .task { await loadProducts() }
        .alert("エラー", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    // MARK: - Sections

    private var headerSection: some View {
        VStack(spacing: 8) {
            Image(systemName: "sparkles")
                .font(.system(size: 44))
                .foregroundStyle(.accent)
            Text(context.featureTitle)
                .font(.title2.bold())
            Text(context.featureDescription)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.top, 8)
    }

    @ViewBuilder
    private var deviceWarningSection: some View {
        if !isAIAvailable {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 4) {
                    Text("AIモデルのダウンロードが必要です")
                        .font(.subheadline.bold())
                    Text("Pro 機能をご利用いただくには、AIモデル（約570MB）のダウンロードが必要です。設定 › AIモデル からダウンロードできます。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding()
            .background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
        }
    }

    private var featureSection: some View {
        GroupBox("Pro 機能") {
            PaywallFeatureListView(context: context)
                .padding(.top, 4)
        }
    }

    private var productSection: some View {
        VStack(spacing: 12) {
            if !products.isEmpty {
                if let yearly = yearlyProduct {
                    productButton(yearly, badge: "7日間無料トライアル付き")
                }
                if let monthly = monthlyProduct {
                    productButton(monthly, badge: nil)
                }
            } else if loadFailed {
                VStack(spacing: 8) {
                    Text("商品を読み込めませんでした")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Button("再試行") {
                        Task { await loadProducts() }
                    }
                    .font(.subheadline)
                }
                .frame(maxWidth: .infinity)
                .padding()
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .padding()
            }
        }
    }

    private func productButton(_ product: Product, badge: String?) -> some View {
        Button {
            Task { await purchase(product) }
        } label: {
            VStack(spacing: 4) {
                if let badge {
                    Text(badge)
                        .font(.caption.bold())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 3)
                        .background(.accent, in: Capsule())
                }
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(product.displayName)
                            .font(.headline)
                        Text(product.description)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(product.displayPrice)
                        .font(.title3.bold())
                }
                .padding()
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(selectedProductID == product.id ? .accent : .clear, lineWidth: 2)
                )
            }
        }
        .buttonStyle(.plain)
        .disabled(isPurchasing || isRestoring)
        .opacity((isPurchasing && selectedProductID != product.id) ? 0.5 : 1)
    }

    private var footerSection: some View {
        VStack(spacing: 12) {
            Button {
                Task { await restore() }
            } label: {
                if isRestoring {
                    ProgressView()
                } else {
                    Text("購入を復元")
                        .font(.subheadline)
                }
            }
            .disabled(isPurchasing || isRestoring)

            Text("購入は Apple ID に紐づきます。ファミリー共有対応。サブスクリプションは App Store で管理・解約できます。年額プランは 7 日間の無料トライアル後に自動更新されます。期間終了の 24 時間以上前に解約しない限り同一料金で更新されます。")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)

            HStack(spacing: 16) {
                Link("利用規約", destination: URL(string: "https://hannaheptapod.github.io/meishi-app/terms-of-use.html")!)
                Link("プライバシーポリシー", destination: URL(string: "https://hannaheptapod.github.io/meishi-app/privacy-policy.html")!)
            }
            .font(.caption2)
        }
    }

    // MARK: - Actions

    private func loadProducts() async {
        loadFailed = false
        products = await StoreService.shared.fetchProducts()
            .sorted { $0.price > $1.price }
        if products.isEmpty { loadFailed = true }
    }

    private func purchase(_ product: Product) async {
        isPurchasing = true
        selectedProductID = product.id
        defer {
            isPurchasing = false
            selectedProductID = nil
        }
        do {
            let success = try await StoreService.shared.purchase(product)
            if success { dismiss() }
        } catch {
            errorMessage = "購入に失敗しました。しばらく経ってから再試行してください。"
        }
    }

    private func restore() async {
        isRestoring = true
        defer { isRestoring = false }
        await StoreService.shared.restorePurchases()
        if entitlementStore.hasPro { dismiss() }
    }

    // MARK: - Device Compatibility

    private var isAIAvailable: Bool {
        if LocalLLMService.shared.isModelAvailable { return true }
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            if case .available = SystemLanguageModel.default.availability { return true }
        }
        #endif
        return false
    }
}
