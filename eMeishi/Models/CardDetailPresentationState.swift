import Foundation

/// 名刺詳細から表示する presentation。
/// Core Data オブジェクトは保持せず、対象カードは URI から表示時に再解決する。
nonisolated enum CardDetailPresentationDestination: Equatable, Sendable {
    enum Sheet: Equatable, Sendable {
        case editCard(objectURI: URL)
        case shareExport(url: URL)
    }

    enum FullScreen: Equatable, Sendable {
        case cardImage(objectURI: URL)
    }

    enum Alert: Equatable, Sendable {
        case message(title: String, message: String)
    }

    case sheet(Sheet)
    case fullScreen(FullScreen)
    case alert(Alert)
}

typealias CardDetailPresentationRequest = QueuedPresentationRequest<CardDetailPresentationDestination>
typealias CardDetailPresentationState = QueuedPresentationState<CardDetailPresentationDestination>
