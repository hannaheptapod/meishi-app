import Foundation

/// 名刺一覧が表示できるモーダルを、表示方式ごとに型で制約する。
/// Core Data オブジェクトは保持せず、必要な時点で URI から再解決する。
nonisolated enum CardListPresentationDestination: Equatable, Sendable {
    enum Sheet: Equatable, Sendable {
        case tagManager
        case editCard(objectURI: URL)
        case bulkTag(cardURIs: Set<URL>)
        case paywall
        case mockOCRForm
        case shareExport(url: URL)
    }

    enum Confirmation: Equatable, Sendable {
        case importContacts
        case deleteCard(objectURI: URL)
        case bulkDelete(cardURIs: Set<URL>)
    }

    enum Alert: Equatable, Sendable {
        case error(message: String)
        case importResult(message: String)
    }

    case sheet(Sheet)
    case confirmation(Confirmation)
    case alert(Alert)
}

typealias CardListPresentationRequest = QueuedPresentationRequest<CardListPresentationDestination>
typealias CardListPresentationState = QueuedPresentationState<CardListPresentationDestination>
