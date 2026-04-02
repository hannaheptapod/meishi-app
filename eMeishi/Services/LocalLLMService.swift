import Foundation
import CoreML
import Accelerate
import Combine
import os

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

    private(set) var prefillModel: MLModel? = nil
    private(set) var decodeModel:  MLModel? = nil
    private(set) var tokenizer:    Qwen25Tokenizer? = nil

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
        // .all だと ANE が int32 入力に対応できず CPU フォールバックで極端に遅い
        // .cpuAndGPU で GPU を優先的に使用し、int32 互換性を確保
        config.computeUnits = .cpuAndGPU

        if prefillModel == nil {
            prefillModel = try MLModel(contentsOf: prefillModelURL, configuration: config)
            let desc = prefillModel!.modelDescription
            AppLogger.llm.debug("Prefill inputs: \(desc.inputDescriptionsByName.keys.sorted(), privacy: .public)")
            AppLogger.llm.debug("Prefill outputs: \(desc.outputDescriptionsByName.keys.sorted(), privacy: .public)")
            AppLogger.llm.info("Prefill モデルロード完了 (cpuAndGPU)")
        }
        if decodeModel == nil {
            decodeModel = try MLModel(contentsOf: decodeModelURL, configuration: config)
            let desc = decodeModel!.modelDescription
            AppLogger.llm.debug("Decode inputs: \(desc.inputDescriptionsByName.keys.sorted(), privacy: .public)")
            AppLogger.llm.debug("Decode outputs: \(desc.outputDescriptionsByName.keys.sorted(), privacy: .public)")
            AppLogger.llm.info("Decode モデルロード完了 (cpuAndGPU)")
        }
        if tokenizer == nil {
            tokenizer = try Qwen25Tokenizer(url: tokenizerFileURL)
        }
    }

    // MARK: - モデルロード（公開ヘルパー）

    /// モデルをロードし、利用可能なら (prefillModel, tokenizer) を返す。
    /// 利用不可の場合は nil を返す。
    func ensureModelLoaded() -> (prefill: MLModel, tokenizer: Qwen25Tokenizer)? {
        if prefillModel == nil || tokenizer == nil {
            isModelAvailable = checkModelFiles()
            do {
                try loadModelIfNeeded()
            } catch {
                AppLogger.llm.error("モデルロードエラー: \(error)")
            }
        }
        guard let pModel = prefillModel, let tok = tokenizer else { return nil }
        return (pModel, tok)
    }

    // MARK: - 推論（公開API）

    /// 未分類行のみをLLMで分類する。
    /// ルールベース前段処理は呼び出し元（CardFormViewModel）で実施済み。
    /// モデル未ロード・推論失敗時は nil を返す。
    ///
    /// 推論方式: 単一パス分類（1行1回の forward pass でカテゴリ判定）
    /// - 自動回帰生成を完全廃止（KVキャッシュなしモデルでは O(n²) で破綻するため）
    /// - 未分類行数 × 1回の forward pass のみ（通常2-4回）
    func classifyUnclassifiedLines(_ lines: [String]) async -> CardFieldClassifier.ParsedCard? {
        // アプリ再起動後に未ロードの場合はここでロードする
        if prefillModel == nil || decodeModel == nil || tokenizer == nil {
            await MainActor.run { isInferencing = true }
            // モデルファイルの存在を再チェック（Finder で追加された場合に対応）
            isModelAvailable = checkModelFiles()
            do {
                try loadModelIfNeeded()
            } catch {
                AppLogger.llm.error("モデルロードエラー: \(error)")
            }
        }
        guard let pModel = prefillModel, let dModel = decodeModel, let tok = tokenizer else {
            await MainActor.run { isInferencing = false }
            AppLogger.llm.warning("モデル未ロード（prefill=\(self.prefillModel != nil, privacy: .public), decode=\(self.decodeModel != nil, privacy: .public), tok=\(self.tokenizer != nil, privacy: .public)）")
            return nil
        }

        await MainActor.run { isInferencing = true }
        defer { Task { @MainActor in self.isInferencing = false } }

        let timeoutSeconds: TimeInterval = 10
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        let startTime = Date()

        AppLogger.llm.info("単一パス分類開始。未分類行: \(lines.count, privacy: .public)行")

        do {
            let llmResult = try classifyByLine(
                prefillModel: pModel, decodeModel: dModel,
                tokenizer: tok,
                lines: lines,
                deadline: deadline
            )
            let elapsed = Date().timeIntervalSince(startTime)
            AppLogger.llm.info("分類完了。\(String(format: "%.1f", elapsed), privacy: .public)秒")

            let llmHasContent = !llmResult.lastName.isEmpty || !llmResult.firstName.isEmpty
                || !llmResult.title.isEmpty || !llmResult.department.isEmpty
                || !llmResult.company.isEmpty
            if !llmHasContent {
                AppLogger.llm.info("LLM結果が空")
                return nil
            }
            return llmResult
        } catch InferenceError.timeout {
            let elapsed = Date().timeIntervalSince(startTime)
            AppLogger.llm.warning("分類タイムアウト（\(String(format: "%.1f", elapsed), privacy: .public)秒）")
            return nil
        } catch {
            AppLogger.llm.error("分類エラー: \(error)")
            return nil
        }
    }

    // MARK: - 単一パス分類（自動回帰生成を廃止）

    /// 各未分類行に対して1回の forward pass でカテゴリ（名前/役職/部署/会社）を判定。
    ///
    /// 自動回帰生成（15ステップ × 全シーケンス再処理 = O(n²)）を完全廃止し、
    /// 行数分の単一 forward pass（各 ~25トークン）のみで分類する。
    ///
    /// 計算量: O(行数 × プロンプト長) ≈ O(3 × 25) = 75トークン相当
    /// 旧方式: O(15 × (60+15)/2) ≈ O(562) トークン相当（7.5倍の削減）
    private enum LineCategory: String {
        case name, title, department, company, unknown
    }

    private func classifyByLine(prefillModel: MLModel,
                                decodeModel: MLModel,
                                tokenizer: Qwen25Tokenizer,
                                lines: [String],
                                deadline: Date) throws -> CardFieldClassifier.ParsedCard {
        var result = CardFieldClassifier.ParsedCard()

        // Prefill モデルを使用（causalMask 付きで正しいアテンション保証）
        // Decode モデルは causalMask なしで全行 '!' を返す問題があるため不使用

        for (i, line) in lines.enumerated() {
            if Date() > deadline { throw InferenceError.timeout }

            // 分類用プロンプト
            let prompt = buildClassificationPrompt(line: line)
            let ids = tokenizer.encode(prompt)

            let stepStart = CFAbsoluteTimeGetCurrent()
            let logits = try forwardPrefill(model: prefillModel, ids: ids, seqLen: ids.count)
            let stepMs = (CFAbsoluteTimeGetCurrent() - stepStart) * 1000

            guard let tokenId = argmaxLastToken(logits: logits) else {
                AppLogger.llm.debug("行\(i+1, privacy: .public) [Pre] \(String(format: "%.0f", stepMs), privacy: .public)ms: argmax失敗 \(line, privacy: .private)")
                continue
            }
            let decoded = tokenizer.decode([tokenId]).lowercased()
                .trimmingCharacters(in: .whitespacesAndNewlines)

            // カテゴリ判定: 先頭文字 + 日本語キーワードの両方に対応
            let category: LineCategory
            if decoded.hasPrefix("n") || decoded.hasPrefix("名") || decoded.hasPrefix("person") { category = .name }
            else if decoded.hasPrefix("t") || decoded.hasPrefix("役") || decoded.hasPrefix("position") { category = .title }
            else if decoded.hasPrefix("d") || decoded.hasPrefix("部") || decoded.hasPrefix("sect") { category = .department }
            else if decoded.hasPrefix("c") || decoded.hasPrefix("会") || decoded.hasPrefix("org") { category = .company }
            else if decoded.hasPrefix("a") || decoded.hasPrefix("住") || decoded.hasPrefix("addr") { category = .unknown } // 住所はルールベースが処理済みのはず
            else { category = .unknown }

            AppLogger.llm.debug("行\(i+1, privacy: .public) [Pre] \(String(format: "%.0f", stepMs), privacy: .public)ms (\(ids.count, privacy: .public)tok): \(line, privacy: .private) → \(category.rawValue, privacy: .public) (token=\(decoded, privacy: .public) id=\(tokenId, privacy: .public))")

            switch category {
            case .name:
                let (last, first) = splitJapaneseName(line)
                if result.lastName.isEmpty { result.lastName = last }
                if result.firstName.isEmpty { result.firstName = first }
            case .title:
                if result.title.isEmpty { result.title = line.trimmingCharacters(in: .whitespaces) }
            case .department:
                if result.department.isEmpty { result.department = line.trimmingCharacters(in: .whitespaces) }
            case .company:
                if result.company.isEmpty { result.company = line.trimmingCharacters(in: .whitespaces) }
            case .unknown:
                // unknown はスキップ（ルールベースが既に名前・住所等を検出済み）
                // LLM が分類できなかった行を名前として扱うと正しい結果を壊す
                break
            }
        }

        return result
    }

    /// 分類用 ChatML プロンプト
    /// Qwen3 に1行のカテゴリを1トークンで回答させる
    /// /no_think で思考モード無効化し、選択肢を明示してトークン制約する
    private func buildClassificationPrompt(line: String) -> String {
        return "<|im_start|>system\nClassify the business card field. Reply with exactly one word. A person's name is typically 2-6 kanji characters, often with a space between family and given name.<|im_end|>\n<|im_start|>user\nWhat type of field is this on a Japanese business card?\n\"\(line)\"\nOptions: name, title, department, company, address, other<|im_end|>\n<|im_start|>assistant\n/no_think\n"
    }

    /// 日本語名を姓・名に分割（スペース区切り、日本の慣習で姓が先）
    private func splitJapaneseName(_ text: String) -> (lastName: String, firstName: String) {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        // 半角スペースで分割
        let parts = trimmed.split(separator: " ", maxSplits: 1).map(String.init)
        if parts.count >= 2 { return (parts[0], parts[1]) }
        // 全角スペースで分割
        let fwParts = trimmed.split(separator: "\u{3000}", maxSplits: 1).map(String.init)
        if fwParts.count >= 2 { return (fwParts[0], fwParts[1]) }
        // 分割不能 → 全体を姓に
        return (trimmed, "")
    }

    // MARK: - 自動回帰生成（レガシー・単一パス分類が失敗した場合の保険）

    private let maxContextLength = 1024

    // MARK: - Forward Pass（Prefill）

    /// Prefill モデルの forward pass（プロンプト全体を一括処理）
    /// 入力: inputIds [1, seqLen] + causalMask [1, 1, seqLen, 1024]
    /// 出力: logits [1, 1, 151936]
    func forwardPrefill(model: MLModel, ids: [Int], seqLen: Int) throws -> MLMultiArray {
        let inputArray = try MLMultiArray(shape: [1, NSNumber(value: seqLen)], dataType: .int32)
        // NSNumber 変換を回避して直接ポインタ書き込み
        let ptr = inputArray.dataPointer.assumingMemoryBound(to: Int32.self)
        for (i, id) in ids.enumerated() { ptr[i] = Int32(id) }

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
        let ptr = inputArray.dataPointer.assumingMemoryBound(to: Int32.self)
        for (i, id) in ids.enumerated() { ptr[i] = Int32(id) }

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
    /// 0.0 = 参照可、-30000.0 = マスク（-inf の代替）
    /// Accelerate (vDSP) でバルク充填しループコストを削減
    func buildCausalMask(queryLen: Int, keyLen: Int) throws -> MLMultiArray {
        let shape: [NSNumber] = [1, 1, NSNumber(value: queryLen), NSNumber(value: keyLen)]
        let mask = try MLMultiArray(shape: shape, dataType: .float16)

        // Float16 ポインタで直接書き込み（NSNumber 変換を回避）
        let ptr = mask.dataPointer.assumingMemoryBound(to: UInt16.self)
        let allowBits: UInt16 = 0x0000        // Float16: 0.0
        let blockBits: UInt16 = 0xF753        // Float16: -30000.0

        // まず全体を blockVal で埋める
        let totalElements = queryLen * keyLen
        ptr.initialize(repeating: blockBits, count: totalElements)

        // causal 部分（下三角）を allowVal で上書き
        for i in 0 ..< queryLen {
            let absI = keyLen - queryLen + i
            let rowStart = i * keyLen
            // 0 ... absI を allow に設定
            let allowCount = absI + 1
            if allowCount > 0 {
                let rowPtr = ptr.advanced(by: rowStart)
                rowPtr.initialize(repeating: allowBits, count: min(allowCount, keyLen))
            }
        }
        return mask
    }

    enum InferenceError: Error { case noLogits, timeout }

    // MARK: - Argmax・float16変換

    /// ロジット配列の最後のトークン位置で argmax を取り、最大値のインデックスを返す
    /// Prefill: [1, 1, 151936]、Decode: スカラーまたは [vocab] 等の可変形状に対応
    func argmaxLastToken(logits: MLMultiArray) -> Int? {
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
    /// - プロンプトの各トークンが全デコードステップの計算量に影響するため極限まで短縮
    /// - Qwen3 の思考モード無効化（/no_think）
    /// - assistant ターンで `{"lastName":"` までプリフィルし生成トークン数を最小化
    ///
    /// 設計意図: KVキャッシュなしモデルでは各デコードステップで全トークンを再処理する
    /// → プロンプト10トークン短縮 × 15ステップ = 150トークン分の計算削減
    /// → プリフィル3トークン追加 = デコードステップ3回分の完全削減
    let jsonPrefill = "{\"lastName\":\""

    func buildChatMLPrompt(unclassifiedLines: [String], knownCompany: String) -> String {
        let rawText = unclassifiedLines.joined(separator: "\n")
        let hint = knownCompany.isEmpty ? "" : " company=\(knownCompany)"
        return "<|im_start|>system\nJSON<|im_end|>\n<|im_start|>user\nCard:\n\(rawText)\nGet:lastName,firstName,title,department\(hint)<|im_end|>\n<|im_start|>assistant\n/no_think\n\(jsonPrefill)"
    }

    /// 旧API互換: 全行を渡すプロンプト（テスト用に残す）
    func buildChatMLPrompt(lines: [String]) -> String {
        let rawText = lines.joined(separator: "\n")
        return "<|im_start|>system\nJSON<|im_end|>\n<|im_start|>user\nCard:\n\(rawText)\nGet:lastName,firstName,company,department,title,phone,email,address,website<|im_end|>\n<|im_start|>assistant\n/no_think\n\(jsonPrefill)"
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
