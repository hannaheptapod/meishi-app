import XCTest
import CloudKit

/// CloudKit Public Database に正しいモデルファイルをアップロードするテスト。
/// Mac 上の /Users/jink/dev/pers/anemll-Qwen-Qwen3-0.6B-ctx512_0.3.4/ から読み込む。
///
/// ⚠️ 手動実行専用テスト。Xcode Cloud など CI 環境では自動スキップされる:
///   - ホストマシン固定パス（/Users/jink/dev/pers/...）にモデル実体が必要
///   - iCloud 認証済みシミュレータ・デバイスが必要
///   - 700MB+ のアップロードで実行時間が長い
///
/// 手動実行方法（ローカル Mac のみ）:
///   xcodebuild test \
///     -scheme eMeishi \
///     -destination 'platform=iOS Simulator,name=iPhone 16' \
///     -only-testing:eMeishiTests/CloudKitModelUploadTests/testUploadCorrectModels
class CloudKitModelUploadTests: XCTestCase {

    private let database   = CKContainer(identifier: "iCloud.com.jinks.emeishi").publicCloudDatabase
    private let recordID   = CKRecord.ID(recordName: "65526C03-31FB-4EE0-A61D-7C2C91C1C424")
    private let chunkBytes = 200 * 1024 * 1024  // 200 MB

    /// Mac 上の正しいモデルディレクトリ
    private let modelBase = URL(fileURLWithPath: "/Users/jink/dev/pers/anemll-Qwen-Qwen3-0.6B-ctx512_0.3.4")

    func testUploadCorrectModels() async throws {
        // CI 環境（Xcode Cloud では CI=TRUE が注入される）では自動スキップ
        try XCTSkipIf(ProcessInfo.processInfo.environment["CI"] != nil,
                      "CloudKit モデルアップロードは手動実行専用（ローカル環境・実モデルファイル前提）")

        // タイムアウトを長めに設定（700MB+ のアップロードがある）
        // continueAfterFailure は false のまま（エラーで即停止）

        log("📦 モデルベースパス確認: \(modelBase.path)")
        XCTAssertTrue(FileManager.default.fileExists(atPath: modelBase.path),
                      "モデルディレクトリが見つかりません: \(modelBase.path)")

        // --- Step 1: 既存レコード取得 ---
        log("☁️ CloudKit レコード取得中...")
        let record: CKRecord
        do {
            record = try await database.record(for: recordID)
            log("✅ レコード取得完了")
        } catch {
            XCTFail("レコード取得失敗: \(error)")
            return
        }

        // --- Step 2: 小ファイルをセット ---
        let smallFiles: [(field: String, relativePath: String)] = [
            ("coremlDataAsset",        "qwen_embeddings.mlmodelc/coremldata.bin"),
            ("metadataAsset",          "qwen_embeddings.mlmodelc/metadata.json"),
            ("modelMilAsset",          "qwen_embeddings.mlmodelc/model.mil"),
            ("prefillCoremlDataAsset", "qwen_FFN_PF_lut6_chunk_01of01.mlmodelc/coremldata.bin"),
            ("prefillMetadataAsset",   "qwen_FFN_PF_lut6_chunk_01of01.mlmodelc/metadata.json"),
            ("prefillModelMilAsset",   "qwen_FFN_PF_lut6_chunk_01of01.mlmodelc/model.mil"),
            ("decodeCoremlDataAsset",  "qwen_lm_head_lut6.mlmodelc/coremldata.bin"),
            ("decodeMetadataAsset",    "qwen_lm_head_lut6.mlmodelc/metadata.json"),
            ("decodeModelMilAsset",    "qwen_lm_head_lut6.mlmodelc/model.mil"),
            ("tokenizerAsset",         "tokenizer.json"),
        ]

        log("📄 小ファイルセット中...")
        for (field, path) in smallFiles {
            let url = modelBase.appendingPathComponent(path)
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path),
                          "ファイルが見つかりません: \(path)")
            record[field] = CKAsset(fileURL: url)
            log("  ✓ \(field) ← \(path)")
        }

        // --- Step 3: weight.bin チャンク分割 ---
        let weightFiles: [(String, String)] = [
            ("qwen_embeddings.mlmodelc/weights/weight.bin",              "embed"),
            ("qwen_FFN_PF_lut6_chunk_01of01.mlmodelc/weights/weight.bin", "FFN"),
            ("qwen_lm_head_lut6.mlmodelc/weights/weight.bin",            "LMHead"),
        ]

        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ck_upload_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        var chunkIndex = 0
        for (weightPath, label) in weightFiles {
            let src = modelBase.appendingPathComponent(weightPath)
            XCTAssertTrue(FileManager.default.fileExists(atPath: src.path),
                          "weight.bin が見つかりません: \(weightPath)")

            let attrs = try FileManager.default.attributesOfItem(atPath: src.path)
            let fileSize = attrs[.size] as? Int ?? 0
            log("🔪 \(label) weight.bin 分割中（\(fileSize / 1024 / 1024) MB）...")

            let handle = try FileHandle(forReadingFrom: src)
            defer { try? handle.close() }
            var part = 0
            while true {
                guard let data = try handle.read(upToCount: chunkBytes), !data.isEmpty else { break }
                let chunkURL = tmpDir.appendingPathComponent("chunk_\(chunkIndex).bin")
                try data.write(to: chunkURL)
                record["weightChunk\(chunkIndex)"] = CKAsset(fileURL: chunkURL)
                log("  chunk\(chunkIndex): \(data.count / 1024 / 1024) MB")
                chunkIndex += 1
                part += 1
            }
            log("  \(label): \(part) チャンク")
        }

        record["weightChunkCount"] = Int64(chunkIndex)
        log("📊 合計チャンク数: \(chunkIndex)")

        // --- Step 4: CloudKit 保存 ---
        log("⬆️ CloudKit 保存中（数分かかる場合があります）...")
        do {
            let saved = try await database.save(record)
            log("✅ 保存完了: \(saved.recordID.recordName)")
        } catch {
            XCTFail("CloudKit 保存失敗: \(error)")
        }
    }

    private func log(_ message: String) {
        print("[CloudKitUpload] \(message)")
    }
}
