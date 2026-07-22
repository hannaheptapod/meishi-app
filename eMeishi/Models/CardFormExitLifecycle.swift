import Foundation

nonisolated enum CardFormExitAction: Equatable, Sendable {
    case skip
    case close
}

/// 閉じる操作を画面ごとに1件へ限定し、非同期キャンセル完了後の多重dismissを防ぐ。
nonisolated struct CardFormExitLifecycle: Equatable, Sendable {
    private(set) var request: Request?
    private(set) var didComplete = false

    struct Request: Equatable, Sendable {
        let id: UUID
        let action: CardFormExitAction
    }

    var isExiting: Bool { request != nil }
    var isSkipping: Bool { request?.action == .skip }
    var isClosing: Bool { request?.action == .close }

    mutating func begin(_ action: CardFormExitAction) -> Request? {
        guard request == nil else { return nil }
        let request = Request(id: UUID(), action: action)
        self.request = request
        didComplete = false
        return request
    }

    mutating func complete(requestID: UUID) -> CardFormExitAction? {
        guard request?.id == requestID, !didComplete else { return nil }
        didComplete = true
        return request?.action
    }

    mutating func invalidate() {
        request = nil
        didComplete = false
    }
}
