import Foundation
import CoreData
import Combine
import UIKit
import os
#if canImport(FoundationModels)
import FoundationModels
#endif

nonisolated struct CardFormPhoneField: Identifiable, Equatable, Sendable {
    let id: UUID
    var value: String

    init(id: UUID = UUID(), value: String) {
        self.id = id
        self.value = value
    }
}

// 名刺の新規作成・編集フォームのViewModel
@MainActor
class CardFormViewModel: ObservableObject {

    @Published var lastName: String = ""
    @Published var lastNameReading: String = "" {
        didSet { markReadingEdited(.lastName) }
    }
    @Published var firstName: String = ""
    @Published var firstNameReading: String = "" {
        didSet { markReadingEdited(.firstName) }
    }
    @Published var company: String = ""
    @Published var companyReading: String = "" {
        didSet { markReadingEdited(.company) }
    }
    @Published var department: String = ""
    @Published var title: String = ""
    @Published var email: String = ""
    @Published var phoneFields: [CardFormPhoneField] = [CardFormPhoneField(value: "")]
    @Published var address: String = ""
    @Published var website: String = ""
    @Published var notes: String = ""
    @Published var selectedTags: Set<UUID> = []
    @Published var suggestedTagIDs: Set<UUID> = []
    @Published var isLoadingTagSuggestions: Bool = false
    @Published private(set) var readingCandidates: [ReadingCandidate] = []

    // OCR処理中フラグ・エラーメッセージ
    @Published var isProcessingOCR: Bool = false
    @Published var ocrStage: String = "名刺を読み取り中..."
    @Published var ocrErrorMessage: String? = nil
    @Published var saveErrorMessage: String? = nil
    @Published var ocrProcessingState: OCRProcessingState = .idle
    @Published var canContinueOCRInBackground = false
    @Published private(set) var isLoadingEditSnapshot = false
    @Published private(set) var editLoadErrorMessage: String?
    @Published private(set) var isSaving = false

    // モデル未取得時にダウンロード同意アラートを表示するフラグ
    @Published var shouldPromptLLMDownload: Bool = false

    // 撮影した名刺画像（保存用）
    @Published private(set) var capturedImageData: Data? = nil {
        didSet {
            capturedImageRevision = UUID()
            if isEditing, !isApplyingEditSnapshot {
                didChangeCapturedImage = true
            }
        }
    }
    @Published private(set) var capturedImageRevision = UUID()

    /// 永続化形式は従来どおり文字列配列のまま維持し、フォーム上の行IDだけを分離する。
    var phones: [String] {
        get { phoneFields.map(\.value) }
        set {
            let normalized = newValue.isEmpty ? [""] : newValue
            phoneFields = normalized.enumerated().map { index, value in
                if phoneFields.indices.contains(index) {
                    return CardFormPhoneField(id: phoneFields[index].id, value: value)
                }
                return CardFormPhoneField(value: value)
            }
        }
    }

    // 編集中かどうかを外部から確認できるように公開
    var isEditing: Bool { editReference != nil }
    var needsEditSnapshotLoad: Bool {
        isEditing && editGeneration == nil && editLoadErrorMessage == nil
    }

    private let context: NSManagedObjectContext
    private let coordinatorReference: PersistentStoreCoordinatorReference
    private let editReference: CardFormEditReference?
    private let persistenceWorker: CardFormPersistenceWorker
    private var editGeneration: CardFormEditGeneration?
    private let ocrService: OCRServiceProtocol
    private let classifier: CardFieldClassifierProtocol
    private let llmService: LocalLLMServiceProtocol
    private let autoTagService: AutoTagServiceProtocol
    private let settings: SettingsProviding
    private(set) var ocrJobID = OCRJobID()
    private var ocrTask: Task<Void, Never>?
    private var etaTickerTask: Task<Void, Never>?
    private var tagSuggestionTask: Task<Void, Never>?
    private var ocrCancellationTask: Task<Void, Never>?
    private var ocrCancellationGeneration = UUID()
    private var tagSuggestionGeneration = UUID()
    private var isApplyingReadingResolution = false
    private var isApplyingEditSnapshot = false
    private var didChangeCapturedImage = false
    private var editedReadingTargets = Set<ReadingTarget>()

    deinit {
        ocrTask?.cancel()
        etaTickerTask?.cancel()
        tagSuggestionTask?.cancel()
        ocrCancellationTask?.cancel()
    }

    func appendPhoneField() {
        phoneFields.append(CardFormPhoneField(value: ""))
    }

    func removePhoneField(id: UUID) {
        guard phoneFields.count > 1 else { return }
        phoneFields.removeAll { $0.id == id }
        if phoneFields.isEmpty {
            phoneFields = [CardFormPhoneField(value: "")]
        }
    }

    /// OCRを開始せずに、既に正規化済みの画像をフォームへ設定する。
    /// スクリーンショット用の合成フォームなど、準備済み入力の生成経路で使用する。
    func setPreparedImageData(_ data: Data?) {
        capturedImageData = data
    }

    // MARK: - 初期化（新規作成）

