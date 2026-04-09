import Foundation
import CloudKit

/// CloudKit Public Database からオンデバイスLLMモデルファイルをダウンロードするサービス。
/// Anemll 変換済み Qwen3-0.6B-ctx512（3モデル分割方式）に対応。
///
/// CloudKit レコード構成（MLModelPackage）:
///   - embedMetadataAsset:     Embed モデルの metadata.json
///   - embedCoremlDataAsset:   Embed モデルの coremldata.bin
///   - embedModelMilAsset:     Embed モデルの model.mil
///   - ffnMetadataAsset:       FFN モデルの metadata.json
///   - ffnCoremlDataAsset:     FFN モデルの coremldata.bin
///   - ffnModelMilAsset:       FFN モデルの model.mil
///   - lmheadMetadataAsset:    LM Head モデルの metadata.json
///   - lmheadCoremlDataAsset:  LM Head モデルの coremldata.bin
///   - lmheadModelMilAsset:    LM Head モデルの model.mil
///   - weightChunk0〜N:        共有 weight.bin のチャンク
///   - weightChunkCount:       チャンク数
///   - tokenizerAsset:         tokenizer.json
class CloudKitModelService {

    static let shared = CloudKitModelService()

    private let database = CKContainer(identifier: "iCloud.com.jinks.emeishi").publicCloudDatabase
    private let recordType = "MLModelPackage"

    // MARK: - モデルファイル名

    private let embedModelDirName  = "qwen_embeddings.mlmodelc"
    private let ffnModelDirName    = "qwen_FFN_PF_lut6.mlmodelc"
    private let lmheadModelDirName = "qwen_lm_head_lut6.mlmodelc"

    // MARK: - アセットフィールド定義

    /// Embed モデルの小ファイル: フィールド名 → mlmodelc 内の相対パス
    private let embedAssetFields: [(field: String, relativePath: String)] = [
        ("embedMetadataAsset",   "metadata.json"),
        ("embedCoremlDataAsset", "coremldata.bin"),
        ("embedModelMilAsset",   "model.mil"),
    ]

    /// FFN モデルの小ファイル: フィールド名 → mlmodelc 内の相対パス
    private let ffnAssetFields: [(field: String, relativePath: String)] = [
        ("ffnMetadataAsset",   "metadata.json"),
        ("ffnCoremlDataAsset", "coremldata.bin"),
        ("ffnModelMilAsset",   "model.mil"),
    ]

    /// LM Head モデルの小ファイル: フィールド名 → mlmodelc 内の相対パス
    private let lmheadAssetFields: [(field: String, relativePath: String)] = [
        ("lmheadMetadataAsset",   "metadata.json"),
        ("lmheadCoremlDataAsset", "coremldata.bin"),
        ("lmheadModelMilAsset",   "model.mil"),
    ]

    /// トークナイザーのフィールド名
    private let tokenizerField = "tokenizerAsset"

    /// weight チャンクのフィールドプレフィックス
    private let weightChunkPrefix = "weightChunk"

    // MARK: - エラー型

    enum CloudKitModelError: LocalizedError {
        case noRecordFound
        case missingAsset(String)
        case missingChunkCount
        case chunkConcatenationFailed

        var errorDescription: String? {
            switch self {
            case .noRecordFound:
                return "CloudKit にモデルレコードが見つかりません"
            case .missingAsset(let field):
                return "アセットが見つかりません: \(field)"
            case .missingChunkCount:
                return "weightChunkCount が設定されていません"
            case .chunkConcatenationFailed:
                return "weight チャンクの結合に失敗しました"
            }
        }
    }

    private init() {}

    // MARK: - レコード取得

    /// MLModelPackage レコードの固定 Record ID（CloudKit Dashboard で作成済み）
    private let modelRecordID = CKRecord.ID(recordName: "65526C03-31FB-4EE0-A61D-7C2C91C1C424")

    /// CKFetchRecordsOperation を使ってレコードをダウンロードする（リアルタイム進捗対応）
    private func fetchRecordWithProgress(progress: @escaping (Double) -> Void) async throws -> CKRecord {
        try await withCheckedThrowingContinuation { continuation in
            let operation = CKFetchRecordsOperation(recordIDs: [modelRecordID])
            operation.qualityOfService = .userInitiated

            operation.perRecordProgressBlock = { _, p in
                progress(p)
            }

            operation.perRecordResultBlock = { _, result in
                switch result {
                case .success(let record):
                    continuation.resume(returning: record)
                case .failure(let error):
                    if let ckError = error as? CKError, ckError.code == .unknownItem {
                        continuation.resume(throwing: CloudKitModelError.noRecordFound)
                    } else {
                        continuation.resume(throwing: error)
                    }
                }
            }

            database.add(operation)
        }
    }

