import Foundation
import CloudKit

/// CloudKit Public Database からオンデバイスLLMモデルファイルをダウンロードするサービス。
/// Prefill/Decode 分割方式の Qwen3-0.6B-4bit モデルに対応。
/// weight.bin は CKAsset 上限（250MB）を超える場合があるためチャンク分割に対応。
///
/// CloudKit レコード構成（MLModelPackage）:
///   - prefillMetadataAsset:    Prefill の metadata.json
///   - prefillCoremlDataAsset:  Prefill の coremldata.bin
///   - prefillModelMilAsset:    Prefill の model.mil
///   - decodeMetadataAsset:     Decode の metadata.json
///   - decodeCoremlDataAsset:   Decode の coremldata.bin
///   - decodeModelMilAsset:     Decode の model.mil
///   - weightChunk0〜N:         共有 weight.bin のチャンク（Prefill/Decode で同一ウェイト）
///   - weightChunkCount:        チャンク数
///   - tokenizerAsset:          tokenizer.json
class CloudKitModelService {

    static let shared = CloudKitModelService()

    private let database = CKContainer(identifier: "iCloud.com.jinks.emeishi").publicCloudDatabase
    private let recordType = "MLModelPackage"

    // MARK: - モデルファイル名

    private let prefillModelDirName = "Qwen3-0.6B-Prefill-4bit.mlmodelc"
    private let decodeModelDirName  = "Qwen3-0.6B-Decode-4bit.mlmodelc"

    // MARK: - アセットフィールド定義

    /// Prefill モデルの小ファイル: フィールド名 → mlmodelc 内の相対パス
    private let prefillAssetFields: [(field: String, relativePath: String)] = [
        ("prefillMetadataAsset",   "metadata.json"),
        ("prefillCoremlDataAsset", "coremldata.bin"),
        ("prefillModelMilAsset",   "model.mil"),
    ]

    /// Decode モデルの小ファイル: フィールド名 → mlmodelc 内の相対パス
    private let decodeAssetFields: [(field: String, relativePath: String)] = [
        ("decodeMetadataAsset",   "metadata.json"),
        ("decodeCoremlDataAsset", "coremldata.bin"),
        ("decodeModelMilAsset",   "model.mil"),
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
    /// Prefill/Decode 両モデルの小ファイル + 共有 weight チャンク + tokenizer を取得。
    /// weight.bin は Prefill/Decode で同一のため、両方の weights/ に配置する。
    /// - Parameters:
    ///   - modelDir: モデルファイルの保存先ディレクトリ（例: .../LocalLLM/）
    ///   - tokenizerDestination: tokenizer.json の保存先
    ///   - progress: 進捗コールバック（0.0〜1.0）
    func downloadModel(modelDir: URL,
                       tokenizerDestination: URL,
                       progress: @escaping (Double) -> Void) async throws {
        let record = try await fetchRecordWithProgress(progress: progress)

        let fm = FileManager.default

        // --- Prefill モデルの小ファイル保存 ---
        let prefillDir = modelDir.appendingPathComponent(prefillModelDirName, isDirectory: true)
        for (field, relativePath) in prefillAssetFields {
            guard let asset = record[field] as? CKAsset,
                  let sourceURL = asset.fileURL else {
                throw CloudKitModelError.missingAsset(field)
            }
            let destURL = prefillDir.appendingPathComponent(relativePath)
            let parentDir = destURL.deletingLastPathComponent()
            try fm.createDirectory(at: parentDir, withIntermediateDirectories: true)
            try? fm.removeItem(at: destURL)
            try fm.copyItem(at: sourceURL, to: destURL)
        }

        // --- Decode モデルの小ファイル保存 ---
        let decodeDir = modelDir.appendingPathComponent(decodeModelDirName, isDirectory: true)
        for (field, relativePath) in decodeAssetFields {
            guard let asset = record[field] as? CKAsset,
                  let sourceURL = asset.fileURL else {
                throw CloudKitModelError.missingAsset(field)
            }
            let destURL = decodeDir.appendingPathComponent(relativePath)
            let parentDir = destURL.deletingLastPathComponent()
            try fm.createDirectory(at: parentDir, withIntermediateDirectories: true)
            try? fm.removeItem(at: destURL)
            try fm.copyItem(at: sourceURL, to: destURL)
        }

        // --- tokenizer.json の保存 ---
        guard let tokenizerAsset = record[tokenizerField] as? CKAsset,
              let tokenizerSourceURL = tokenizerAsset.fileURL else {
            throw CloudKitModelError.missingAsset(tokenizerField)
        }
        try? fm.removeItem(at: tokenizerDestination)
        try fm.copyItem(at: tokenizerSourceURL, to: tokenizerDestination)

        // --- weight チャンクの結合 ---
        guard let chunkCount = record["weightChunkCount"] as? Int64, chunkCount > 0 else {
            throw CloudKitModelError.missingChunkCount
        }

        // weight.bin を一時ファイルに結合し、Prefill/Decode 両方の weights/ にコピー
        let tempWeightURL = modelDir.appendingPathComponent("weight_temp.bin")
        try? fm.removeItem(at: tempWeightURL)
        fm.createFile(atPath: tempWeightURL.path, contents: nil)
        guard let outputHandle = try? FileHandle(forWritingTo: tempWeightURL) else {
            throw CloudKitModelError.chunkConcatenationFailed
        }

        for i in 0 ..< Int(chunkCount) {
            let chunkField = "\(weightChunkPrefix)\(i)"
            guard let chunkAsset = record[chunkField] as? CKAsset,
                  let chunkURL = chunkAsset.fileURL else {
                throw CloudKitModelError.missingAsset(chunkField)
            }
            let chunkData = try Data(contentsOf: chunkURL)
            outputHandle.write(chunkData)
        }
        try outputHandle.close()

        // Prefill の weights/weight.bin
        let prefillWeightsDir = prefillDir.appendingPathComponent("weights", isDirectory: true)
        try fm.createDirectory(at: prefillWeightsDir, withIntermediateDirectories: true)
        let prefillWeightDest = prefillWeightsDir.appendingPathComponent("weight.bin")
        try? fm.removeItem(at: prefillWeightDest)
        try fm.copyItem(at: tempWeightURL, to: prefillWeightDest)

        // Decode の weights/weight.bin
        let decodeWeightsDir = decodeDir.appendingPathComponent("weights", isDirectory: true)
        try fm.createDirectory(at: decodeWeightsDir, withIntermediateDirectories: true)
        let decodeWeightDest = decodeWeightsDir.appendingPathComponent("weight.bin")
        try? fm.removeItem(at: decodeWeightDest)
        try fm.copyItem(at: tempWeightURL, to: decodeWeightDest)

        // 一時ファイル削除
        try? fm.removeItem(at: tempWeightURL)

        progress(1.0)
    }
}