    // デフォルト引数式は nonisolated で評価されるため @MainActor シングルトンを直接参照できない。
    // ? = nil にして @MainActor な init 本体内で解決する。
    init(context: NSManagedObjectContext? = nil,
         ocrService: OCRServiceProtocol? = nil,
         classifier: CardFieldClassifierProtocol? = nil,
         llmService: LocalLLMServiceProtocol? = nil,
         autoTagService: AutoTagServiceProtocol? = nil,
         settings: SettingsProviding? = nil) {
        let resolvedContext = context ?? PersistenceController.shared.container.viewContext
        self.context = resolvedContext
        self.coordinatorReference = Self.makeCoordinatorReference(for: resolvedContext)
        self.editReference = nil
        self.persistenceWorker = CardFormPersistenceWorker()
        self.ocrService   = ocrService   ?? OCRService()
        self.classifier   = classifier   ?? CardFieldClassifier()
        self.llmService   = llmService   ?? LocalLLMService.shared
        self.autoTagService = autoTagService ?? AutoTagService.shared
        self.settings     = settings     ?? SettingsStore.shared
    }

    // MARK: - 初期化（正規化済みDataからOCR）

    /// 写真取込み・カメラ・未完了キューで共通利用する初期化経路。
    /// 保存用Dataは既に向き補正・外周補正・圧縮済みのため、そのまま保持する。
    /// OCR用UIImageの展開だけを画像処理actorへ委譲し、MainActorでは再圧縮しない。
    init(normalizedImageData: Data,
         context: NSManagedObjectContext? = nil,
         ocrService: OCRServiceProtocol? = nil,
         classifier: CardFieldClassifierProtocol? = nil,
         llmService: LocalLLMServiceProtocol? = nil,
         autoTagService: AutoTagServiceProtocol? = nil,
         settings: SettingsProviding? = nil) {
        let resolvedContext = context ?? PersistenceController.shared.container.viewContext
        self.context = resolvedContext
        self.coordinatorReference = Self.makeCoordinatorReference(for: resolvedContext)
        self.editReference = nil
        self.persistenceWorker = CardFormPersistenceWorker()
        self.ocrService   = ocrService   ?? OCRService()
        self.classifier   = classifier   ?? CardFieldClassifier()
        self.llmService   = llmService   ?? LocalLLMService.shared
        self.autoTagService = autoTagService ?? AutoTagService.shared
        self.settings     = settings     ?? SettingsStore.shared
        self.capturedImageData = normalizedImageData
        self.isProcessingOCR = true
        ocrTask = Task { [weak self] in
            guard let self, !Task.isCancelled else { return }
            do {
                let decoded = try await CardImageProcessingService.shared
                    .decodeNormalizedImage(from: normalizedImageData)
                try Task.checkCancellation()
                let image = decoded.image
                try await self.beginOCRProcessing(image: image)
                try await self.setOCRPhase(.textRecognition)
                await self.populateFromOCR(image: image)
            } catch is CancellationError {
                await self.finishCancelledOCR()
                self.isProcessingOCR = false
            } catch {
                await self.finishOCRFailure(message: error.localizedDescription)
            }
        }
    }

    // MARK: - 初期化（既存カードの編集）

    init(card: BusinessCard,
         context: NSManagedObjectContext? = nil,
         ocrService: OCRServiceProtocol? = nil,
         classifier: CardFieldClassifierProtocol? = nil,
         llmService: LocalLLMServiceProtocol? = nil,
         autoTagService: AutoTagServiceProtocol? = nil,
         settings: SettingsProviding? = nil) {
        let resolvedContext = context ?? card.managedObjectContext
            ?? PersistenceController.shared.container.viewContext
        self.context = resolvedContext
        self.coordinatorReference = Self.makeCoordinatorReference(for: resolvedContext)
        self.editReference = CardFormEditReference(
            objectURI: card.objectID.uriRepresentation()
        )
        self.persistenceWorker = CardFormPersistenceWorker()
        self.ocrService   = ocrService   ?? OCRService()
        self.classifier   = classifier   ?? CardFieldClassifier()
        self.llmService   = llmService   ?? LocalLLMService.shared
        self.autoTagService = autoTagService ?? AutoTagService.shared
        self.settings     = settings     ?? SettingsStore.shared
        isLoadingEditSnapshot = true
    }

    private static func makeCoordinatorReference(
        for context: NSManagedObjectContext
    ) -> PersistentStoreCoordinatorReference {
        if let coordinator = context.persistentStoreCoordinator
            ?? context.parent?.persistentStoreCoordinator {
            return PersistentStoreCoordinatorReference(coordinator: coordinator)
        }
        preconditionFailure("CardFormViewModel requires a context connected to a persistent store")
    }

    // MARK: - 編集スナップショット

    /// Viewが所有するTaskから呼び出し、結果の適用前にView側で世代を照合する。
    /// 読込み中はフォーム本体を表示せず、MainActor上で個別フィールドをfaultさせない。
    func beginEditSnapshotLoading() {
        guard isEditing, editGeneration == nil else { return }
        isLoadingEditSnapshot = true
        editLoadErrorMessage = nil
    }

    func loadEditSnapshot() async throws -> CardFormEditSnapshot {
        guard let editReference else {
            throw CardFormPersistenceError.invalidObjectReference
        }
        return try await persistenceWorker.loadEditSnapshot(
            reference: editReference,
            coordinatorReference: coordinatorReference
        )
    }

