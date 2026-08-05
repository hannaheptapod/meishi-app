import SwiftUI
import StoreKit

struct ManageSubscriptionButton: View {
    @State private var isShowingSubscriptionManagement = false

    var body: some View {
        Button("サブスクリプションを管理") {
            isShowingSubscriptionManagement = true
        }
        .manageSubscriptionsSheet(isPresented: $isShowingSubscriptionManagement)
    }
}
