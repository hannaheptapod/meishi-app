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
    @State private var alertTitle = "エラー"
    @State private var selectedProductID: String = ProductIdentifier.proYearly.rawValue
    @State private var loadFailed = false

    private var yearlyProduct: Product? { products.first { $0.id == ProductIdentifier.proYearly.rawValue } }
    private var monthlyProduct: Product? { products.first { $0.id == ProductIdentifier.proMonthly.rawValue } }
    private var selectedProduct: Product? { products.first { $0.id == selectedProductID } }

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
            .background(AppTheme.background.ignoresSafeArea())
            .navigationTitle("eMeishi Pro")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("閉じる") { dismiss() }
                }
            }
            .safeAreaInset(edge: .bottom) {
                purchaseBar
            }
        }
        .task { await loadProducts() }
        .alert(alertTitle, isPresented: Binding(
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
                    .foregroundStyle(.yellow)
                VStack(alignment: .leading, spacing: 4) {
                    Text("AIモデルのダウンロードが必要です")
                        .font(.subheadline.bold())
                    Text("Pro 機能をご利用いただくには、AIモデル（約570MB）のダウンロードが必要です。設定 › AIモデル からダウンロードできます。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding()
            .background(.yellow.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
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
                    productButton(yearly, badge: "7日間無料")
                }
                if let monthly = monthlyProduct {
                    productButton(monthly, badge: nil)
                }
            } else if ScreenshotMode.isActive {
                // UI テストでは StoreKit Configuration が app.launch 先に届かないため、
                // App Store 提出用スクリーンショットでは表示用のモック商品ボタンを描画する
                mockProductButton(
                    id: ProductIdentifier.proYearly.rawValue,
                    title: "eMeishi Pro 年額",
                    description: "AI 自然言語検索など Pro 機能が使えます。7日間の無料トライアル付き。",
                    price: "¥3,200",
                    badge: "7日間無料"
                )
                mockProductButton(
                    id: ProductIdentifier.proMonthly.rawValue,
                    title: "eMeishi Pro 月額",
                    description: "AI 自然言語検索など Pro 機能が使えます。",
                    price: "¥500",
                    badge: nil
                )
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

    private func mockProductButton(id: String, title: String, description: String, price: String, badge: String?) -> some View {
        Button {
            selectedProductID = id
        } label: {
        VStack(alignment: .leading, spacing: 8) {
            if let badge {
                Text(badge)
                    .font(.caption.bold())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 3)
                    .background(AppTheme.brandOrange, in: Capsule())
            }
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.headline)
                    Text(description).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Text(price).font(.title3.bold())
                Image(systemName: selectedProductID == id ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selectedProductID == id ? AppTheme.brandOrange : .secondary)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, minHeight: 132, alignment: .leading)
        .background(
            selectedProductID == id ? AppTheme.brandOrange.opacity(0.08) : AppTheme.contentSurface,
            in: .rect(cornerRadius: AppTheme.contentCornerRadius, style: .continuous)
        )
        }
        .buttonStyle(.plain)
    }

    private func productButton(_ product: Product, badge: String?) -> some View {
        Button {
            selectedProductID = product.id
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                if let badge {
                    Text(badge)
                        .font(.caption.bold())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 3)
                        .background(AppTheme.brandOrange, in: Capsule())
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
                    Image(systemName: selectedProductID == product.id ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(selectedProductID == product.id ? AppTheme.brandOrange : .secondary)
                }
            }
            .padding()
            .frame(maxWidth: .infinity, minHeight: 132, alignment: .leading)
            .background(
                selectedProductID == product.id ? AppTheme.brandOrange.opacity(0.08) : AppTheme.contentSurface,
                in: .rect(cornerRadius: AppTheme.contentCornerRadius, style: .continuous)
            )
        }
        .buttonStyle(.plain)
        .disabled(isPurchasing || isRestoring)
    }

    private var purchaseBar: some View {
        VStack(spacing: 6) {
            Button {
                guard let selectedProduct else { return }
                Task { await purchase(selectedProduct) }
            } label: {
                HStack {
                    if isPurchasing {
                        ProgressView().tint(.white)
                    }
                    Text(selectedProductID == ProductIdentifier.proYearly.rawValue
                         ? "7日間無料で試す"
                         : "月額プランを開始")
                        .fontWeight(.semibold)
                }
                .frame(maxWidth: .infinity)
                .frame(minHeight: 48)
            }
            .buttonStyle(.borderedProminent)
            .tint(AppTheme.brandOrange)
            .disabled((selectedProduct == nil && !ScreenshotMode.isActive) || isPurchasing || isRestoring)
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .background(.bar)
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
                Link("利用規約（Apple 標準 EULA）", destination: URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")!)
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
        if products.contains(where: { $0.id == ProductIdentifier.proYearly.rawValue }) {
            selectedProductID = ProductIdentifier.proYearly.rawValue
        } else if let first = products.first {
            selectedProductID = first.id
        }
        if products.isEmpty { loadFailed = true }
    }

    private func purchase(_ product: Product) async {
        isPurchasing = true
        defer {
            isPurchasing = false
        }
        do {
            let success = try await StoreService.shared.purchase(product)
            if success { dismiss() }
        } catch {
            alertTitle = "購入エラー"
            errorMessage = "購入に失敗しました。しばらく経ってから再試行してください。"
        }
    }

    private func restore() async {
        isRestoring = true
        defer { isRestoring = false }
        do {
            switch try await StoreService.shared.restorePurchases() {
            case .restored:
                dismiss()
            case .nothingToRestore:
                alertTitle = "購入の復元"
                errorMessage = "復元できる購入が見つかりませんでした。購入時と同じApple Accountでサインインしているか確認してください。"
            }
        } catch {
            alertTitle = "復元エラー"
            errorMessage = "購入情報を復元できませんでした。通信状態を確認して、もう一度お試しください。"
        }
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
