import Foundation
import CoreML
import Accelerate
import Combine

// オンデバイス Qwen3-0.6B（4bit量子化 CoreML・Prefill/Decode 分割方式）による意味分析サービス
// モデルソース: smkrv/Qwen3-0.6B-CoreML-4bit
//
// モデルファイル配置先（2通り）:
//   A) CloudKit 経由ダウンロード → ~/Library/Application Support/LocalLLM/
//   B) 開発用ローカル配置 → Documents/LocalLLM/（Finder / iTunes ファイル共有で転送）
//
// 必要ファイル構成:
//   <modelDir>/
//     Qwen3-0.6B-Prefill-4bit.mlmodelc/   (コンパイル済み Prefill モデル)
//     Qwen3-0.6B-Decode-4bit.mlmodelc/    (コンパイル済み Decode モデル)
//     tokenizer.json                       (BPE トークナイザー)
class LocalLLMService: ObservableObject {

    static let shared = LocalLLMService()

    // MARK: - 定数

    private let prefillModelName = "Qwen3-0.6B-Prefill-4bit.mlmodelc"
    private let decodeModelName  = "Qwen3-0.6B-Decode-4bit.mlmodelc"

    // MARK: - 状態

    @Published var isModelAvailable: Bool = false
    @Published var isDownloading:    Bool = false
    @Published var downloadProgress: Double = 0.0
    @Published var isInferencing:    Bool = false

    private var prefillModel: MLModel? = nil
    private var decodeModel:  MLModel? = nil
    private var tokenizer:    Qwen25Tokenizer? = nil

    // MARK: - ファイルパス