    // MARK: - モデルダウンロード

    /// CloudKit からモデルファイルをダウンロードし、指定ディレクトリに保存する。
    /// Embed / FFN / LM Head の3モデル小ファイル + 共有 weight チャンク + tokenizer を取得。
    /// weight.bin はすべてのモデルの weights/ にコピーする（Anemll 共有ウェイト構成）。
    /// - Parameters:
    ///   - modelDir: モデルファイルの保存先ディレクトリ（例: .../LocalLLM/）
    ///   - tokenizerDestination: tokenizer.json の保存先
    ///   - progress: 進捗コールバック（0.0〜1.0）
    func downloadModel(modelDir: URL,
                       tokenizerDestination: URL,
                       progress: @escaping (Double) -> Void) async throws {
        let record = try await fetchRecordWithProgress(progress: progress)

        let fm = FileManager.default

        // --- 各モデルの小ファイル保存 ---
        let modelDirs: [(dirName: String, fields: [(field: String, relativePath: String)])] = [
            (embedModelDirName,  embedAssetFields),
            (ffnModelDirName,    ffnAssetFields),
            (lmheadModelDirName, lmheadAssetFields),
        ]

        for (dirName, fields) in modelDirs {
            let modelSubDir = modelDir.appendingPathComponent(dirName, isDirectory: true)
            for (field, relativePath) in fields {
                guard let asset = record[field] as? CKAsset,
                      let sourceURL = asset.fileURL else {
                    throw CloudKitModelError.missingAsset(field)
                }
                let destURL   = modelSubDir.appendingPathComponent(relativePath)
                let parentDir = destURL.deletingLastPathComponent()
                try fm.createDirectory(at: parentDir, withIntermediateDirectories: true)
                try? fm.removeItem(at: destURL)
                try fm.copyItem(at: sourceURL, to: destURL)
            }
        }

        // --- tokenizer.json の保存 ---
        guard let tokenizerAsset = record[tokenizerField] as? CKAsset,
              let tokenizerSourceURL = tokenizerAsset.fileURL else {
            throw CloudKitModelError.missingAsset(tokenizerField)
        }
        let tokenizerDir = tokenizerDestination.deletingLastPathComponent()
        try fm.createDirectory(at: tokenizerDir, withIntermediateDirectories: true)
        try? fm.removeItem(at: tokenizerDestination)
        try fm.copyItem(at: tokenizerSourceURL, to: tokenizerDestination)

        // --- weight チャンクの結合 ---
        guard let chunkCount = record["weightChunkCount"] as? Int64, chunkCount > 0 else {
            throw CloudKitModelError.missingChunkCount
        }

        // weight.bin を一時ファイルに結合
        let tempWeightURL = modelDir.appendingPathComponent("weight_temp.bin")
        try? fm.removeItem(at: tempWeightURL)
        fm.createFile(atPath: tempWeightURL.path, contents: nil)
        guard let outputHandle = try? FileHandle(forWritingTo: tempWeightURL) else {
            throw CloudKitModelError.chunkConcatenationFailed
        }

        for i in 0..<Int(chunkCount) {
            let chunkField = "\(weightChunkPrefix)\(i)"
            guard let chunkAsset = record[chunkField] as? CKAsset,
                  let chunkURL = chunkAsset.fileURL else {
                throw CloudKitModelError.missingAsset(chunkField)
            }
            let chunkData = try Data(contentsOf: chunkURL)
            outputHandle.write(chunkData)
        }
        try outputHandle.close()

        // 各モデルの weights/weight.bin に配置
        for dirName in [embedModelDirName, ffnModelDirName, lmheadModelDirName] {
            let weightsDir  = modelDir.appendingPathComponent(dirName, isDirectory: true)
                                      .appendingPathComponent("weights", isDirectory: true)
            try fm.createDirectory(at: weightsDir, withIntermediateDirectories: true)
            let weightDest  = weightsDir.appendingPathComponent("weight.bin")
            try? fm.removeItem(at: weightDest)
            try fm.copyItem(at: tempWeightURL, to: weightDest)
        }

        // 一時ファイル削除
        try? fm.removeItem(at: tempWeightURL)

        progress(1.0)
    }
}
