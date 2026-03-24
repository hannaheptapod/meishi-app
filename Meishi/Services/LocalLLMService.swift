import Foundation
import CoreML
import Combine

// オンデバイスOSSモデルによる意味分析サービス
// Foundation Modelsが利用不可の場合のフォールバック（層2）
class LocalLLMService: ObservableObject {

    static let shared = LocalLLMService()

    // MARK: - 定数

    let modelFileName = "Qwen2.5-0.5B-Instruct-4bit.mlmodelc"
    private let hfBase = "https://huggingface.co/finnvoorhees/coreml-Qwen2.5-0.5B-Instruct-4bit/resolve/main/Qwen2.5-0.5B-Instruct-4bit.mlmodelc"
    // mlmodelc はディレクトリ構造のため、構成ファイルを個別にダウンロードする
    private let modelFiles: [(path: String, approxBytes: Int64)] = [
        ("metadata.json",           10_000),
        ("coremldata.bin",          50_000),
        ("analytics/coremldata.bin", 5_000),
        ("model.mil",            5_000_000),
        ("weights/weight.bin", 268_000_000),
    ]

    // MARK: - 状態

    /// モデルが取得済みかつロード可能な状態かどうか
    @Published var isModelAvailable: Bool = false

    /// ダウンロード中かどうか
    @Published var isDownloading: Bool = false

    /// ダウンロード進捗（0.0〜1.0）
    @Published var downloadProgress: Double = 0.0

    private var loadedModel: MLModel? = nil

    var modelFileURL: URL {
        let dir = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LocalLLM", isDirectory: true)
        return dir.appendingPathComponent(modelFileName, isDirectory: true)
    }

    private init() {
        // weight.bin が存在すればダウンロード完了とみなす
        let weightURL = modelFileURL.appendingPathComponent("weights/weight.bin")
        isModelAvailable = FileManager.default.fileExists(atPath: weightURL.path)
    }

    // MARK: - モデルロード

    func loadModelIfNeeded() throws {
        guard isModelAvailable, loadedModel == nil else { return }
        let config = MLModelConfiguration()
        config.computeUnits = .all   // ANE / GPU / CPU を自動選択
        loadedModel = try MLModel(contentsOf: modelFileURL, configuration: config)
    }

    // MARK: - 推論

    /// OCR行リストを受け取り、CardFieldClassifier.ParsedCard を返す
    /// エラー時またはモデル未ロード時は nil を返す（呼び出し元はフォールバックへ進む）
    func classify(lines: [String]) async -> CardFieldClassifier.ParsedCard? {
        guard let model = loadedModel else { return nil }

        let prompt = buildPrompt(lines: lines)

        // NOTE: CoreMLPipelines または MLModel の generate API を使用する
        // 実装はモデルのMLPackage仕様に依存するため、
        // ダウンロード後に以下を具体化する
        //
        // let input = try Qwen25Input(prompt: prompt)
        // let output = try model.prediction(from: input)
        // return parseJSON(output.text)

        _ = model   // 未使用警告を抑制（実装プレースホルダー）
        _ = prompt
        return nil
    }

    // MARK: - プロンプト構築

    private func buildPrompt(lines: [String]) -> String {
        let rawText = lines.joined(separator: "\n")
        return """
            以下は名刺から読み取ったテキストです。各フィールドをJSON形式で出力してください。
            キー名は必ず lastName / firstName / company / title / phone / email / address / website を使用してください。
            値が不明な場合は空文字列にしてください。JSONのみ出力し、説明は不要です。

            \(rawText)
            """
    }

    // MARK: - JSONパース

    private func parseJSON(_ text: String) -> CardFieldClassifier.ParsedCard? {
        // モデル出力から ```json ``` フェンスを除去してパース
        let cleaned = text
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard let data = cleaned.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: String]
        else { return nil }

        var result = CardFieldClassifier.ParsedCard()
        result.lastName  = dict["lastName"]  ?? ""
        result.firstName = dict["firstName"] ?? ""
        result.company   = dict["company"]   ?? ""
        result.title     = dict["title"]     ?? ""
        result.phone     = dict["phone"]     ?? ""
        result.email     = dict["email"]     ?? ""
        result.address   = dict["address"]   ?? ""
        result.website   = dict["website"]   ?? ""
        return result
    }

    // MARK: - ダウンロード

    /// ユーザーの同意を得たあとに呼び出す。@Published プロパティで進捗を通知する
    func downloadModel() async throws {
        await MainActor.run {
            isDownloading = true
            downloadProgress = 0.0
        }
        defer {
            Task { @MainActor in isDownloading = false }
        }

        let dir = modelFileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        // URLSession の delegate で進捗を追跡
        let totalBytes = modelFiles.reduce(0) { $0 + $1.approxBytes }
        var downloadedBytes: Int64 = 0

        let session = URLSession(configuration: .default)

        for (relativePath, approxBytes) in modelFiles {
            let fileURL = modelFileURL.appendingPathComponent(relativePath)
            let parentDir = fileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true)

            let remoteURL = URL(string: "\(hfBase)/\(relativePath)")!
            let (tempURL, _) = try await session.download(from: remoteURL)
            try? FileManager.default.removeItem(at: fileURL)
            try FileManager.default.moveItem(at: tempURL, to: fileURL)

            downloadedBytes += approxBytes
            let progress = min(Double(downloadedBytes) / Double(totalBytes), 1.0)
            await MainActor.run { self.downloadProgress = progress }
        }

        try loadModelIfNeeded()

        await MainActor.run { isModelAvailable = true }
    }

    // MARK: - 削除

    /// ダウンロード済みモデルディレクトリを削除する
    func deleteModel() throws {
        guard isModelAvailable else { return }
        try FileManager.default.removeItem(at: modelFileURL)
        loadedModel = nil
        isModelAvailable = false
    }

    // MARK: - モデルファイルサイズ

    /// ダウンロード済みモデルのファイルサイズ合計（バイト）
    var modelFileSize: Int64? {
        guard isModelAvailable else { return nil }
        let enumerator = FileManager.default.enumerator(
            at: modelFileURL,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        )
        var total: Int64 = 0
        while let fileURL = enumerator?.nextObject() as? URL {
            let size = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            total += Int64(size)
        }
        return total > 0 ? total : nil
    }
}

