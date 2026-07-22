import Testing
import CoreData
import UIKit
@testable import eMeishi

// MARK: - Mock サービス定義

/// 固定テキストを返す OCR モック
private final class MockOCRService: OCRServiceProtocol {
    var linesToReturn: [RecognizedLine] = []
    var errorToThrow: Error? = nil
    var croppedImageToReturn: UIImage? = nil
    var recognitionDelayNanoseconds: UInt64 = 0

    func detectAndCropCard(from image: UIImage) async -> UIImage {
        croppedImageToReturn ?? image
    }

    func recognizeText(from image: UIImage) async throws -> [RecognizedLine] {
        if recognitionDelayNanoseconds > 0 {
            try await Task.sleep(nanoseconds: recognitionDelayNanoseconds)
        }
        if let error = errorToThrow { throw error }
        return linesToReturn
    }
}

/// 固定 ParsedCard を返す Classifier モック
private struct MockClassifier: CardFieldClassifierProtocol {
    var result: CardFieldClassifier.ParsedCard
    var unclassifiedLines: [String] = []
    var structuredResult: CardFieldClassifier.StructuredFieldsResult?

    func classifyStructuredFields(lines: [RecognizedLine]) -> CardFieldClassifier.StructuredFieldsResult {
        structuredResult ?? CardFieldClassifier.StructuredFieldsResult(parsed: result, unclassifiedLines: unclassifiedLines)
    }
}

/// モデル有無と分類結果を制御できる LLM モック
private final class MockLLMService: LocalLLMServiceProtocol {
    var isModelAvailable: Bool
    var classifyResult: CardFieldClassifier.ParsedCard?
    var decisions: [CardFieldDecision] = []
    var resolveCallCount = 0

    init(modelAvailable: Bool = false, classifyResult: CardFieldClassifier.ParsedCard? = nil) {
        self.isModelAvailable = modelAvailable
        self.classifyResult = classifyResult
    }

    func classifyUnclassifiedLines(_ lines: [String]) async -> CardFieldClassifier.ParsedCard? {
        classifyResult
    }

    func resolveFields(request: CardFieldResolutionRequest) async -> [CardFieldDecision] {
        resolveCallCount += 1
        return decisions
    }
}

/// 固定 UUID リストを返す AutoTag モック
private final class MockAutoTagService: AutoTagServiceProtocol {
    var returnedIDs: [UUID] = []
    func suggestTags(cardInfo: AutoTagService.CardInfo, tags: [AutoTagService.TagInfo]) async -> [UUID] {
        returnedIDs
    }
}

/// readingMethod を制御できる Settings モック
@MainActor
private struct MockSettings: SettingsProviding {
    var readingMethod: ReadingMethod
}

// MARK: - テスト用ヘルパー

@MainActor
private func makeContext() -> NSManagedObjectContext {
    PersistenceController(inMemory: true).container.viewContext
}

@MainActor
private func makeLine(_ text: String) -> RecognizedLine {
    RecognizedLine(
        text: text,
        boundingBox: CGRect(x: 0.1, y: 0.1, width: 0.8, height: 0.05),
        confidence: 0.99
    )
}

@MainActor
private func makeTestImage(size: CGSize, color: UIColor) -> UIImage {
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    return UIGraphicsImageRenderer(size: size, format: format).image { context in
        color.setFill()
        context.fill(CGRect(origin: .zero, size: size))
    }
}

