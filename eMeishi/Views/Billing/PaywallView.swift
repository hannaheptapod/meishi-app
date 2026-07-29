import SwiftUI
import StoreKit
#if canImport(FoundationModels)
import FoundationModels
#endif

nonisolated enum PaywallAlertDestination: String, Identifiable, Equatable, Sendable {
    case purchaseFailure
    case nothingToRestore
    case restoreFailure

    var id: String { rawValue }

    var title: String {
        switch self {
        case .purchaseFailure: return "購入エラー"
        case .nothingToRestore: return "購入の復元"
        case .restoreFailure: return "復元エラー"
        }
    }

    var message: String {
        switch self {
        case .purchaseFailure:
            return "購入に失敗しました。しばらく経ってから再試行してください。"
        case .nothingToRestore:
            return "復元できる購入が見つかりませんでした。購入時と同じApple Accountでサインインしているか確認してください。"
        case .restoreFailure:
            return "購入情報を復元できませんでした。通信状態を確認して、もう一度お試しください。"
        }
    }
}

nonisolated private enum PaywallPurchaseOutcome: Sendable {
    case purchased
    case notCompleted
    case failed
}

nonisolated private enum PaywallRestoreOutcome: Sendable {
    case restored
    case nothingToRestore
    case failed
}

struct PaywallView: View {

    let context: PaywallContext

    @EnvironmentObject private var entitlementStore: EntitlementStore
    @Environment(\.dismiss) private var dismiss

    @State private var products: [Product] = []
    @State private var isLoadingProducts = false
    @State private var isPurchasing = false
    @State private var isRestoring = false
    @State private var alertDestination: PaywallAlertDestination?
    @State private var selectedProductID: String = ProductIdentifier.proYearly.rawValue
    @State private var loadFailed = false
    @State private var productLoadTask: Task<Void, Never>?
    @State private var productLoadTaskGate = SecondaryViewTaskGate()
    @State private var purchaseTask: Task<Void, Never>?
    @State private var purchaseTaskGate = SecondaryViewTaskGate()
    @State private var restoreTask: Task<Void, Never>?
    @State private var restoreTaskGate = SecondaryViewTaskGate()

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
                        .disabled(isPurchasing || isRestoring)
                }
            }
            .safeAreaInset(edge: .bottom) {
                purchaseBar
            }
        }
        .interactiveDismissDisabled(isPurchasing || isRestoring)
        .onAppear(perform: startProductLoad)
        .onDisappear(perform: cancelViewOwnedTasks)
        .alert(item: $alertDestination) { destination in
            Alert(
                title: Text(destination.title),
                message: Text(destination.message),
                dismissButton: .cancel(Text("OK"))
            )
        }
    }

    // MARK: - Sections

    private var headerSection: some View {
        VStack(spacing: 8) {
            Image(systemName: "sparkles")
                .font(.system(size: 44))
                .foregroundStyle(Color.accentColor)
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
                        startProductLoad()
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
        planOption(
            id: id,
            title: title,
            description: description,
            price: price,
            badge: badge,
            disabled: false
        )
    }

    private func productButton(_ product: Product, badge: String?) -> some View {
        planOption(
            id: product.id,
            title: product.displayName,
            description: product.description,
            price: product.displayPrice,
            badge: badge,
            disabled: isPurchasing || isRestoring
        )
    }

    private func planOption(
        id: String,
        title: String,
        description: String,
        price: String,
        badge: String?,
        disabled: Bool
    ) -> some View {
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
                        Text(title)
                            .font(.headline)
                        Text(description)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(price)
                        .font(.title3.bold())
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
        .disabled(disabled)
        .accessibilityAddTraits(selectedProductID == id ? .isSelected : [])
    }

    private var purchaseBar: some View {
        VStack(spacing: 6) {
            Button {
                guard let selectedProduct else { return }
                startPurchase(selectedProduct)
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
                startRestore()
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
                if let termsURL = URL(
                    string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/"
                ) {
                    Link("利用規約（Apple 標準 EULA）", destination: termsURL)
                }
                if let privacyURL = URL(
                    string: "https://hannaheptapod.github.io/meishi-app/privacy-policy.html"
                ) {
                    Link("プライバシーポリシー", destination: privacyURL)
                }
            }
            .font(.caption2)
        }
    }

    // MARK: - Actions

    private func startProductLoad() {
        guard let operationID = productLoadTaskGate.begin() else { return }
        isLoadingProducts = true
        loadFailed = false

        // 商品取得はStoreServiceのキャッシュを温める処理でもあるため継続させ、
        // 画面側の待受だけをonDisappearで破棄する。
        let serviceTask = Task { @MainActor in
            await StoreService.shared.fetchProducts()
                .sorted { $0.price > $1.price }
        }
        productLoadTask = Task { @MainActor in
            let loadedProducts = await serviceTask.value
            guard !Task.isCancelled,
                  productLoadTaskGate.finish(operationID) else { return }
            productLoadTask = nil
            isLoadingProducts = false
            products = loadedProducts
            if loadedProducts.contains(where: { $0.id == ProductIdentifier.proYearly.rawValue }) {
                selectedProductID = ProductIdentifier.proYearly.rawValue
            } else if let first = loadedProducts.first {
                selectedProductID = first.id
            }
            loadFailed = loadedProducts.isEmpty
        }
    }

    private func startPurchase(_ product: Product) {
        guard !isRestoring,
              let operationID = purchaseTaskGate.begin() else { return }
        isPurchasing = true

        // StoreKitの購入確認は画面遷移を理由に中断せず、トランザクションを完結させる。
        let serviceTask = Task { @MainActor () -> PaywallPurchaseOutcome in
            do {
                return try await StoreService.shared.purchase(product) ? .purchased : .notCompleted
            } catch {
                return .failed
            }
        }
        purchaseTask = Task { @MainActor in
            let outcome = await serviceTask.value
            guard !Task.isCancelled,
                  purchaseTaskGate.finish(operationID) else { return }
            purchaseTask = nil
            isPurchasing = false
            switch outcome {
            case .purchased:
                dismiss()
            case .notCompleted:
                break
            case .failed:
                alertDestination = .purchaseFailure
            }
        }
    }

    private func startRestore() {
        guard !isPurchasing,
              let operationID = restoreTaskGate.begin() else { return }
        isRestoring = true

        let serviceTask = Task { @MainActor () -> PaywallRestoreOutcome in
            do {
                switch try await StoreService.shared.restorePurchases() {
                case .restored:
                    return .restored
                case .nothingToRestore:
                    return .nothingToRestore
                }
            } catch {
                return .failed
            }
        }
        restoreTask = Task { @MainActor in
            let outcome = await serviceTask.value
            guard !Task.isCancelled,
                  restoreTaskGate.finish(operationID) else { return }
            restoreTask = nil
            isRestoring = false
            switch outcome {
            case .restored:
                dismiss()
            case .nothingToRestore:
                alertDestination = .nothingToRestore
            case .failed:
                alertDestination = .restoreFailure
            }
        }
    }

    private func cancelViewOwnedTasks() {
        productLoadTaskGate.cancel()
        productLoadTask?.cancel()
        productLoadTask = nil
        isLoadingProducts = false

        purchaseTaskGate.cancel()
        purchaseTask?.cancel()
        purchaseTask = nil
        isPurchasing = false

        restoreTaskGate.cancel()
        restoreTask?.cancel()
        restoreTask = nil
        isRestoring = false
        alertDestination = nil
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
