import Foundation
import CloudKit

/// CloudKit Public Database からオンデバイスLLMモデルファイルをダウンロードするサービス。
/// Anemll 変換済み Qwen3-0.6B-ctx512（3モデル分割方式）に対応。
///
/// CloudKit レコード構成（MLModelPackage）:
///   - embedMetadataAsset:     Embed モデルの metadata.json
///   - embedCoremlDataAsset:   Embed モデルの coremldata.bin
///   - embedModelMilAsset:     Embed モデルの model.mil
///   - embedWeightChunk0〜N:   Embed の weight.bin チャンク（各 ≤200MB）
///   - embedWeightChunkCount:  Embed チャンク数
///   - ffnMetadataAsset:       FFN モデルの metadata.json
///   - ffnCoremlDataAsset:     FFN モデルの coremldata.bin
///   - ffnModelMilAsset:       FFN モデルの model.mil
///   - ffnWeightChunk0〜N:     FFN の weight.bin チャンク
///   - ffnWeightChunkCount:    FFN チャンク数
///   - lmheadMetadataAsset:    LM Head モデルの metadata.json
///   - lmheadCoremlDataAsset:  LM Head モデルの coremldata.bin
///   - lmheadModelMilAsset:    LM Head モデルの model.mil
///   - lmheadWeightChunk0〜N:  LM Head の weight.bin チャンク
///   - lmheadWeightChunkCount: LM Head チャンク数
///   - tokenizerAsset:         tokenizer.json
class CloudKitModelService {

    static let shared = CloudKitModelService()

    private let database = CKContainer(identifier: "iCloud.com.jinks.emeishi").publicCloudDatabase
    private let recordType = "MLModelPackage"

    // MARK: - モデルファイル名

    private let embedModelDirName  = "qwen_embeddings.mlmodelc"
    private let ffnModelDirName    = "qwen_FFN_PF_lut6_chunk_01of01.mlmodelc"
    private let lmheadModelDirName = "qwen_lm_head_lut6.mlmodelc"

    // MARK: - アセットフィールド定義

    /// 小ファイル（metadata.json / coremldata.bin / model.mil）のフィールド定義
    private struct ModelAssetConfig {
        let dirName: String
        let fields: [(field: String, relativePath: String)]
        let weightChunkPrefix: String
        let weightChunkCountField: String
    }

    private var modelConfigs: [ModelAssetConfig] {
        [
            ModelAssetConfig(
                dirName: embedModelDirName,
                fields: [
                    ("embedMetadataAsset",   "metadata.json"),
                    ("embedCoremlDataAsset", "coremldata.bin"),
                    ("embedModelMilAsset",   "model.mil"),
                ],
                weightChunkPrefix: "embedWeightChunk",
                weightChunkCountField: "embedWeightChunkCount"
            ),
            ModelAssetConfig(
                dirName: ffnModelDirName,
                fields: [
                    ("ffnMetadataAsset",   "metadata.json"),
                    ("ffnCoremlDataAsset", "coremldata.bin"),
                    ("ffnModelMilAsset",   "model.mil"),
                ],
                weightChunkPrefix: "ffnWeightChunk",
                weightChunkCountField: "ffnWeightChunkCount"
            ),
            ModelAssetConfig(
                dirName: lmheadModelDirName,
                fields: [
                    ("lmheadMetadataAsset",   "metadata.json"),
                    ("lmheadCoremlDataAsset", "coremldata.bin"),
                    ("lmheadModelMilAsset",   "model.mil"),
                ],
                weightChunkPrefix: "lmheadWeightChunk",
                weightChunkCountField: "lmheadWeightChunkCount"
            ),
        ]
    }

    /// トークナイザーのフィールド名
    private let tokenizerField = "tokenizerAsset"

    // MARK: - エラー型

    enum CloudKitModelError: LocalizedError {
        case noRecordFound
        case missingAsset(String)
        case missingChunkCount(String)
        case chunkConcatenationFailed(String)

        var errorDescription: String? {
            switch self {
            case .noRecordFound:
                return "CloudKit にモデルレコードが見つかりません"
            case .missingAsset(let field):
                return "アセットが見つかりません: \(field)"
            case .missingChunkCount(let model):
                return "\(model) の weightChunkCount が設定されていません"
            case .chunkConcatenationFailed(let model):
                return "\(model) の weight チャンクの結合に失敗しました"
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
    /// Embed / FFN / LM Head それぞれの小ファイル + 各 weight チャンク + tokenizer を取得。
    /// 各モデルは独自の weight.bin を持つ（Anemll 独立ウェイト構成）。
    /// - Parameters:
    ///   - modelDir: モデルファイルの保存先ディレクトリ（例: .../LocalLLM/）
    ///   - tokenizerDestination: tokenizer.json の保存先
    ///   - progress: 進捗コールバック（0.0〜1.0）
    func downloadModel(modelDir: URL,
                       tokenizerDestination: URL,
                       progress: @escaping (Double) -> Void) async throws {
        let record = try await fetchRecordWithProgress(progress: progress)

        let fm = FileManager.default

        // --- 各モデルの小ファイル + weight チャンク結合 ---
        for config in modelConfigs {
            let modelSubDir = modelDir.appendingPathComponent(config.dirName, isDirectory: true)

            // 小ファイル（metadata.json / coremldata.bin / model.mil）
            for (field, relativePath) in config.fields {
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

            // weight チャンクを結合して weights/weight.bin に保存
            try concatenateWeightChunks(
                record: record,
                config: config,
                modelSubDir: modelSubDir,
                fm: fm
            )
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

        progress(1.0)
    }

    // MARK: - weight チャンク結合

    /// 指定モデルの weight チャンクを結合して weights/weight.bin に保存する
    private func concatenateWeightChunks(record: CKRecord,
                                         config: ModelAssetConfig,
                                         modelSubDir: URL,
                                         fm: FileManager) throws {
        guard let chunkCount = record[config.weightChunkCountField] as? Int64, chunkCount > 0 else {
            throw CloudKitModelError.missingChunkCount(config.dirName)
        }

        let weightsDir = modelSubDir.appendingPathComponent("weights", isDirectory: true)
        try fm.createDirectory(at: weightsDir, withIntermediateDirectories: true)

        let tempURL = weightsDir.appendingPathComponent("weight_temp.bin")
        try? fm.removeItem(at: tempURL)
        fm.createFile(atPath: tempURL.path, contents: nil)

        guard let outputHandle = try? FileHandle(forWritingTo: tempURL) else {
            throw CloudKitModelError.chunkConcatenationFailed(config.dirName)
        }

        for i in 0..<Int(chunkCount) {
            let chunkField = "\(config.weightChunkPrefix)\(i)"
            guard let chunkAsset = record[chunkField] as? CKAsset,
                  let chunkURL = chunkAsset.fileURL else {
                try? outputHandle.close()
                throw CloudKitModelError.missingAsset(chunkField)
            }
            let chunkData = try Data(contentsOf: chunkURL)
            outputHandle.write(chunkData)
        }
        try outputHandle.close()

        let weightDest = weightsDir.appendingPathComponent("weight.bin")
        try? fm.removeItem(at: weightDest)
        try fm.moveItem(at: tempURL, to: weightDest)
    }
}
