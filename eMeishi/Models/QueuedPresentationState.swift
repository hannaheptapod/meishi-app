import Foundation

/// 種類の異なる SwiftUI presentation を FIFO で直列化する request。
///
/// `Destination` は値型に限定し、Core Data オブジェクトのような
/// View ライフサイクルを越えて保持すべきでない参照を載せない。
nonisolated struct QueuedPresentationRequest<Destination>: Identifiable, Equatable, Sendable
where Destination: Equatable & Sendable {
    let id: UUID
    let destination: Destination

    init(id: UUID = UUID(), destination: Destination) {
        self.id = id
        self.destination = destination
    }
}

/// sheet / fullScreenCover / alert などを同時に表示しないための状態機械。
///
/// dismissal は開始と完了を分離する。完了側にも request ID を要求するため、
/// 古い presentation の遅延 callback が、新しい presentation を進めることはない。
nonisolated struct QueuedPresentationState<Destination>: Equatable, Sendable
where Destination: Equatable & Sendable {
    typealias Request = QueuedPresentationRequest<Destination>

    private(set) var active: Request?
    private(set) var queued: [Request] = []
    private(set) var dismissing: Request?

    var isDismissing: Bool { dismissing != nil }

    @discardableResult
    mutating func request(_ destination: Destination, id: UUID = UUID()) -> Bool {
        guard active?.destination != destination,
              dismissing?.destination != destination,
              !queued.contains(where: { $0.destination == destination }) else {
            return false
        }

        let request = Request(id: id, destination: destination)
        guard active == nil, dismissing == nil else {
            queued.append(request)
            return true
        }

        active = request
        return true
    }

    /// request ID が現在の表示と一致する場合だけ dismissal を開始する。
    @discardableResult
    mutating func clearActive(requestID: UUID) -> Bool {
        guard let active, active.id == requestID else { return false }
        self.active = nil
        dismissing = active
        return true
    }

    /// 対応する dismissal が完了した場合だけ、待機中の先頭を表示する。
    @discardableResult
    mutating func presentNext(afterDismissing requestID: UUID) -> Bool {
        guard active == nil, dismissing?.id == requestID else { return false }
        dismissing = nil
        guard !queued.isEmpty else { return false }
        active = queued.removeFirst()
        return true
    }

    mutating func removeAll() {
        active = nil
        queued.removeAll()
        dismissing = nil
    }
}

/// 確認ダイアログのボタン操作で決まった副作用を、対応するUIKit dismissal完了まで保持する。
/// request IDを照合するため、古いdismiss callbackが新しい操作を実行することはない。
nonisolated struct DismissalCommitState<Action>: Equatable, Sendable
where Action: Equatable & Sendable {
    private(set) var requestID: UUID?
    private(set) var action: Action?

    var hasPendingCommit: Bool { requestID != nil }

    @discardableResult
    mutating func schedule(_ action: Action, for requestID: UUID) -> Bool {
        guard self.requestID == nil else { return false }
        self.requestID = requestID
        self.action = action
        return true
    }

    /// 対応する presentation のdismiss完了時にだけ副作用を取り出す。
    mutating func take(afterDismissing requestID: UUID) -> Action? {
        guard self.requestID == requestID else { return nil }
        let result = action
        self.requestID = nil
        action = nil
        return result
    }

    mutating func removeAll() {
        requestID = nil
        action = nil
    }
}
