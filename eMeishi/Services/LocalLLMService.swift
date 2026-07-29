import Combine
import Foundation
import os

/// オンデバイスQwenのUI状態とモデル配布を管理するMainActorファサード。
/// Core MLモデル・tokenizer・推論状態はLocalLLMInferenceWorkerだけが所有する。
@MainActor
final class LocalLLMService: ObservableObject {
    static let shared = LocalLLMService()

    let maxContextLength = 512

    @Published var isModelAvailable = false
    @Published var isDownloading = false
    @Published var downloadProgress = 0.0
    @Published var isInferencing = false

    private let worker = LocalLLMInferenceWorker()
    private var inferenceCount = 0

    private let embedModelName = "qwen_embeddings.mlmodelc"
    private let ffnModelName = "qwen_FFN_PF_lut6_chunk_01of01.mlmodelc"
    private let lmheadModelName = "qwen_lm_head_lut6.mlmodelc"

    var modelDirURL: URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LocalLLM", isDirectory: true)
    }

    private var localModelDirURL: URL {
        FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LocalLLM", isDirectory: true)
    }

    private var activeModelDir: URL {
        let localEmbed = localModelDirURL.appendingPathComponent(embedModelName)
        return FileManager.default.fileExists(atPath: localEmbed.path)
            ? localModelDirURL
            : modelDirURL
    }

    private var activePaths: LocalLLMInferenceWorker.ModelPaths {
        LocalLLMInferenceWorker.ModelPaths(
            embed: activeModelDir.appendingPathComponent(embedModelName),
            ffn: activeModelDir.appendingPathComponent(ffnModelName),
            lmhead: activeModelDir.appendingPathComponent(lmheadModelName),
            tokenizer: activeModelDir.appendingPathComponent("tokenizer.json")
        )
    }

    var embedModelURL: URL { activePaths.embed }
    var ffnModelURL: URL { activePaths.ffn }
    var lmheadModelURL: URL { activePaths.lmhead }
    var tokenizerFileURL: URL { activePaths.tokenizer }
    var prefillModelURL: URL { embedModelURL }

    private init() {
        isModelAvailable = checkModelFiles()
    }

    func classifyUnclassifiedLines(_ lines: [String]) async -> CardFieldClassifier.ParsedCard? {
        guard isModelAvailable || checkModelFiles() else { return nil }
        isModelAvailable = true
        beginInference()
        defer { endInference() }

        let deadline = Date().addingTimeInterval(10)
        var result = CardFieldClassifier.ParsedCard()
        for line in lines {
            guard Date() <= deadline else { break }
            let prompt = classificationPrompt(line: line)
            guard let decoded = try? await worker.responseToken(for: prompt, paths: activePaths) else {
                continue
            }
            let value = decoded.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            if value.hasPrefix("n") || value.hasPrefix("名") || value.hasPrefix("person") {
                let split = splitJapaneseName(line)
                if result.lastName.isEmpty { result.lastName = split.lastName }
                if result.firstName.isEmpty { result.firstName = split.firstName }
            } else if value.hasPrefix("t") || value.hasPrefix("役") || value.hasPrefix("position") {
                if result.title.isEmpty { result.title = line.trimmingCharacters(in: .whitespaces) }
            } else if value.hasPrefix("d") || value.hasPrefix("部") || value.hasPrefix("sect") {
                if result.department.isEmpty { result.department = line.trimmingCharacters(in: .whitespaces) }
            } else if value.hasPrefix("c") || value.hasPrefix("会") || value.hasPrefix("org") {
                if result.company.isEmpty { result.company = line.trimmingCharacters(in: .whitespaces) }
            }
        }

        let hasContent = !result.lastName.isEmpty || !result.firstName.isEmpty
            || !result.title.isEmpty || !result.department.isEmpty || !result.company.isEmpty
        return hasContent ? result : nil
    }

    /// 曖昧な span を名刺全体の文脈付きで分類する。
    func resolveFields(request: CardFieldResolutionRequest) async -> [CardFieldDecision] {
        guard isModelAvailable || checkModelFiles() else { return [] }
        isModelAvailable = true
        beginInference()
        defer { endInference() }

        let deadline = Date().addingTimeInterval(10)
        let fullContext = request.spans
            .sorted { $0.readingOrder < $1.readingOrder }
            .map { "[\($0.id)] \($0.text)" }
            .joined(separator: "\n")
        let candidatesBySpan = Dictionary(grouping: request.candidates) { $0.spanIDs.first ?? "" }
        var decisions: [CardFieldDecision] = []

        for spanID in request.ambiguousSpanIDs.prefix(4) {
            guard Date() <= deadline, !Task.isCancelled,
                  let span = request.spans.first(where: { $0.id == spanID }) else { break }
            let allowed = Set(candidatesBySpan[spanID, default: []].map(\.field))
            guard !allowed.isEmpty else { continue }
            let prompt = contextualClassificationPrompt(
                target: span,
                fullContext: fullContext,
                allowed: allowed
            )
            guard let decoded = try? await worker.responseToken(for: prompt, paths: activePaths),
                  let field = fieldKind(from: decoded),
                  allowed.contains(field) else { continue }
            decisions.append(CardFieldDecision(spanID: spanID, field: field))
        }
        return decisions
    }

    /// タグ・AI検索・重複検出のyes/no判定を同じ推論キューへ直列化する。
    func yesNo(prompt: String) async -> Bool {
        guard isModelAvailable || checkModelFiles() else { return false }
        isModelAvailable = true
        beginInference()
        defer { endInference() }
        do {
            let token = try await worker.responseToken(for: prompt, paths: activePaths)
                .lowercased()
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return token.hasPrefix("y") || token.hasPrefix("はい") || token.hasPrefix("yes")
        } catch {
            AppLogger.llm.error("Qwen yes/no推論エラー: \(error)")
            return false
        }
    }

    func downloadModel() async throws {
        guard !isDownloading else { return }
        isDownloading = true
        downloadProgress = 0
        defer { isDownloading = false }

        let destination = modelDirURL
        let pathsAfterInstall = LocalLLMInferenceWorker.ModelPaths(
            embed: destination.appendingPathComponent(embedModelName),
            ffn: destination.appendingPathComponent(ffnModelName),
            lmhead: destination.appendingPathComponent(lmheadModelName),
            tokenizer: destination.appendingPathComponent("tokenizer.json")
        )
        do {
            try await worker.performModelUpdate(pathsAfterUpdate: pathsAfterInstall) {
                try await CloudKitModelService.shared.downloadModel(modelDir: destination) { progress in
                    LocalLLMService.shared.downloadProgress = progress
                }
            }
            isModelAvailable = checkModelFiles()
        } catch {
            isModelAvailable = checkModelFiles()
            throw error
        }
    }

    func deleteModel() async throws {
        try await worker.deleteModel(directory: modelDirURL)
        isModelAvailable = checkModelFiles()
    }

    var modelFileSize: Int64? {
        guard isModelAvailable else { return nil }
        let enumerator = FileManager.default.enumerator(
            at: activeModelDir,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        )
        var total: Int64 = 0
        while let fileURL = enumerator?.nextObject() as? URL {
            total += Int64((try? fileURL.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        }
        return total
    }

    private func checkModelFiles() -> Bool {
        let names = [embedModelName, ffnModelName, lmheadModelName, "tokenizer.json"]
        return [localModelDirURL, modelDirURL].contains { directory in
            names.allSatisfy { FileManager.default.fileExists(atPath: directory.appendingPathComponent($0).path) }
        }
    }

    private func beginInference() {
        inferenceCount += 1
        isInferencing = true
    }

    private func endInference() {
        inferenceCount = max(0, inferenceCount - 1)
        isInferencing = inferenceCount > 0
    }

    private func classificationPrompt(line: String) -> String {
        "<|im_start|>system\nClassify the business card field. Reply with exactly one word. A person's name is typically 2-6 kanji characters, often with a space between family and given name.<|im_end|>\n<|im_start|>user\nWhat type of field is this on a Japanese business card?\n\"\(line)\"\nOptions: name, title, department, company, address, other<|im_end|>\n<|im_start|>assistant\n/no_think\n"
    }

    private func contextualClassificationPrompt(
        target: CardTextSpan,
        fullContext: String,
        allowed: Set<CardFieldKind>
    ) -> String {
        let optionTokens = allowed.compactMap { field -> String? in
            switch field {
            case .personName: "N=name"
            case .company: "C=company"
            case .department: "D=department"
            case .title: "T=title"
            default: nil
            }
        }.sorted().joined(separator: ", ")
        return """
        <|im_start|>system
        Classify one target line on a Japanese business card using the entire card context. Reply with exactly one allowed letter.<|im_end|>
        <|im_start|>user
        Full card in reading order:
        \(fullContext)

        Target: [\(target.id)] \(target.text)
        Allowed: \(optionTokens)<|im_end|>
        <|im_start|>assistant
        /no_think
        """
    }

    private func fieldKind(from token: String) -> CardFieldKind? {
        let value = token.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("n") || value.hasPrefix("名") { return .personName }
        if value.hasPrefix("c") || value.hasPrefix("会") { return .company }
        if value.hasPrefix("d") || value.hasPrefix("部") { return .department }
        if value.hasPrefix("t") || value.hasPrefix("役") { return .title }
        return nil
    }

    private func splitJapaneseName(_ text: String) -> (lastName: String, firstName: String) {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        for separator in [" ", "\u{3000}"] {
            let parts = trimmed.split(separator: Character(separator), maxSplits: 1).map(String.init)
            if parts.count == 2 { return (parts[0], parts[1]) }
        }
        return (trimmed, "")
    }
}