    /// 全項目をloading shellの背後で設定し、最後に一度だけフォーム表示へ切り替える。
    func applyEditSnapshot(_ snapshot: CardFormEditSnapshot) {
        guard editReference?.objectURI == snapshot.generation.objectURI else { return }
        isApplyingEditSnapshot = true
        isApplyingReadingResolution = true

        lastName = snapshot.lastName
        lastNameReading = snapshot.lastNameReading
        firstName = snapshot.firstName
        firstNameReading = snapshot.firstNameReading
        company = snapshot.company
        companyReading = snapshot.companyReading
        department = snapshot.department
        title = snapshot.title
        email = snapshot.email
        phones = snapshot.phones
        address = snapshot.address
        website = snapshot.website
        notes = snapshot.notes
        selectedTags = snapshot.selectedTagIDs
        capturedImageData = snapshot.imageData

        editGeneration = snapshot.generation
        didChangeCapturedImage = false
        editedReadingTargets.removeAll()
        isApplyingReadingResolution = false
        isApplyingEditSnapshot = false
        editLoadErrorMessage = nil
        isLoadingEditSnapshot = false
    }

    func cancelEditSnapshotLoading() {
        if editGeneration == nil {
            isLoadingEditSnapshot = false
        }
    }

    func finishEditSnapshotLoading(with error: Error) {
        guard editGeneration == nil else { return }
        isLoadingEditSnapshot = false
        editLoadErrorMessage = error.localizedDescription
    }

    // MARK: - OCR + AI意味分析

    func populateFromOCR(image: UIImage) async {
        isProcessingOCR = true
        ocrErrorMessage = nil
        var didFail = false

        do {
            if ocrProcessingState == .idle {
                try await beginOCRProcessing(image: image)
                try await setOCRPhase(.textRecognition)
            }
            let lines = try await ocrService.recognizeText(from: image)
            try Task.checkCancellation()
            guard !lines.isEmpty else {
                await finishOCRFailure(message: "テキストを認識できませんでした")
                return
            }

            await updateRecognitionWorkload(lines)
            try await setOCRPhase(.fieldAnalysis)

            switch settings.readingMethod {
            case .automatic:
                #if canImport(FoundationModels)
                if #available(iOS 26.0, *) {
                    try await populateWithFoundationModels(lines: lines)
                } else {
                    try await populateWithLocalLLMOrClassifier(lines: lines)
                }
                #else
                try await populateWithLocalLLMOrClassifier(lines: lines)
                #endif
            case .appleIntelligence:
                #if canImport(FoundationModels)
                if #available(iOS 26.0, *) {
                    try await populateWithFoundationModelsOnly(lines: lines)
                } else {
                    ocrErrorMessage = "Apple Intelligence は iOS 26 以降で利用できます。標準読み取りで処理しました。"
                    try await runUnifiedPipeline(lines: lines, llmBackend: .none)
                }
                #else
                ocrErrorMessage = "Apple Intelligence は現在利用できません。標準読み取りで処理しました。"
                try await runUnifiedPipeline(lines: lines, llmBackend: .none)
                #endif
            case .localLLM:
                ocrStage = "AIモデルで分析中..."
                try await populateWithLocalLLMOnly(lines: lines)
            }
            try Task.checkCancellation()

            guard hasAnyResolvedField else {
                await finishOCRFailure(message: "名刺の項目を判別できませんでした。画像を確認して再試行してください。")
                return
            }

            try await setOCRPhase(.saving)
            try Task.checkCancellation()
            guard let completed = await OCRProcessingCoordinator.shared.complete(jobID: ocrJobID) else {
                throw CancellationError()
            }
            ocrProcessingState = completed
            OCRBackgroundTaskManager.shared.update(jobID: ocrJobID, state: completed)
            OCRBackgroundTaskManager.shared.finish(jobID: ocrJobID, success: true)
            canContinueOCRInBackground = false
            isProcessingOCR = false
            stopETATicker()

