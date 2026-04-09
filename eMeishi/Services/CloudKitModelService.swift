import Foundation
import CloudKit

/// CloudKit Public Database からオンデバイスLLMモデルファイルをダウンロードするサービス。
/// Anemll 変換済み Qwen3-0.6B-ctx512（3モデル分割方式）に対応。
///
/// CloudKit レコード構成（MLModelPackage）:
///   - coremlDataAsset:         Embed モデルの coremldata.bin
///   - metadataAsset:           Embed モデルの metadata.json
///   - modelMilAsset:           Embed モデルの model.mil
///   - prefillCoremlDataAsset:  FFN モデルの coremldata.bin
///   - prefillMetadataAsset:    FFN モデルの metadata.json
///   - prefillModelMilAsset:    FFN モデルの model.mil
///   - decodeCoremlDataAsset:   LM Head モデルの coremldata.bin
///   - decodeMetadataAsset:     LM Head モデルの metadata.json
///   - decodeModelMilAsset:     LM Head モデルの model.mil
///   - weightChunk0〜4:         weight.bin チャンク（embed:0-1, ffn:2-3, lmhead:4）
///   - weightChunkCount:        チャンク総数（= 5）
///   - tokenizerAsset:          tokenizer.json
class CloudKitModelService {

    static let shared = CloudKitModelService()

    private let database = CKContainer(identifier: "iCloud.com.jinks.emeishi").publicCloudDatabase
    private let recordType = "MLModelPackage"

    // MARK: - モデルファイル名

    private let embedModelDirName  = "qwen_embeddings.mlmodelc"
    private let ffnModelDirName    = "qwen_FFN_PF_lut6_chunk_01of01.mlmodelc"
    private let lmheadModelDirName = "qwen_lm_head_lut6.mlmodelc"

    // MARK: - アセットフィールド定義（本番スキーマに合わせた命名）

    private struct ModelAssetConfig {
        let dirName: String
        let coremlDataField: String
        let metadataField: String
        let modelMilField: String
        /// weightChunk のインデックス範囲（例: 0..<2）
        let chunkRange: Range<Int>
    }

    private let modelConfigs: [ModelAssetConfig] = [
        ModelAssetConfig(
            dirName: "qwen_embeddings.mlmodelc",
            coremlDataField: "coremlDataAsset",
            metadataField:   "metadataAsset",
            modelMilField:   "modelMilAsset",
            chunkRange:      0..<2
        ),
        ModelAssetConfig(
            dirName: "qwen_FFN_PF_lut6_chunk_01of01.mlmodelc",
            coremlDataField: "prefillCoremlDataAsset",
            metadataField:   "prefillMetadataAsset",
            modelMilField:   "prefillModelMilAsset",
            chunkRange:      2..<4
        ),
        ModelAssetConfig(
            dirName: "qwen_lm_head_lut6.mlmodelc",
            coremlDataField: "decodeCoremlDataAsset",
            metadataField:   "decodeMetadataAsset",
            modelMilField:   "decodeModelMilAsset",
            chunkRange:      4..<5
        ),
    ]

    private let tokenizerField     = "tokenizerAsset"
    private let weightChunkPrefix  = "weightChunk"
    private let weightChunkCountField = "weightChunkCount"

    // MARK: - エラー型

    enum CloudKitModelError: LocalizedError {
        case noRecordFound
        case missingAsset(String)
        case missingChunkCount
        case chunkConcatenationFailed(String)

        var errorDescription: String? {
            switch self {
            case .noRecordFound:
                return "CloudKit にモデルレコードが見つかりません"
            case .missingAsset(let field):
                return "アセットが見つかりません: \(field)"
            case .missingChunkCount:
                return "weightChunkCount が設定されていません"
            case .chunkConcatenationFailed(let model):
                return "\(model) の weight チャンクの結合に失敗しました"
            }
        }
    }

    private init() {}

    // MARK: - レコード取得

    private let modelRecordID = CKRecord.ID(recordName: "65526C03-31FB-4EE0-A61D-7C2C91C1C424")

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

    func downloadModel(modelDir: URL,
                       tokenizerDestination: URL,
                       progress: @escaping (Double) -> Void) async throws {
        let record = try await fetchRecordWithProgress(progress: progress)
        let fm = FileManager.default

        // weightChunkCount を取得
        guard let chunkCount = record[weightChunkCountField] as? Int64, chunkCount > 0 else {
            throw CloudKitModelError.missingChunkCount
        }

        // 各モデルの小ファイル + weight チャンク結合
        for config in modelConfigs {
            let modelSubDir = modelDir.appendingPathComponent(config.dirName, isDirectory: true)

            // 小ファイル（coremldata.bin / metadata.json / model.mil）
            let smallFiles: [(field: String, path: String)] = [
                (config.coremlDataField, "coremldata.bin"),
                (config.metadataField,   "metadata.json"),
                (config.modelMilField,   "model.mil"),
            ]
            for (field, relativePath) in smallFiles {
                guard let asset = record[field] as? CKAsset,
                      let sourceURL = asset.fileURL else {
                    throw CloudKitModelError.missingAsset(field)
                }
                let destURL = modelSubDir.appendingPathComponent(relativePath)
                try fm.createDirectory(at: destURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? fm.removeItem(at: destURL)
                try fm.copyItem(at: sourceURL, to: destURL)
            }

            // weight チャンクを結合して weights/weight.bin に保存
            try concatenateChunks(
                record: record,
                range: config.chunkRange,
                modelSubDir: modelSubDir,
                modelName: config.dirName,
                fm: fm
            )
        }

        // tokenizer.json を保存
        guard let tokenizerAsset = record[tokenizerField] as? CKAsset,
              let tokenizerSourceURL = tokenizerAsset.fileURL else {
            throw CloudKitModelError.missingAsset(tokenizerField)
        }
        try fm.createDirectory(at: tokenizerDestination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? fm.removeItem(at: tokenizerDestination)
        try fm.copyItem(at: tokenizerSourceURL, to: tokenizerDestination)

        progress(1.0)
    }

    // MARK: - weight チャンク結合

    private func concatenateChunks(record: CKRecord,
                                   range: Range<Int>,
                                   modelSubDir: URL,
                                   modelName: String,
                                   fm: FileManager) throws {
        let weightsDir = modelSubDir.appendingPathComponent("weights", isDirectory: true)
        try fm.createDirectory(at: weightsDir, withIntermediateDirectories: true)

        let tempURL = weightsDir.appendingPathComponent("weight_temp.bin")
        try? fm.removeItem(at: tempURL)
        fm.createFile(atPath: tempURL.path, contents: nil)

        guard let outputHandle = try? FileHandle(forWritingTo: tempURL) else {
            throw CloudKitModelError.chunkConcatenationFailed(modelName)
        }

        for i in range {
            let field = "\(weightChunkPrefix)\(i)"
            guard let chunkAsset = record[field] as? CKAsset,
                  let chunkURL = chunkAsset.fileURL else {
                try? outputHandle.close()
                throw CloudKitModelError.missingAsset(field)
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