    /// Application Support 内のモデルディレクトリ（CloudKit ダウンロード先）
    var modelDirURL: URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LocalLLM", isDirectory: true)
    }

    /// Documents 内のモデルディレクトリ（開発用ローカル配置）
    private var localModelDirURL: URL {
        FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LocalLLM", isDirectory: true)
    }

    /// 実際に使用するモデルディレクトリ（Documents 優先、なければ Application Support）
    private var activeModelDir: URL {
        let localPrefill = localModelDirURL.appendingPathComponent(prefillModelName)
        if FileManager.default.fileExists(atPath: localPrefill.path) {
            return localModelDirURL
        }
        return modelDirURL
    }

    var prefillModelURL: URL { activeModelDir.appendingPathComponent(prefillModelName) }
    var decodeModelURL:  URL { activeModelDir.appendingPathComponent(decodeModelName) }
    var tokenizerFileURL: URL { activeModelDir.appendingPathComponent("tokenizer.json") }

    private init() {
        isModelAvailable = checkModelFiles()
    }

    /// モデルファイルの存在を確認（Documents → Application Support の順）
    private func checkModelFiles() -> Bool {
        let fm = FileManager.default
        // Documents 内を先にチェック（開発用ローカル配置）
        let localDir = localModelDirURL
        let localPrefill = localDir.appendingPathComponent(prefillModelName)
        let localDecode  = localDir.appendingPathComponent(decodeModelName)
        let localTok     = localDir.appendingPathComponent("tokenizer.json")
        if fm.fileExists(atPath: localPrefill.path)
        && fm.fileExists(atPath: localDecode.path)
        && fm.fileExists(atPath: localTok.path) {
            return true
        }
        // Application Support 内をチェック（CloudKit ダウンロード）
        let appDir = modelDirURL
        let appPrefill = appDir.appendingPathComponent(prefillModelName)
        let appDecode  = appDir.appendingPathComponent(decodeModelName)
        let appTok     = appDir.appendingPathComponent("tokenizer.json")
        return fm.fileExists(atPath: appPrefill.path)
            && fm.fileExists(atPath: appDecode.path)
            && fm.fileExists(atPath: appTok.path)
    }

    // MARK: - モデル管理

    func loadModelIfNeeded() throws {
        guard isModelAvailable else { return }

        let config = MLModelConfiguration()
        config.computeUnits = .all

        if prefillModel == nil {
            prefillModel = try MLModel(contentsOf: prefillModelURL, configuration: config)
            print("[LocalLLM] Prefill モデルロード完了")
        }
        if decodeModel == nil {
            decodeModel = try MLModel(contentsOf: decodeModelURL, configuration: config)
            print("[LocalLLM] Decode モデルロード完了")
        }
        if tokenizer == nil {
            tokenizer = try Qwen25Tokenizer(url: tokenizerFileURL)
        }
    }

    // MARK: - 推論（公開API）

    /// ハイブリッド分類: ルールベース（空間情報活用）で確実なフィールドを先に抽出し、
    /// 未分類行のみLLMに送って名前・役職・部署を判定する。
    /// モデル未ロード・推論失敗時は nil を返す（呼び出し元はフォールバックへ進む）。
    func classify(lines: [RecognizedLine]) async -> CardFieldClassifier.ParsedCard? {
        // アプリ再起動後に未ロードの場合はここでロードする
        if prefillModel == nil || decodeModel == nil || tokenizer == nil {
            await MainActor.run { isInferencing = true }
            // モデルファイルの存在を再チェック（Finder で追加された場合に対応）
            isModelAvailable = checkModelFiles()
            try? loadModelIfNeeded()
        }
        guard let pModel = prefillModel, let dModel = decodeModel, let tok = tokenizer else {
            await MainActor.run { isInferencing = false }
            return nil
        }

        await MainActor.run { isInferencing = true }
        defer { Task { @MainActor in self.isInferencing = false } }

        // --- Step 1: ルールベース（座標情報含む）で確実なフィールドを先に抽出 ---
        let ruleResult = CardFieldClassifier().classifyStructuredFields(lines: lines)
        let baseParsed = ruleResult.parsed

        // 未分類行が空ならLLM不要（全フィールドがルールで解決済み）
        guard !ruleResult.unclassifiedLines.isEmpty else {
            return baseParsed
        }

        // --- Step 2: 未分類行のみをLLMに送る ---
        let prompt   = buildChatMLPrompt(
            unclassifiedLines: ruleResult.unclassifiedLines,
            knownCompany: baseParsed.company
        )
        let inputIds = tok.encode(prompt)

        let timeoutSeconds: TimeInterval = 7
        let deadline = Date().addingTimeInterval(timeoutSeconds)

        print("[LocalLLM] 推論開始。入力トークン数: \(inputIds.count)")
        let startTime = Date()

        do {
            let output = try runGeneration(
                prefillModel: pModel, decodeModel: dModel,
                tokenizer: tok, inputIds: inputIds, deadline: deadline
            )
            let elapsed = Date().timeIntervalSince(startTime)
            print("[LocalLLM] 推論完了。\(String(format: "%.1f", elapsed))秒")

            // プロンプトで `{` をプリフィル済みなので先頭に補完
            let jsonOutput = "{" + output
            guard let llmResult = parseJSON(jsonOutput) else {
                print("[LocalLLM] JSONパース失敗。生出力: \(output.prefix(200))")
                return baseParsed
            }

            // --- Step 3: ルールベース結果とLLM結果をマージ ---
            return mergeResults(base: baseParsed, llm: llmResult)
        } catch InferenceError.timeout {
            let elapsed = Date().timeIntervalSince(startTime)
            print("[LocalLLM] 推論タイムアウト（\(String(format: "%.1f", elapsed))秒）")
            return baseParsed
        } catch {
            print("[LocalLLM] 推論エラー: \(error.localizedDescription)")
            return baseParsed
        }
    }

    /// ルールベース結果にLLM結果を上書きマージする。
    private func mergeResults(base: CardFieldClassifier.ParsedCard,
                              llm: CardFieldClassifier.ParsedCard) -> CardFieldClassifier.ParsedCard {
        var merged = base
        if !llm.lastName.isEmpty  { merged.lastName  = llm.lastName }
        if !llm.firstName.isEmpty { merged.firstName = llm.firstName }
        if !llm.title.isEmpty     { merged.title     = llm.title }
        if !llm.department.isEmpty { merged.department = llm.department }
        if merged.company.isEmpty && !llm.company.isEmpty { merged.company = llm.company }
        return merged
    }

    // MARK: - テキスト生成ループ（Prefill/Decode 分割方式）

    /// Prefill モデルでプロンプトを一括処理し、Decode モデルで全シーケンスを逐次拡張して生成する。
    /// このモデルには KV キャッシュがないため、各 Decode ステップで全トークンを再処理する。
    /// 0.6B モデルのため 1 ステップ 50-100ms 程度。
    private let maxContextLength = 1024

    private func runGeneration(prefillModel: MLModel,
                               decodeModel: MLModel,
                               tokenizer: Qwen25Tokenizer,
                               inputIds: [Int],
                               deadline: Date) throws -> String {
        let promptLen    = inputIds.count
        var allIds       = inputIds   // プロンプト + 生成済みトークンの全体
        var generatedIds = [Int]()
        let maxNewTokens = 60
        // プロンプトで `{` をプリフィル済みなので、最初から開きブレース1つ分を追跡
        var openBraces   = 1
        var jsonStarted  = true

        // --- Prefill: プロンプト全体を一括処理 ---
        if Date() > deadline { throw InferenceError.timeout }

        let prefillLogits = try forwardPrefill(
            model: prefillModel, ids: inputIds, seqLen: promptLen
        )

        guard let firstToken = argmaxLastToken(logits: prefillLogits) else {
            return ""
        }
        if firstToken == Qwen25Tokenizer.SpecialToken.imEnd
        || firstToken == Qwen25Tokenizer.SpecialToken.eot { return "" }
        generatedIds.append(firstToken)
        allIds.append(firstToken)

        // 最初のトークンでブレース追跡
        for ch in tokenizer.decode([firstToken]) {
            if ch == "{" { openBraces += 1; jsonStarted = true }
            else if ch == "}" && jsonStarted { openBraces -= 1 }
        }
        if jsonStarted && openBraces <= 0 {
            return tokenizer.decode(generatedIds)
        }

        // --- Decode: 全シーケンスを毎回渡して次トークンを予測 ---
        while generatedIds.count < maxNewTokens {
            if Date() > deadline { throw InferenceError.timeout }
            guard allIds.count < maxContextLength else { break }

            let decLogits = try forwardDecode(
                model: decodeModel, ids: allIds, seqLen: allIds.count
            )

            guard let nextToken = argmaxLastToken(logits: decLogits) else { break }
            if nextToken == Qwen25Tokenizer.SpecialToken.imEnd
            || nextToken == Qwen25Tokenizer.SpecialToken.eot { break }
            generatedIds.append(nextToken)
            allIds.append(nextToken)

            // { } をカウントしてJSONが閉じたら即終了
            for ch in tokenizer.decode([nextToken]) {
                if ch == "{" { openBraces += 1; jsonStarted = true }
                else if ch == "}" && jsonStarted { openBraces -= 1 }
            }
            if jsonStarted && openBraces <= 0 { break }
        }

        return tokenizer.decode(generatedIds)
    }

    // MARK: - Forward Pass（Prefill）

    /// Prefill モデルの forward pass（プロンプト全体を一括処理）
    /// 入力: inputIds [1, seqLen] + causalMask [1, 1, seqLen, 1024]
    /// 出力: logits [1, 1, 151936]
    private func forwardPrefill(model: MLModel, ids: [Int], seqLen: Int) throws -> MLMultiArray {
        let inputArray = try MLMultiArray(shape: [1, NSNumber(value: seqLen)], dataType: .int32)
        for (i, id) in ids.enumerated() { inputArray[i] = NSNumber(value: id) }

        let mask = try buildCausalMask(queryLen: seqLen, keyLen: maxContextLength)

        let features: [String: Any] = [
            "inputIds":   MLFeatureValue(multiArray: inputArray),
            "causalMask": MLFeatureValue(multiArray: mask),
        ]
        let provider = try MLDictionaryFeatureProvider(dictionary: features)
        let output   = try model.prediction(from: provider)

        guard let logits = output.featureValue(for: "logits")?.multiArrayValue else {
            throw InferenceError.noLogits
        }
        return logits
    }

    // MARK: - Forward Pass（Decode）

    /// Decode モデルの forward pass（全シーケンスを入力し最後のトークンの logits を取得）
    /// 入力: inputIds [1, seqLen]（プロンプト + 生成済みトークン全体）
    /// 出力: logits
    /// このモデルは内部で causal mask と position_ids を自動構築する
    private func forwardDecode(model: MLModel, ids: [Int], seqLen: Int) throws -> MLMultiArray {
        let inputArray = try MLMultiArray(shape: [1, NSNumber(value: seqLen)], dataType: .int32)
        for (i, id) in ids.enumerated() { inputArray[i] = NSNumber(value: id) }

        let features: [String: Any] = [
            "inputIds": MLFeatureValue(multiArray: inputArray),
        ]
        let provider = try MLDictionaryFeatureProvider(dictionary: features)
        let output   = try model.prediction(from: provider)

        guard let logits = output.featureValue(for: "logits")?.multiArrayValue else {
            throw InferenceError.noLogits
        }
        return logits
    }

    // MARK: - Causal Mask

    /// Prefill 用 causal_mask を Float16 で構築する [1, 1, queryLen, keyLen]
    /// keyLen は常に maxContextLength (1024)
    /// 0.0 = 参照可、-inf に近い大きな負の値 = マスク
    func buildCausalMask(queryLen: Int, keyLen: Int) throws -> MLMultiArray {
        let shape: [NSNumber] = [1, 1, NSNumber(value: queryLen), NSNumber(value: keyLen)]
        let mask = try MLMultiArray(shape: shape, dataType: .float16)

        let allowVal: NSNumber = 0.0
        let blockVal: NSNumber = -30000.0

        for i in 0 ..< queryLen {
            // causal: position i は keyLen - queryLen + i 以下のキーを参照可能
            let absI = keyLen - queryLen + i
            for j in 0 ..< keyLen {
                mask[i * keyLen + j] = (j <= absI) ? allowVal : blockVal
            }
        }
        return mask
    }

    private enum InferenceError: Error { case noLogits, timeout }

    // MARK: - Argmax・float16変換

    /// ロジット配列の最後のトークン位置で argmax を取り、最大値のインデックスを返す
    /// Prefill: [1, 1, 151936]、Decode: スカラーまたは [vocab] 等の可変形状に対応
    private func argmaxLastToken(logits: MLMultiArray) -> Int? {
        let shape   = logits.shape.map { $0.intValue }
        let strides = logits.strides.map { $0.intValue }

        let vocabSize: Int
        let baseOffset: Int
        switch shape.count {
        case 1:
            vocabSize  = shape[0]
            baseOffset = 0
        case 2:
            vocabSize  = shape[1]
            let lastRow = max(0, shape[0] - 1)
            baseOffset  = lastRow * strides[0]
        case 3:
            vocabSize   = shape[2]
            let lastPos = max(0, shape[1] - 1)
            baseOffset  = lastPos * strides[1]
        default:
            return nil
        }

        let vocabStride = strides.last ?? 1
        var maxVal: Float = -.infinity
        var argmax = 0

        switch logits.dataType {
        case .float32:
            let ptr = logits.dataPointer.assumingMemoryBound(to: Float32.self)
            for v in 0 ..< vocabSize {
                let val = ptr[baseOffset + v * vocabStride]
                if val > maxVal { maxVal = val; argmax = v }
            }
        case .float16:
            let ptr = logits.dataPointer.assumingMemoryBound(to: UInt16.self)
            for v in 0 ..< vocabSize {
                let bits = ptr[baseOffset + v * vocabStride]
                let val  = float16ToFloat32(bits)
                if val > maxVal { maxVal = val; argmax = v }
            }
        default:
            for v in 0 ..< vocabSize {
                let val = logits[baseOffset + v * vocabStride].floatValue
                if val > maxVal { maxVal = val; argmax = v }
            }
        }

        return argmax
    }

    /// IEEE 754 half-precision（float16）を float32 に変換
    private func float16ToFloat32(_ bits: UInt16) -> Float {
        let sign     = UInt32(bits >> 15) << 31
        let exp16    = Int((bits >> 10) & 0x1F)
        let mantissa = UInt32(bits & 0x3FF)
        let f32bits: UInt32
        if exp16 == 0 {
            if mantissa == 0 {
                f32bits = sign
            } else {
                var m = mantissa
                var e = Int32(-14)
                while (m & 0x400) == 0 { m <<= 1; e -= 1 }
                m &= 0x3FF
                f32bits = sign | (UInt32(e + 127) << 23) | (m << 13)
            }
        } else if exp16 == 31 {
            f32bits = sign | 0x7F800000 | (mantissa << 13)
        } else {
            f32bits = sign | (UInt32(exp16 - 15 + 127) << 23) | (mantissa << 13)
        }
        return Float(bitPattern: f32bits)
    }

    // MARK: - プロンプト構築（ChatML 形式）

    /// ハイブリッド方式用: 未分類行のみを対象に名前・役職・部署を問う最小プロンプト
    /// - 英語で記述しトークン数を削減（日本語はトークン効率が悪い）
    /// - Qwen3 の思考モード無効化（/no_think）
    /// - assistant ターンで `{` をプリフィルしJSON出力を即座に開始
    func buildChatMLPrompt(unclassifiedLines: [String], knownCompany: String) -> String {
        let rawText = unclassifiedLines.joined(separator: "\n")
        let knownHint = knownCompany.isEmpty ? "" : "\nKnown: company=\(knownCompany)"
        return "<|im_start|>system\nJSON only<|im_end|>\n<|im_start|>user\nBusiness card text. Extract: lastName,firstName,company,department,title. Empty string if unknown.\(knownHint)\n\n\(rawText)<|im_end|>\n<|im_start|>assistant\n/no_think\n{"
    }

    /// 旧API互換: 全行を渡すプロンプト（テスト用に残す）
    func buildChatMLPrompt(lines: [String]) -> String {
        let rawText = lines.joined(separator: "\n")
        return "<|im_start|>system\nJSON only<|im_end|>\n<|im_start|>user\nBusiness card text. Extract: lastName,firstName,company,department,title,phone,email,address,website. Empty string if unknown.\n\n\(rawText)<|im_end|>\n<|im_start|>assistant\n/no_think\n{"
    }

    // MARK: - JSON パース

    func parseJSON(_ text: String) -> CardFieldClassifier.ParsedCard? {
        let cleaned = text
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```",     with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard let start = cleaned.firstIndex(of: "{") else { return nil }
        let fromBrace = String(cleaned[start...])

        let jsonStr: String
        if let end = fromBrace.lastIndex(of: "}") {
            jsonStr = String(fromBrace[fromBrace.startIndex...end])
        } else {
            jsonStr = fromBrace + "}"
        }

        guard let data = jsonStr.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: String]
        else { return nil }

        var result = CardFieldClassifier.ParsedCard()
        result.lastName   = dict["lastName"]   ?? ""
        result.firstName  = dict["firstName"]  ?? ""
        result.company    = dict["company"]    ?? ""
        result.department = dict["department"] ?? ""
        result.title      = dict["title"]      ?? ""
        if let phone = dict["phone"], !phone.isEmpty { result.phones = [phone] }
        result.email      = dict["email"]      ?? ""
        result.address    = dict["address"]    ?? ""
        result.website    = dict["website"]    ?? ""
        return result
    }

    // MARK: - モデルダウンロード

    /// ユーザーの同意後に呼び出す。@Published プロパティで進捗を通知する。
    /// CloudKit Public Database からモデルファイルをダウンロードする。
    func downloadModel() async throws {
        await MainActor.run {
            isDownloading    = true
            downloadProgress = 0.0
        }
        defer { Task { @MainActor in self.isDownloading = false } }

        let dir = modelDirURL
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        // CloudKit からダウンロード（プログレスは MainActor で更新）
        try await CloudKitModelService.shared.downloadModel(
            modelDir: dir,
            tokenizerDestination: dir.appendingPathComponent("tokenizer.json")
        ) { [weak self] p in
            Task { @MainActor in self?.downloadProgress = p }
        }

        // ロード確認
        isModelAvailable = checkModelFiles()
        try loadModelIfNeeded()
        await MainActor.run { self.isModelAvailable = true }
    }

    // MARK: - モデル削除

    func deleteModel() throws {
        guard isModelAvailable else { return }
        // Application Support 内のモデルのみ削除（Documents 内は開発用なので残す）
        try? FileManager.default.removeItem(at: modelDirURL)
        prefillModel     = nil
        decodeModel      = nil
        tokenizer        = nil
        isModelAvailable = checkModelFiles()
    }

    // MARK: - モデルファイルサイズ

    var modelFileSize: Int64? {
        guard isModelAvailable else { return nil }
        let enumerator = FileManager.default.enumerator(
            at: activeModelDir,
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
