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

    func classifyStructuredFields(lines: [RecognizedLine]) -> CardFieldClassifier.StructuredFieldsResult {
        CardFieldClassifier.StructuredFieldsResult(parsed: result, unclassifiedLines: unclassifiedLines)
    }
}

/// モデル有無と分類結果を制御できる LLM モック
private final class MockLLMService: LocalLLMServiceProtocol {
    var isModelAvailable: Bool
    var classifyResult: CardFieldClassifier.ParsedCard?

    init(modelAvailable: Bool = false, classifyResult: CardFieldClassifier.ParsedCard? = nil) {
        self.isModelAvailable = modelAvailable
        self.classifyResult = classifyResult
    }

    func classifyUnclassifiedLines(_ lines: [String]) async -> CardFieldClassifier.ParsedCard? {
        classifyResult
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

    @Test func populateFromOCRDoesNotStoreAsciiOnlyReadingsAsFurigana() async {
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
        #expect(vm.lastNameReading.isEmpty)
        #expect(vm.firstNameReading.isEmpty)
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

        // ルールベースは名前のみ解決、部署は未分類
        var ruleParsed = CardFieldClassifier.ParsedCard()
        ruleParsed.lastName = "山田"

        // LLM は部署を返す（OCR テキストに存在する文字列）
        var llmParsed = CardFieldClassifier.ParsedCard()
        llmParsed.department = "テック営業部"

        let vm = CardFormViewModel(
            context: ctx,
            ocrService: mockOCR,
            classifier: MockClassifier(result: ruleParsed, unclassifiedLines: ["テック営業部"]),
            llmService: MockLLMService(modelAvailable: true, classifyResult: llmParsed),
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

        // LLM が OCR テキストに存在しない部署を返す → ハルシネーション除去
        var llmParsed = CardFieldClassifier.ParsedCard()
        llmParsed.department = "存在しない部署名XYZ"

        let vm = CardFormViewModel(
            context: ctx,
            ocrService: mockOCR,
            classifier: MockClassifier(result: ruleParsed, unclassifiedLines: ["テック"]),
            llmService: MockLLMService(modelAvailable: true, classifyResult: llmParsed),
            settings: MockSettings(readingMethod: .localLLM)
        )

        await vm.populateFromOCR(image: UIImage())
        // ハルシネーション除去により department は空のまま
        #expect(vm.department.isEmpty)
    }
}