@MainActor
private func waitForOCRCompletion(_ vm: CardFormViewModel) async {
    for _ in 0..<50 {
        if !vm.isProcessingOCR { return }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
}

// MARK: - 初期化（新規作成・カード編集）

@MainActor
struct CardFormViewModelInitTests {

    @Test func defaultInitHasEmptyFields() {
        let ctx = makeContext()
        let vm = CardFormViewModel(context: ctx)
        #expect(vm.lastName.isEmpty)
        #expect(vm.firstName.isEmpty)
        #expect(vm.phones == [""])
        #expect(vm.isEditing == false)
    }

    @Test func cardInitRestoresFields() throws {
        let ctx = makeContext()
        let card = BusinessCard(context: ctx)
        card.id = UUID()
        card.lastName = "山田"
        card.firstName = "太郎"
        card.company = "テスト株式会社"
        card.email = "yamada@example.com"
        card.phone = "03-1234-5678\n090-9999-0000"
        card.notes = "備考"
        let imageData = Data([0x01, 0x02, 0x03])
        card.imageData = imageData
        card.createdAt = Date()
        card.updatedAt = Date()

        let vm = CardFormViewModel(card: card, context: ctx)
        #expect(vm.lastName == "山田")
        #expect(vm.firstName == "太郎")
        #expect(vm.company == "テスト株式会社")
        #expect(vm.email == "yamada@example.com")
        #expect(vm.phones.count == 2)
        #expect(vm.notes == "備考")
        #expect(vm.capturedImageData == imageData)
        #expect(vm.isEditing == true)
    }

    @Test func cardInitWithSinglePhoneSetsOneEntry() {
        let ctx = makeContext()
        let card = BusinessCard(context: ctx)
        card.id = UUID()
        card.phone = "03-1234-5678"
        card.createdAt = Date()
        card.updatedAt = Date()

        let vm = CardFormViewModel(card: card, context: ctx)
        #expect(vm.phones == ["03-1234-5678"])
    }

    @Test func cardInitWithNilPhoneDefaultsToEmptyEntry() {
        let ctx = makeContext()
        let card = BusinessCard(context: ctx)
        card.id = UUID()
        card.phone = nil
        card.createdAt = Date()
        card.updatedAt = Date()

        let vm = CardFormViewModel(card: card, context: ctx)
        #expect(vm.phones == [""])
    }
}

// MARK: - 保存（save）

@MainActor
struct CardFormViewModelSaveTests {

    @Test func saveNewCardSetsIdAndCreatedAt() throws {
        let ctx = makeContext()
        let vm = CardFormViewModel(context: ctx)
        vm.lastName = "佐藤"
        vm.firstName = "花子"
        vm.company = "株式会社テスト"
        try vm.save()
        try ctx.save()

        let request = BusinessCard.fetchRequest()
        let cards = try ctx.fetch(request)
        #expect(cards.count == 1)
        let saved = try #require(cards.first)
        #expect(saved.id != nil)
        #expect(saved.createdAt != nil)
        #expect(saved.lastName == "佐藤")
    }

    @Test func saveUpdatesExistingCardUpdatedAt() throws {
        let ctx = makeContext()
        let card = BusinessCard(context: ctx)
        card.id = UUID()
        card.lastName = "旧姓"
        let oldDate = Date(timeIntervalSinceReferenceDate: 0)
        card.createdAt = oldDate
        card.updatedAt = oldDate
        try ctx.save()

        let vm = CardFormViewModel(card: card, context: ctx)
        vm.lastName = "新姓"
        try vm.save()

        #expect(card.lastName == "新姓")
        #expect(card.updatedAt! > oldDate)
    }

    @Test func saveTrimesWhitespace() throws {
        let ctx = makeContext()
        let vm = CardFormViewModel(context: ctx)
        vm.lastName = "  山田  "
        vm.email = " test@example.com "
        try vm.save()

        let request = BusinessCard.fetchRequest()
        let cards = try ctx.fetch(request)
        let saved = try #require(cards.first)
        #expect(saved.lastName == "山田")
        #expect(saved.email == "test@example.com")
    }

    @Test func saveJoinsPhonesWithNewline() throws {
        let ctx = makeContext()
        let vm = CardFormViewModel(context: ctx)
        vm.phones = ["03-1234-5678", "090-0000-0001", ""]
        try vm.save()

        let request = BusinessCard.fetchRequest()
        let cards = try ctx.fetch(request)
        let saved = try #require(cards.first)
        // 空エントリは除去、残り2件を \n で結合
        #expect(saved.phone == "03-1234-5678\n090-0000-0001")
    }

    @Test func saveAppliesSelectedTags() throws {
        let ctx = makeContext()
        let tag = eMeishi.Tag(context: ctx)
        tag.id = UUID()
        tag.name = "重要"
        tag.colorHex = "#FF0000"
        tag.sortOrder = 0
        tag.createdAt = Date()
        try ctx.save()

        let vm = CardFormViewModel(context: ctx)
        vm.selectedTags = [tag.id!]
        try vm.save()

        let request = BusinessCard.fetchRequest()
        let cards = try ctx.fetch(request)
        let saved = try #require(cards.first)
        let tags = (saved.tags as? Set<eMeishi.Tag>) ?? []
        #expect(tags.contains(tag))
    }

    @Test func saveExistingCardPreservesImageWhenImageWasNotChanged() throws {
        let ctx = makeContext()
        let originalImageData = Data((0..<128).map(UInt8.init))
        let card = BusinessCard(context: ctx)
        card.id = UUID()
        card.lastName = "山田"
        card.imageData = originalImageData
        card.createdAt = Date()
        card.updatedAt = Date()
        try ctx.save()

        let vm = CardFormViewModel(card: card, context: ctx)
        vm.lastName = "佐藤"
        try vm.save()

        #expect(card.lastName == "佐藤")
        #expect(card.imageData == originalImageData)
    }

    @Test func saveKeepsUncertainCompanyReadingBlank() throws {
        let ctx = makeContext()
        let vm = CardFormViewModel(context: ctx)
        vm.company = "SONY"
        vm.companyReading = ""

        try vm.save()

        let saved = try #require(ctx.fetch(BusinessCard.fetchRequest()).first)
        #expect(saved.companyReading?.isEmpty == true)
    }
}

// MARK: - タグ提案（requestTagSuggestions）

@MainActor
struct CardFormViewModelTagSuggestionTests {

    @Test func requestTagSuggestionsSkippedWhenEditing() {
        let ctx = makeContext()
        let card = BusinessCard(context: ctx)
        card.id = UUID()
        card.createdAt = Date()
        card.updatedAt = Date()
        let vm = CardFormViewModel(card: card, context: ctx)
        // isEditing == true のためスキップされ isLoadingTagSuggestions は false のまま
        vm.requestTagSuggestions()
        #expect(vm.isLoadingTagSuggestions == false)
    }

    @Test func requestTagSuggestionsSkippedWhenSelectedTagsNotEmpty() {
        let ctx = makeContext()
        let vm = CardFormViewModel(context: ctx)
        vm.selectedTags = [UUID()]
        vm.requestTagSuggestions()
        #expect(vm.isLoadingTagSuggestions == false)
    }

    @Test func requestTagSuggestionsSkippedWhenAllFieldsEmpty() {
        let ctx = makeContext()
        let vm = CardFormViewModel(context: ctx)
        // company/title/department/address が全て空 → スキップ
        vm.requestTagSuggestions()
        #expect(vm.isLoadingTagSuggestions == false)
    }

    @Test func acceptTagSuggestionMovesTagToSelected() {
        let ctx = makeContext()
        let vm = CardFormViewModel(context: ctx)
        let id = UUID()
        vm.suggestedTagIDs = [id]
        vm.acceptTagSuggestion(id)
        #expect(vm.selectedTags.contains(id))
        #expect(!vm.suggestedTagIDs.contains(id))
    }

    @Test func dismissTagSuggestionRemovesFromSuggested() {
        let ctx = makeContext()
        let vm = CardFormViewModel(context: ctx)
        let id = UUID()
        vm.suggestedTagIDs = [id]
        vm.dismissTagSuggestion(id)
        #expect(!vm.suggestedTagIDs.contains(id))
        #expect(!vm.selectedTags.contains(id))
    }
}

// MARK: - OCR パイプライン（populateFromOCR）

@MainActor
struct CardFormViewModelOCRTests {

    @Test func cancelOCRAndWaitFinishesWithCancelledState() async {
        let ctx = makeContext()
        let mockOCR = MockOCRService()
        mockOCR.recognitionDelayNanoseconds = 5_000_000_000
        mockOCR.linesToReturn = [makeLine("山田太郎")]

        let vm = CardFormViewModel(
            croppedImage: makeTestImage(size: CGSize(width: 120, height: 60), color: .white),
            context: ctx,
            ocrService: mockOCR,
            classifier: MockClassifier(result: CardFieldClassifier.ParsedCard()),
            llmService: MockLLMService(),
            settings: MockSettings(readingMethod: .localLLM)
        )

        await Task.yield()
        await vm.cancelOCRAndWait()

        #expect(vm.isProcessingOCR == false)
        #expect(vm.ocrProcessingState.phase == .cancelled)
        let coordinatorState = await OCRProcessingCoordinator.shared.currentState(jobID: vm.ocrJobID)
        #expect(coordinatorState?.phase == .cancelled)
    }

    @Test func imageInitStoresCroppedImageData() async throws {
        let ctx = makeContext()
        let originalImage = makeTestImage(size: CGSize(width: 120, height: 60), color: .red)
        let croppedImage = makeTestImage(size: CGSize(width: 40, height: 80), color: .blue)
        let mockOCR = MockOCRService()
        mockOCR.croppedImageToReturn = croppedImage
        mockOCR.linesToReturn = [makeLine("山田太郎")]

        var parsed = CardFieldClassifier.ParsedCard()
        parsed.lastName = "山田"
        parsed.firstName = "太郎"

        let vm = CardFormViewModel(
            image: originalImage,
            context: ctx,
            ocrService: mockOCR,
            classifier: MockClassifier(result: parsed),
            llmService: MockLLMService(),
            settings: MockSettings(readingMethod: .localLLM)
        )

        await waitForOCRCompletion(vm)

        #expect(vm.isProcessingOCR == false)
        let data = try #require(vm.capturedImageData)
        let savedImage = try #require(UIImage(data: data))
        #expect(Int(savedImage.size.width.rounded()) == 40)
        #expect(Int(savedImage.size.height.rounded()) == 80)
    }

    @Test func populateFromOCRSetsErrorOnThrow() async {
        let ctx = makeContext()
        let mockOCR = MockOCRService()
        mockOCR.errorToThrow = NSError(domain: "test", code: 1)
        let vm = CardFormViewModel(
            context: ctx,
            ocrService: mockOCR,
            classifier: MockClassifier(result: CardFieldClassifier.ParsedCard()),
            llmService: MockLLMService(),
            settings: MockSettings(readingMethod: .localLLM)
        )

        await vm.populateFromOCR(image: UIImage())
        #expect(vm.ocrErrorMessage != nil)
        #expect(vm.isProcessingOCR == false)
    }

    @Test func populateFromOCRSetsErrorOnEmptyLines() async {
        let ctx = makeContext()
        let mockOCR = MockOCRService()
        mockOCR.linesToReturn = []
        let vm = CardFormViewModel(
            context: ctx,
            ocrService: mockOCR,
            classifier: MockClassifier(result: CardFieldClassifier.ParsedCard()),
            llmService: MockLLMService(),
            settings: MockSettings(readingMethod: .localLLM)
        )

        await vm.populateFromOCR(image: UIImage())
        #expect(vm.ocrErrorMessage == "テキストを認識できませんでした")
        #expect(vm.isProcessingOCR == false)
    }

    @Test func populateFromOCRAppliesRuleResultWhenLocalLLMNotAvailable() async {
        let ctx = makeContext()
        let mockOCR = MockOCRService()
        mockOCR.linesToReturn = [makeLine("山田太郎"), makeLine("テスト株式会社")]

        var parsed = CardFieldClassifier.ParsedCard()
        parsed.lastName = "山田"
        parsed.firstName = "太郎"
        parsed.company = "テスト株式会社"

        let vm = CardFormViewModel(
            context: ctx,
            ocrService: mockOCR,
            // 未分類行なし → ルールベースのみで完了
            classifier: MockClassifier(result: parsed, unclassifiedLines: []),
            llmService: MockLLMService(modelAvailable: false),
            settings: MockSettings(readingMethod: .localLLM)
        )

        await vm.populateFromOCR(image: UIImage())
        #expect(vm.lastName == "山田")
        #expect(vm.firstName == "太郎")
        #expect(vm.company == "テスト株式会社")
        #expect(vm.isProcessingOCR == false)
    }

    @Test func populateFromOCRReplacesAsciiReadingsWithGeneratedKana() async {
        let ctx = makeContext()
        let mockOCR = MockOCRService()
        mockOCR.linesToReturn = [makeLine("田中 花子"), makeLine("TANAKA Hanako")]

        var parsed = CardFieldClassifier.ParsedCard()
        parsed.lastName = "田中"
        parsed.firstName = "花子"
        parsed.lastNameReading = "TANAKA"
        parsed.firstNameReading = "Hanako"

        let vm = CardFormViewModel(
            context: ctx,
            ocrService: mockOCR,
            classifier: MockClassifier(result: parsed, unclassifiedLines: []),
            llmService: MockLLMService(modelAvailable: false),
            settings: MockSettings(readingMethod: .localLLM)
        )

        await vm.populateFromOCR(image: UIImage())
        #expect(vm.lastName == "田中")
        #expect(vm.firstName == "花子")
        #expect(vm.lastNameReading == "たなか")
        #expect(vm.firstNameReading == "はなこ")
    }

    @Test func populateFromOCRLocalLLMNotAvailableSetsError() async {
        let ctx = makeContext()
        let mockOCR = MockOCRService()
        mockOCR.linesToReturn = [makeLine("山田")]

        let vm = CardFormViewModel(
            context: ctx,
            ocrService: mockOCR,
            classifier: MockClassifier(result: CardFieldClassifier.ParsedCard(), unclassifiedLines: ["山田"]),
            llmService: MockLLMService(modelAvailable: false),
            settings: MockSettings(readingMethod: .localLLM)
        )

        await vm.populateFromOCR(image: UIImage())
        #expect(vm.ocrErrorMessage != nil)
        #expect(vm.isProcessingOCR == false)
    }

    @Test func populateFromOCRMergesLLMResultWhenOCRTextPresent() async {
        let ctx = makeContext()
        let mockOCR = MockOCRService()
        mockOCR.linesToReturn = [makeLine("山田"), makeLine("テック営業部")]

        // ルールベースは名前のみ解決し、曖昧な span を候補付きで残す。
        var ruleParsed = CardFieldClassifier.ParsedCard()
        ruleParsed.lastName = "山田"
        let spans = [
            CardTextSpan(sourceLineIndex: 0, text: "山田", boundingBox: .zero, ocrConfidence: 0.99, textDirection: .leftToRight, readingOrder: 0),
            CardTextSpan(sourceLineIndex: 1, text: "テック営業部", boundingBox: .zero, ocrConfidence: 0.99, textDirection: .leftToRight, readingOrder: 1),
        ]
        let nameAssignment = FieldAssignment(
            spanIDs: [spans[0].id], field: .personName, value: "山田",
            confidence: .medium, source: .resolver
        )
        let departmentCandidate = FieldCandidate(
            spanIDs: [spans[1].id], field: .department, value: "テック営業部",
            score: 0.5, evidence: [.organizationKeyword]
        )
        let structured = CardFieldClassifier.StructuredFieldsResult(
            parsed: ruleParsed,
            unclassifiedLines: ["テック営業部"],
            spans: spans,
            candidates: [departmentCandidate],
            assignments: [nameAssignment],
            ambiguousSpanIDs: [spans[1].id]
        )
        let llm = MockLLMService(modelAvailable: true)
        llm.decisions = [CardFieldDecision(spanID: spans[1].id, field: .department)]

        let vm = CardFormViewModel(
            context: ctx,
            ocrService: mockOCR,
            classifier: MockClassifier(result: ruleParsed, structuredResult: structured),
            llmService: llm,
            settings: MockSettings(readingMethod: .localLLM)
        )

        await vm.populateFromOCR(image: UIImage())
        #expect(vm.lastName == "山田")
        #expect(vm.department == "テック営業部")
    }

    @Test func populateFromOCRHallucinatedDepartmentIsRejected() async {
        let ctx = makeContext()
        let mockOCR = MockOCRService()
        mockOCR.linesToReturn = [makeLine("山田"), makeLine("テック")]

        var ruleParsed = CardFieldClassifier.ParsedCard()
        ruleParsed.lastName = "山田"

        let span = CardTextSpan(
            sourceLineIndex: 1, text: "テック", boundingBox: .zero,
            ocrConfidence: 0.99, textDirection: .leftToRight, readingOrder: 1
        )
        let candidate = FieldCandidate(
            spanIDs: [span.id], field: .department, value: "テック",
            score: 0.4, evidence: [.organizationKeyword]
        )
        let structured = CardFieldClassifier.StructuredFieldsResult(
            parsed: ruleParsed,
            unclassifiedLines: ["テック"],
            spans: [span],
            candidates: [candidate],
            assignments: [],
            ambiguousSpanIDs: [span.id]
        )
        let llm = MockLLMService(modelAvailable: true)
        // 会社は許可候補にないため、OCR文字列を使っていても採用しない。
        llm.decisions = [CardFieldDecision(spanID: span.id, field: .company)]

        let vm = CardFormViewModel(
            context: ctx,
            ocrService: mockOCR,
            classifier: MockClassifier(result: ruleParsed, structuredResult: structured),
            llmService: llm,
            settings: MockSettings(readingMethod: .localLLM)
        )

        await vm.populateFromOCR(image: UIImage())
        // ハルシネーション除去により department は空のまま
        #expect(vm.department.isEmpty)
    }

    @Test func populateFromOCRSkipsAIForAlreadyResolvedField() async {
        let ctx = makeContext()
        let mockOCR = MockOCRService()
        mockOCR.linesToReturn = [makeLine("山田 太郎")]

        var parsed = CardFieldClassifier.ParsedCard()
        parsed.lastName = "山田"
        parsed.firstName = "太郎"
        let span = CardTextSpan(
            sourceLineIndex: 0, text: "別候補", boundingBox: .zero,
            ocrConfidence: 0.8, textDirection: .leftToRight, readingOrder: 0
        )
        let duplicateNameCandidate = FieldCandidate(
            spanIDs: [span.id], field: .personName, value: span.text,
            score: 0.4, evidence: [.nameShape]
        )
        let structured = CardFieldClassifier.StructuredFieldsResult(
            parsed: parsed,
            unclassifiedLines: [span.text],
            spans: [span],
            candidates: [duplicateNameCandidate],
            assignments: [],
            ambiguousSpanIDs: [span.id]
        )
        let llm = MockLLMService(modelAvailable: true)
        let vm = CardFormViewModel(
            context: ctx,
            ocrService: mockOCR,
            classifier: MockClassifier(result: parsed, structuredResult: structured),
            llmService: llm,
            settings: MockSettings(readingMethod: .localLLM)
        )

        await vm.populateFromOCR(image: UIImage())

        #expect(llm.resolveCallCount == 0)
        #expect(vm.lastName == "山田")
        #expect(vm.firstName == "太郎")
    }

    @Test func populateFromOCRDoesNotCompleteWithAllFieldsEmpty() async {
        let ctx = makeContext()
        let mockOCR = MockOCRService()
        mockOCR.linesToReturn = [makeLine("SAMPLE LOGO")]
        let vm = CardFormViewModel(
            context: ctx,
            ocrService: mockOCR,
            classifier: MockClassifier(result: CardFieldClassifier.ParsedCard()),
            llmService: MockLLMService(modelAvailable: false),
            settings: MockSettings(readingMethod: .localLLM)
        )

        await vm.populateFromOCR(image: UIImage())

        #expect(vm.ocrProcessingState.phase == .failed)
        #expect(vm.ocrErrorMessage != nil)
    }

    @Test func ocrReviewAutoFillsReliableEmailReadingAndKeepsItSelectable() async throws {
        let ctx = makeContext()
        let mockOCR = MockOCRService()
        mockOCR.linesToReturn = [
            makeLine("山田 太郎"),
            makeLine("yamada.taro@example.com"),
        ]

        let vm = CardFormViewModel(
            context: ctx,
            ocrService: mockOCR,
            classifier: CardFieldClassifier(),
            llmService: MockLLMService(modelAvailable: false),
            settings: MockSettings(readingMethod: .localLLM)
        )

        await vm.populateFromOCR(image: UIImage())

        let candidate = try #require(vm.readingCandidates(for: .lastName).first(where: { $0.source == .email }))
        #expect(vm.lastNameReading == candidate.reading)
        vm.selectReadingCandidate(candidate)
        #expect(vm.lastNameReading == candidate.reading)
    }
}
