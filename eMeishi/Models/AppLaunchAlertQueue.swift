import Combine
import Foundation

/// 起動直後にルートで案内する内容。
nonisolated enum AppLaunchAlert: String, Identifiable, Sendable {
    case grandfatheredAnnouncement
    case qwenDownloadPrompt

    var id: String { rawValue }
}

/// 起動案内を発生順に保持する純粋なFIFO。
/// 実際の表示・dismissは`CardAdditionFlowState`だけが所有する。
nonisolated struct AppLaunchAlertQueue: Equatable, Sendable {
    private(set) var pending: [AppLaunchAlert] = []

    mutating func enqueue(_ alert: AppLaunchAlert) {
        guard !pending.contains(alert) else { return }
        pending.append(alert)
    }

    mutating func dequeue() -> AppLaunchAlert? {
        guard !pending.isEmpty else { return nil }
        return pending.removeFirst()
    }
}

/// App起動処理とSwiftUIのルートpresentation ownerをつなぐ要求キュー。
/// `eMeishiApp`は要求を積むだけで、alert自体は表示しない。
@MainActor
final class AppRootPresentationRequests: ObservableObject {
    @Published private(set) var queue = AppLaunchAlertQueue()
    /// 設定sheetの提示要求。実際の表示・dismissはCardAdditionFlowStateだけが所有する
    @Published private(set) var isSettingsSheetPending = false

    func enqueue(_ alert: AppLaunchAlert) {
        var updatedQueue = queue
        updatedQueue.enqueue(alert)
        guard updatedQueue != queue else { return }
        queue = updatedQueue
    }

    func consumeNextLaunchAlert() -> AppLaunchAlert? {
        var updatedQueue = queue
        guard let alert = updatedQueue.dequeue() else { return nil }
        queue = updatedQueue
        return alert
    }

    func requestSettingsSheet() {
        guard !isSettingsSheetPending else { return }
        isSettingsSheetPending = true
    }

    func consumeSettingsSheetRequest() -> Bool {
        guard isSettingsSheetPending else { return false }
        isSettingsSheetPending = false
        return true
    }
}
