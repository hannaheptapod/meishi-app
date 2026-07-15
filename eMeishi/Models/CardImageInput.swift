import Foundation

/// カメラ撮影と写真ライブラリ取込みで共通利用する画像入力。
/// UIKit 型を境界外へ出さず、Swift 6 の並行処理でも安全に受け渡せるよう Data で保持する。
nonisolated struct CardImageInput: Identifiable, Sendable {
    enum Source: String, Codable, Sendable {
        case camera
        case photoLibrary
    }

    let id: UUID
    let data: Data
    let source: Source

    init(id: UUID = UUID(), data: Data, source: Source) {
        self.id = id
        self.data = data
        self.source = source
    }
}
