import Foundation

/// 検証済みモデル一式を現行配置へ原子的に切り替える。
/// 置換に失敗した場合は、退避した現行モデルを必ず元の位置へ戻す。
actor ModelInstallService {
    static let shared = ModelInstallService()

    enum InstallError: LocalizedError {
        case stagingMissing
        case replacementFailed

        var errorDescription: String? {
            switch self {
            case .stagingMissing: "検証済みモデルの一時配置が見つかりません"
            case .replacementFailed: "モデルの切替に失敗したため、従来モデルへ戻しました"
            }
        }
    }

    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func install(stagingDirectory: URL, at targetDirectory: URL) throws {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: stagingDirectory.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw InstallError.stagingMissing
        }

        let parent = targetDirectory.deletingLastPathComponent()
        try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
        let backup = parent.appendingPathComponent(
            ".\(targetDirectory.lastPathComponent).backup",
            isDirectory: true
        )

        // 前回中断でtargetが消えbackupだけ残った場合は、先に現行モデルを復旧する。
        if !fileManager.fileExists(atPath: targetDirectory.path),
           fileManager.fileExists(atPath: backup.path) {
            try fileManager.moveItem(at: backup, to: targetDirectory)
        }

        do {
            if fileManager.fileExists(atPath: targetDirectory.path) {
                if fileManager.fileExists(atPath: backup.path) {
                    try fileManager.removeItem(at: backup)
                }
                _ = try fileManager.replaceItemAt(
                    targetDirectory,
                    withItemAt: stagingDirectory,
                    backupItemName: backup.lastPathComponent,
                    options: []
                )
            } else {
                try fileManager.moveItem(at: stagingDirectory, to: targetDirectory)
            }

            guard fileManager.fileExists(atPath: targetDirectory.path) else {
                throw InstallError.replacementFailed
            }
            try? fileManager.removeItem(at: backup)
        } catch {
            if !fileManager.fileExists(atPath: targetDirectory.path),
               fileManager.fileExists(atPath: backup.path) {
                try? fileManager.moveItem(at: backup, to: targetDirectory)
            }
            throw InstallError.replacementFailed
        }
    }
}
