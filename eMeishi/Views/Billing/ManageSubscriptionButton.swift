import SwiftUI
import StoreKit

struct ManageSubscriptionButton: View {
    var body: some View {
        Button("サブスクリプションを管理") {
            Task {
                guard let scene = UIApplication.shared.connectedScenes
                    .first(where: { $0.activationState == .foregroundActive }) as? UIWindowScene
                else { return }
                try? await AppStore.showManageSubscriptions(in: scene)
            }
        }
    }
}
