import Foundation
import UniformTypeIdentifiers

/// 共有シート・「このAppで開く」から渡されたファイルURLの判定（Issue #204）。
/// `LSSupportsOpeningDocumentsInPlace = false`のため、iOSは元ファイルをアプリ内（`Documents/Inbox`等）へ
/// コピーしてからURLを渡す。コピーは個人情報を含むため、読み込み後に削除する。
nonisolated enum IncomingVCardFile {
    /// Info.plistの`CFBundleDocumentTypes`で受け付けたvCardかどうか。
    static func isVCard(_ url: URL) -> Bool {
        guard url.isFileURL,
              let type = UTType(filenameExtension: url.pathExtension.lowercased()) else { return false }
        return type.conforms(to: .vCard)
    }

    /// iOSがアプリのコンテナ内に置いたコピーかどうか。アプリ外にある元ファイルは消さない。
    static func isCopyInsideApp(
        _ url: URL,
        homeDirectory: URL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
    ) -> Bool {
        guard url.isFileURL else { return false }
        let home = homeDirectory.standardizedFileURL.resolvingSymlinksInPath().path
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path
        let homePrefix = home.hasSuffix("/") ? home : home + "/"
        return path.hasPrefix(homePrefix)
    }
}