            // 完了した同一ジョブだけがAIタグ提案を開始できる。
            requestTagSuggestions()
        } catch is CancellationError {
            didFail = true
            await finishCancelledOCR()
        } catch {
            didFail = true
            await finishOCRFailure(message: "OCR処理に失敗しました: \(error.localizedDescription)")
        }

        if didFail { isProcessingOCR = false }
    }

    private func finishOCRFailure(message: String) async {
        // Vision/Core MLなどキャンセル非協調の処理は、停止後に通常Errorを返す場合がある。
        // Coordinatorの終端状態を正とし、キャンセル済みジョブをfailedへ戻さない。
        if await isOCRJobCancelled() {
            await finishCancelledOCR()
            return
        }

        guard let failed = await OCRProcessingCoordinator.shared.fail(jobID: ocrJobID, message: message) else {
            // 別の終端遷移が先行した場合も、遅れて届いたErrorで表示状態を上書きしない。
            if let terminal = await OCRProcessingCoordinator.shared.currentState(jobID: ocrJobID) {
                ocrProcessingState = terminal
                switch terminal.phase {
                case .failed:
                    ocrErrorMessage = terminal.errorMessage
                case .cancelled, .completed:
                    ocrErrorMessage = nil
                default:
                    break
                }
            }
            isProcessingOCR = false
            canContinueOCRInBackground = false
            stopETATicker()
            return
        }

        ocrErrorMessage = message
        isProcessingOCR = false
        ocrProcessingState = failed
        OCRBackgroundTaskManager.shared.update(jobID: ocrJobID, state: failed)
        OCRBackgroundTaskManager.shared.finish(jobID: ocrJobID, success: false)
        canContinueOCRInBackground = false
        stopETATicker()
    }

    func cancelOCR() {
        _ = beginOCRCancellation()
    }

    /// バッチのスキップ時は旧OCRの終了完了後に次の名刺へ進み、
    /// 旧Live Activityの残留や新しいOCRへの終了処理の競合を防ぐ。
    func cancelOCRAndWait() async {
        await beginOCRCancellation().value
    }

    @discardableResult
    private func beginOCRCancellation() -> Task<Void, Never> {
        if let ocrCancellationTask {
            return ocrCancellationTask
        }
        let generation = UUID()
        ocrCancellationGeneration = generation
        let task = Task { [weak self] in
            guard let self else { return }
            await self.performOCRCancellation()
            guard self.ocrCancellationGeneration == generation else { return }
            self.ocrCancellationTask = nil
        }
        ocrCancellationTask = task
        return task
    }

    private func performOCRCancellation() async {
        let task = ocrTask
        task?.cancel()
        isProcessingOCR = false

        // キャンセル非対応の処理が残っていても、表示は即時終了する。
        await finishCancelledOCR()

        // 旧タスクが完全に終了するまで、新しいバッチ項目を開始させない。
        await task?.value
        ocrTask = nil

        // 旧タスクの終了処理が状態を書き戻した場合にも最終状態を揃える。
        await finishCancelledOCR()
    }

    private func finishCancelledOCR() async {
        ocrErrorMessage = nil
        isProcessingOCR = false
        if let cancelled = await OCRProcessingCoordinator.shared.cancel(jobID: ocrJobID) {
            ocrProcessingState = cancelled
            OCRBackgroundTaskManager.shared.update(jobID: ocrJobID, state: cancelled)
        }
        OCRBackgroundTaskManager.shared.finish(jobID: ocrJobID, success: false)
        canContinueOCRInBackground = false
        stopETATicker()
    }

    private func isOCRJobCancelled() async -> Bool {
        if Task.isCancelled { return true }
        return await OCRProcessingCoordinator.shared.currentState(jobID: ocrJobID)?.phase == .cancelled
    }

    private func beginOCRProcessing(image: UIImage) async throws {
        try Task.checkCancellation()
        let started = await OCRProcessingCoordinator.shared.start(
            jobID: ocrJobID,
            totalItems: 1,
            workload: makeInitialWorkload(image: image)
        )
        guard !started.phase.isTerminal else { throw CancellationError() }
        ocrProcessingState = started
        ocrStage = ocrProcessingState.phase.title
        canContinueOCRInBackground = OCRBackgroundTaskManager.shared.begin(jobID: ocrJobID, totalItems: 1) { [weak self] in
            self?.cancelOCR()
        }
        OCRBackgroundTaskManager.shared.update(jobID: ocrJobID, state: ocrProcessingState)
        startETATicker()
#if DEBUG
        try await OCRProcessingCoordinator.shared.waitForConfiguredTestDelay(jobID: ocrJobID)
#endif
        try Task.checkCancellation()
    }

    private func setOCRPhase(_ phase: OCRProcessingPhase) async throws {
        try Task.checkCancellation()
        guard let state = await OCRProcessingCoordinator.shared.transition(jobID: ocrJobID, to: phase) else {
            throw CancellationError()
        }
        ocrProcessingState = state
        ocrStage = phase.title
        OCRBackgroundTaskManager.shared.update(jobID: ocrJobID, state: state)
#if DEBUG
        try await OCRProcessingCoordinator.shared.waitForConfiguredTestDelay(jobID: ocrJobID)
#endif
        try Task.checkCancellation()
    }

    private func updateImageWorkload(_ image: UIImage) async {
        let metrics = Self.imageMetrics(image: image, data: capturedImageData)
        if let state = await OCRProcessingCoordinator.shared.updateImageMetrics(
            jobID: ocrJobID,
            megapixels: metrics.megapixels,
            megabytes: metrics.megabytes
        ) {
            ocrProcessingState = state
            OCRBackgroundTaskManager.shared.update(jobID: ocrJobID, state: state)
        }
    }

    private func updateRecognitionWorkload(_ lines: [RecognizedLine]) async {
        let characterCount = lines.reduce(0) { $0 + $1.text.count }
        if let state = await OCRProcessingCoordinator.shared.updateRecognitionMetrics(
            jobID: ocrJobID,
            lineCount: lines.count,
            characterCount: characterCount
        ) {
            ocrProcessingState = state
            OCRBackgroundTaskManager.shared.update(jobID: ocrJobID, state: state)
        }
    }

    private func startETATicker() {
        etaTickerTask?.cancel()
        let jobID = ocrJobID
        etaTickerTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled,
                      let self,
                      self.isProcessingOCR,
                      self.ocrJobID == jobID,
                      let state = await OCRProcessingCoordinator.shared.refreshEstimate(jobID: jobID) else {
                    return
                }
                self.ocrProcessingState = state
                OCRBackgroundTaskManager.shared.update(jobID: jobID, state: state)
            }
        }
    }

    private func stopETATicker() {
        etaTickerTask?.cancel()
        etaTickerTask = nil
    }

    private func makeInitialWorkload(image: UIImage) -> OCRProcessingWorkload {
        let metrics = Self.imageMetrics(image: image, data: capturedImageData)
        let backend = expectedAIBackend
        return OCRProcessingWorkload(
            imageMegapixels: metrics.megapixels,
            imageMegabytes: metrics.megabytes,
            recognizedLineCount: 0,
            recognizedCharacterCount: 0,
            ambiguousSpanCount: 0,
            aiInputTokenEstimate: 0,
            aiOutputTokenEstimate: 0,
            aiBackend: backend,
            aiRequired: backend == .none ? false : nil
        )
    }

    private static func imageMetrics(image: UIImage, data: Data?) -> (megapixels: Double, megabytes: Double) {
        let pixelWidth = Double(image.cgImage?.width ?? Int(image.size.width * image.scale))
        let pixelHeight = Double(image.cgImage?.height ?? Int(image.size.height * image.scale))
        return (
            megapixels: max(0.01, pixelWidth * pixelHeight / 1_000_000),
            megabytes: Double(data?.count ?? 0) / 1_048_576
        )
    }

    private var expectedAIBackend: OCRAIWorkloadBackend {
        switch settings.readingMethod {
        case .automatic:
            #if canImport(FoundationModels)
            if #available(iOS 26.0, *), case .available = SystemLanguageModel.default.availability {
                return .foundationModels
            }
            #endif
            return llmService.isModelAvailable ? .localLLM : .none
        case .appleIntelligence:
            #if canImport(FoundationModels)
            if #available(iOS 26.0, *), case .available = SystemLanguageModel.default.availability {
                return .foundationModels
            }
            #endif
            return .none
        case .localLLM:
            return llmService.isModelAvailable ? .localLLM : .none
        }
    }

    // MARK: - AIタグ提案

    /// OCR完了後に既存タグから該当するものをAIで提案する
    func requestTagSuggestions() {
        guard ocrProcessingState.phase != .cancelled,
              ocrProcessingState.phase != .failed else { return }
        // 既にタグが選択されている場合（編集時）はスキップ
        guard !isEditing, selectedTags.isEmpty else { return }

        let cardInfo = AutoTagService.CardInfo(
            company: company,
            department: department,
            title: title,
            address: address,
            email: email,
            website: website
        )
        // 空の場合はスキップ
        guard !cardInfo.company.isEmpty || !cardInfo.title.isEmpty || !cardInfo.department.isEmpty || !cardInfo.address.isEmpty else { return }

        tagSuggestionTask?.cancel()
        let generation = UUID()
        tagSuggestionGeneration = generation
        isLoadingTagSuggestions = true
        tagSuggestionTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.tagSuggestionGeneration == generation {
                    self.isLoadingTagSuggestions = false
                    self.tagSuggestionTask = nil
                }
            }

            let tagSnapshots: [CardFormTagInfoSnapshot]
            do {
                tagSnapshots = try await self.persistenceWorker.loadTagInfos(
                    coordinatorReference: self.coordinatorReference
                )
            } catch {
                guard !(error is CancellationError) else { return }
                AppLogger.persistence.error("タグ候補の読込みに失敗しました: \(error)")
                return
            }
            let tagInfos = tagSnapshots.map {
                AutoTagService.TagInfo(id: $0.id, name: $0.name)
            }
            guard !tagInfos.isEmpty else { return }

            let suggested = await self.autoTagService.suggestTags(cardInfo: cardInfo, tags: tagInfos)
            guard !Task.isCancelled,
                  self.tagSuggestionGeneration == generation,
                  self.ocrProcessingState.phase != .cancelled,
                  self.ocrProcessingState.phase != .failed else { return }
            self.suggestedTagIDs = Set(suggested)
        }
    }

    /// フォームが閉じた後にタグ提案が状態を書き戻さないよう、View所有の処理を終了する。
    func cancelTagSuggestions() {
        tagSuggestionGeneration = UUID()
        tagSuggestionTask?.cancel()
        tagSuggestionTask = nil
        isLoadingTagSuggestions = false
    }

    /// AI提案タグを適用する
    func acceptTagSuggestion(_ tagID: UUID) {
        selectedTags.insert(tagID)
        suggestedTagIDs.remove(tagID)
    }

    /// AI提案タグを却下する
    func dismissTagSuggestion(_ tagID: UUID) {
        suggestedTagIDs.remove(tagID)
    }

    // MARK: - 統一パイプライン

    /// 全 Tier 共通の分類パイプライン。
    ///
    /// 1. 全 OCR span から候補と初期割り当てを生成
    /// 2. 曖昧な span だけを、名刺全体の文脈付きで LLM に照会
    /// 3. span ID と候補集合で応答を検証し、OCR 原文から値を再構成
    private func runUnifiedPipeline(lines: [RecognizedLine], llmBackend: LLMBackend) async throws {
        try Task.checkCancellation()
        let ruleResult = classifier.classifyStructuredFields(lines: lines)
        var result = ruleResult.parsed
        var assignments = ruleResult.assignments
        let neededFields = missingSemanticFields(in: ruleResult.parsed)
        let relevantAmbiguousSpanIDs = ruleResult.ambiguousSpanIDs.filter { spanID in
            ruleResult.candidates.contains { candidate in
                candidate.spanIDs.contains(spanID) && neededFields.contains(candidate.field)
            }
        }
        let request = CardFieldResolutionRequest(
            spans: ruleResult.spans,
            candidates: ruleResult.candidates,
            assignments: ruleResult.assignments,
            ambiguousSpanIDs: relevantAmbiguousSpanIDs
        )
        AppLogger.pipeline.info(
            "項目解析: spans=\(ruleResult.spans.count, privacy: .public) assignments=\(ruleResult.assignments.count, privacy: .public) AI対象=\(relevantAmbiguousSpanIDs.count, privacy: .public)"
        )

        // ルール分類後に初めて確定するAI実行有無・入力規模をETAへ反映する。
        // トークン数は日本語・英数字混在を考慮した文字数ベースの概算で、
        // 実測時間から学習する端末補正により継続的に補正される。
        let inputCharacterCount = request.spans.reduce(0) { $0 + $1.text.count }
        let inputTokenEstimate = max(
            32,
            Int(ceil(Double(inputCharacterCount) / 2)) + request.ambiguousSpanIDs.count * 12
        )
        let outputTokenEstimate = max(1, request.ambiguousSpanIDs.count * 8)
        let aiRequired = llmBackend != .none && !request.ambiguousSpanIDs.isEmpty
        if let state = await OCRProcessingCoordinator.shared.updateAIPlan(
            jobID: ocrJobID,
            backend: llmBackend.workloadBackend,
            required: aiRequired,
            ambiguousSpanCount: request.ambiguousSpanIDs.count,
            inputTokenEstimate: inputTokenEstimate,
            outputTokenEstimate: outputTokenEstimate
        ) {
            ocrProcessingState = state
            OCRBackgroundTaskManager.shared.update(jobID: ocrJobID, state: state)
        }

        guard !request.ambiguousSpanIDs.isEmpty else {
            AppLogger.pipeline.info("全フィールドがルールベースで解決済み")
            applyResolved(result, spans: ruleResult.spans, assignments: assignments)
            return
        }

        if llmBackend != .none {
            try await setOCRPhase(.aiAssistance)
        }

        let decisions = await runLLMBackend(llmBackend, request: request)
        try Task.checkCancellation()

        let validated = CardFieldResolver().validate(decisions: decisions, request: request)
        if !validated.isEmpty {
            assignments.append(contentsOf: validated)
            merge(validated, into: &result)
        }
        applyResolved(result, spans: ruleResult.spans, assignments: assignments)
    }

    private func missingSemanticFields(
        in parsed: CardFieldClassifier.ParsedCard
    ) -> Set<CardFieldKind> {
        var fields = Set<CardFieldKind>()
        if parsed.lastName.isEmpty && parsed.firstName.isEmpty { fields.insert(.personName) }
        if parsed.company.isEmpty { fields.insert(.company) }
        if parsed.department.isEmpty { fields.insert(.department) }
        if parsed.title.isEmpty { fields.insert(.title) }
        return fields
    }

    private var hasAnyResolvedField: Bool {
        !lastName.isEmpty || !firstName.isEmpty || !company.isEmpty
            || !department.isEmpty || !title.isEmpty || !email.isEmpty
            || phones.contains(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
            || !address.isEmpty || !website.isEmpty
    }

    /// LLM バックエンドの種別
    private enum LLMBackend: Equatable {
        case foundationModels
        case qwen
        case none  // Tier 3: ルールベースのみ

        var workloadBackend: OCRAIWorkloadBackend {
            switch self {
            case .foundationModels: .foundationModels
            case .qwen: .localLLM
            case .none: .none
            }
        }
    }

    /// LLM バックエンド固有の推論を実行。ルールベース処理は呼び出し元で完了済み。
    private func runLLMBackend(
        _ backend: LLMBackend,
        request: CardFieldResolutionRequest
    ) async -> [CardFieldDecision] {
        switch backend {
        case .foundationModels:
            #if canImport(FoundationModels)
            if #available(iOS 26.0, *) {
                return await runFoundationModelsLLM(request: request)
            }
            #endif
            return []

        case .qwen:
            return await llmService.resolveFields(request: request)

        case .none:
            return []
        }
    }

    #if canImport(FoundationModels)
    /// Foundation Models 固有の推論。出力は span ID とフィールドだけに限定する。
    @available(iOS 26.0, *)
    private func runFoundationModelsLLM(
        request: CardFieldResolutionRequest
    ) async -> [CardFieldDecision] {
        let spanText = request.spans.sorted { $0.readingOrder < $1.readingOrder }
            .map { "[\($0.id)] \($0.text)" }
            .joined(separator: "\n")
        let candidatesBySpan = Dictionary(grouping: request.candidates) { $0.spanIDs.first ?? "" }
        let targetText = request.ambiguousSpanIDs.prefix(4).map { id in
            let allowed = Set(candidatesBySpan[id, default: []].map(\.field.rawValue)).sorted().joined(separator: ",")
            return "[\(id)] allowed=\(allowed)"
        }.joined(separator: "\n")
        let session = LanguageModelSession()
        let prompt = """
            名刺全体を見て、対象 span を許可されたフィールドへ分類してください。
            span の文字列を生成・修正せず、spanID と field だけを返してください。
            field は personName, company, department, title のいずれかです。

            名刺全体:
            \(spanText)

            対象と許可フィールド:
            \(targetText)
            """
        do {
            let response = try await session.respond(to: prompt, generating: GeneratedFieldDecisions.self)
            return response.content.decisions.compactMap { item in
                guard let field = CardFieldKind(rawValue: item.field) else { return nil }
                return CardFieldDecision(spanID: item.spanID, field: field)
            }
        } catch {
            AppLogger.pipeline.error("Foundation Models 推論エラー: \(error)")
            return []
        }
    }
    #endif

    private func merge(_ assignments: [FieldAssignment], into result: inout CardFieldClassifier.ParsedCard) {
        for assignment in assignments {
            switch assignment.field {
            case .personName where result.lastName.isEmpty && result.firstName.isEmpty:
                let split = NameProcessor.splitName(assignment.value)
                result.lastName = split.lastName
                result.firstName = split.firstName
            case .company where result.company.isEmpty: result.company = assignment.value
            case .department where result.department.isEmpty: result.department = assignment.value
            case .title where result.title.isEmpty: result.title = assignment.value
            default: break
            }
        }
    }

    // MARK: - Tier 別エントリポイント（統一パイプラインへのディスパッチ）

    #if canImport(FoundationModels)
    // 自動モード: Foundation Models → LocalLLM → Classifier の順にフォールバック
    @available(iOS 26.0, *)
    private func populateWithFoundationModels(lines: [RecognizedLine]) async throws {
        switch SystemLanguageModel.default.availability {
        case .available:
            try await runUnifiedPipeline(lines: lines, llmBackend: .foundationModels)
        default:
            try await populateWithLocalLLMOrClassifier(lines: lines)
        }
    }

    // 明示指定モード: Apple Intelligence のみ（利用不可の場合はエラー表示 + Classifier）
    @available(iOS 26.0, *)
    private func populateWithFoundationModelsOnly(lines: [RecognizedLine]) async throws {
        switch SystemLanguageModel.default.availability {
        case .available:
            try await runUnifiedPipeline(lines: lines, llmBackend: .foundationModels)
        default:
            ocrErrorMessage = "Apple Intelligence が利用できません（設定を確認してください）。標準読み取りで処理しました。"
            try await runUnifiedPipeline(lines: lines, llmBackend: .none)
        }
    }
    #endif

    // 明示指定モード: AIアシスト（Qwen）
    private func populateWithLocalLLMOnly(lines: [RecognizedLine]) async throws {
        guard llmService.isModelAvailable else {
            ocrErrorMessage = "AIアシストのモデルが未取得です。設定からダウンロードしてください。標準読み取りで処理しました。"
            try await runUnifiedPipeline(lines: lines, llmBackend: .none)
            return
        }
        try await runUnifiedPipeline(lines: lines, llmBackend: .qwen)
    }

    // 自動モード: LocalLLM → Classifier のフォールバック
    private func populateWithLocalLLMOrClassifier(lines: [RecognizedLine]) async throws {
        if !llmService.isModelAvailable {
            shouldPromptLLMDownload = true
            try await runUnifiedPipeline(lines: lines, llmBackend: .none)
            return
        }
        try await runUnifiedPipeline(lines: lines, llmBackend: .qwen)
    }

    private func populateWithClassifier(lines: [RecognizedLine]) {
        let ruleResult = classifier.classifyStructuredFields(lines: lines)
        applyResolved(ruleResult.parsed, spans: ruleResult.spans, assignments: ruleResult.assignments)
    }

    /// ParsedCard の内容をフォームフィールドに反映する共通ヘルパー
    private func apply(_ parsed: CardFieldClassifier.ParsedCard) {
        apply(lastName: parsed.lastName, lastNameReading: Self.sanitizeReading(parsed.lastNameReading),
              firstName: parsed.firstName, firstNameReading: Self.sanitizeReading(parsed.firstNameReading),
              company: parsed.company, companyReading: BusinessCard.stripLegalEntityReading(from: parsed.companyReading),
              department: parsed.department, title: parsed.title, phones: parsed.phones,
              email: parsed.email, address: parsed.address, website: parsed.website)
    }

    private func applyResolved(
        _ parsed: CardFieldClassifier.ParsedCard,
        spans: [CardTextSpan],
        assignments: [FieldAssignment]
    ) {
        var correctedParsed = parsed
        if let corrected = NameReadingGenerator.correctedNameSplitUsingEmail(
            lastName: parsed.lastName,
            firstName: parsed.firstName,
            email: parsed.email
        ) {
            correctedParsed.lastName = corrected.lastName
            correctedParsed.firstName = corrected.firstName
        }
        let resolution = NameReadingGenerator.resolveReadings(
            parsed: correctedParsed,
            spans: spans,
            assignments: assignments
        )
        readingCandidates = resolution.candidates
        var resolved = correctedParsed
        resolved.lastNameReading = editedReadingTargets.contains(.lastName)
            ? lastNameReading
            : resolution.automaticValues[.lastName] ?? ""
        resolved.firstNameReading = editedReadingTargets.contains(.firstName)
            ? firstNameReading
            : resolution.automaticValues[.firstName] ?? ""
        resolved.companyReading = editedReadingTargets.contains(.company)
            ? companyReading
            : resolution.automaticValues[.company] ?? ""
        isApplyingReadingResolution = true
        apply(resolved)
        isApplyingReadingResolution = false
    }

    func readingCandidates(for target: ReadingTarget) -> [ReadingCandidate] {
        Array(readingCandidates.filter { $0.target == target }.prefix(3))
    }

    func selectReadingCandidate(_ candidate: ReadingCandidate) {
        isApplyingReadingResolution = true
        switch candidate.target {
        case .lastName: lastNameReading = candidate.reading
        case .firstName: firstNameReading = candidate.reading
        case .company: companyReading = candidate.reading
        }
        isApplyingReadingResolution = false
        editedReadingTargets.insert(candidate.target)
    }

    private func markReadingEdited(_ target: ReadingTarget) {
        guard !isApplyingReadingResolution else { return }
        editedReadingTargets.insert(target)
    }

    private static func sanitizeReading(_ reading: String) -> String {
        let trimmed = reading.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        if trimmed.unicodeScalars.allSatisfy({ $0.isASCII }) { return "" }
        return trimmed
    }

    private func apply(lastName: String, lastNameReading: String = "",
                       firstName: String, firstNameReading: String = "",
                       company: String, companyReading: String = "",
                       department: String, title: String,
                       phones: [String], email: String, address: String, website: String) {
        self.lastName         = lastName
        self.lastNameReading  = lastNameReading
        self.firstName        = firstName
        self.firstNameReading = firstNameReading
        self.company          = company
        self.companyReading   = companyReading
        self.department = department
        self.title      = title
        self.phones     = phones.isEmpty ? [""] : phones
        self.email      = email
        self.address    = address
        self.website    = website
    }

    // 読み仮名生成は NameReadingGenerator に委譲

    // MARK: - 保存

    func save() async throws {
        saveErrorMessage = nil
        guard !isSaving else {
            throw CardFormPersistenceError.saveAlreadyInProgress
        }
        if isEditing, editGeneration == nil {
            let error = CardFormPersistenceError.invalidObjectReference
            saveErrorMessage = error.localizedDescription
            throw error
        }

        isSaving = true
        defer { isSaving = false }

        let trimmed: (String) -> String = {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let imageUpdate: CardFormImageUpdate = isEditing && !didChangeCapturedImage
            ? .preserveExisting
            : .replace(capturedImageData)
        let payload = CardFormSavePayload(
            lastName: trimmed(lastName),
            lastNameReading: trimmed(lastNameReading),
            firstName: trimmed(firstName),
            firstNameReading: trimmed(firstNameReading),
            company: trimmed(company),
            // 空欄は「読みを確定できない」という有効な状態。保存直前には再生成しない。
            companyReading: BusinessCard.stripLegalEntityReading(from: trimmed(companyReading)),
            department: trimmed(department),
            title: trimmed(title),
            email: trimmed(email),
            phone: phones.map(trimmed).filter { !$0.isEmpty }.joined(separator: "\n"),
            address: trimmed(address),
            website: trimmed(website),
            notes: trimmed(notes),
            imageUpdate: imageUpdate,
            selectedTagIDs: selectedTags
        )

        do {
            let result = try await persistenceWorker.save(
                payload: payload,
                editing: editGeneration,
                coordinatorReference: coordinatorReference
            )
            mergeSaveResultIntoViewContext(result)
            editGeneration = result.generation
            didChangeCapturedImage = false
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            saveErrorMessage = (error as? LocalizedError)?.errorDescription
                ?? "名刺を保存できませんでした。入力内容を確認して、もう一度お試しください。"
            AppLogger.persistence.error("名刺の保存に失敗しました: \(error)")
            throw error
        }
    }

    private func mergeSaveResultIntoViewContext(_ result: CardFormSaveResult) {
        guard let objectID = coordinatorReference.coordinator.managedObjectID(
            forURIRepresentation: result.generation.objectURI
        ) else { return }
        let key = result.changeKind == .inserted
            ? NSInsertedObjectIDsKey
            : NSUpdatedObjectIDsKey
        NSManagedObjectContext.mergeChanges(
            fromRemoteContextSave: [key: [objectID]],
            into: [context]
        )
    }
}

// MARK: - Foundation Models 構造化出力
#if canImport(FoundationModels)
@available(iOS 26.0, *)
@Generable
struct GeneratedFieldDecision {
    @Guide(description: "入力にある span ID") var spanID: String
    @Guide(description: "personName, company, department, title のいずれか") var field: String
}

@available(iOS 26.0, *)
@Generable
struct GeneratedFieldDecisions {
    @Guide(description: "曖昧な span の分類結果") var decisions: [GeneratedFieldDecision]
}
#endif
