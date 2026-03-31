import Foundation
import CoreData
import Combine
import UIKit
#if canImport(FoundationModels)
import FoundationModels
#endif

// 名刺の新規作成・編集フォームのViewModel
class CardFormViewModel: ObservableObject {

    @Published var lastName: String = ""
    @Published var lastNameReading: String = ""
    @Published var firstName: String = ""
    @Published var firstNameReading: String = ""
    @Published var company: String = ""
    @Published var companyReading: String = ""
    @Published var department: String = ""
    @Published var title: String = ""
    @Published var email: String = ""
    @Published var phones: [String] = [""]
    @Published var address: String = ""
    @Published var website: String = ""
    @Published var notes: String = ""
    @Published var selectedTags: Set<UUID> = []

    // OCR処理中フラグ・エラーメッセージ
    @Published var isProcessingOCR: Bool = false
    @Published var ocrStage: String = "名刺を読み取り中..."
    @Published var ocrErrorMessage: String? = nil

    // モデル未取得時にダウンロード同意アラートを表示するフラグ
    @Published var shouldPromptLLMDownload: Bool = false

    // 撮影した名刺画像（保存用）
    var capturedImageData: Data? = nil

    // 編集中かどうかを外部から確認できるように公開
    var isEditing: Bool { card != nil }

    private let context: NSManagedObjectContext
    private var card: BusinessCard?
    private let ocrService = OCRService()
    private let classifier = CardFieldClassifier()

    // MARK: - 初期化（新規作成）

    init(context: NSManagedObjectContext = PersistenceController.shared.container.viewContext) {
        self.context = context
    }

    // MARK: - 初期化（カメラ撮影画像からOCR）

    init(image: UIImage,
         context: NSManagedObjectContext = PersistenceController.shared.container.viewContext) {
        self.context = context
        // 矩形検出前にオリジナル画像をいったんセットしておく（検出後に上書き）
        self.capturedImageData = image.jpegData(compressionQuality: 0.8)
        // init 時点でフラグを立てることで、最初のレンダリングからインジケーターを表示
        self.isProcessingOCR = true
        Task { @MainActor in
            // 矩形検出 → パースペクティブ補正済みの名刺画像を取得
            let cardImage = await ocrService.detectAndCropCard(from: image)
            // 補正済み画像で保存データを上書き
            self.capturedImageData = cardImage.jpegData(compressionQuality: 0.8)
            await populateFromOCR(image: cardImage)
        }
    }

    // MARK: - 初期化（既存カードの編集）

    init(card: BusinessCard,
         context: NSManagedObjectContext = PersistenceController.shared.container.viewContext) {
        self.card = card
        self.context = context
        lastName        = card.lastName        ?? ""
        lastNameReading = card.lastNameReading ?? ""
        firstName       = card.firstName       ?? ""
        firstNameReading = card.firstNameReading ?? ""
        company        = card.company        ?? ""
        companyReading = card.companyReading ?? ""
        department = card.department ?? ""
        title      = card.title      ?? ""
        email     = card.email     ?? ""
        let stored = card.phoneList
        phones    = stored.isEmpty ? [""] : stored
        address   = card.address   ?? ""
        website   = card.website   ?? ""
        notes     = card.notes     ?? ""
        selectedTags = Set(card.tagArray.compactMap { $0.id })
    }

    // MARK: - OCR + AI意味分析

    @MainActor
    func populateFromOCR(image: UIImage) async {
        isProcessingOCR = true
        ocrStage = "文字を認識中..."
        ocrErrorMessage = nil

        do {
            let lines = try await ocrService.recognizeText(from: image)
            guard !lines.isEmpty else {
                ocrErrorMessage = "テキストを認識できませんでした"
                isProcessingOCR = false
                return
            }

            ocrStage = "フィールドを分析中..."

            switch SettingsStore.shared.readingMethod {
            case .automatic:
                #if canImport(FoundationModels)
                if #available(iOS 26.0, *) {
                    await populateWithFoundationModels(lines: lines)
                } else {
                    await populateWithLocalLLMOrClassifier(lines: lines)
                }
                #else
                await populateWithLocalLLMOrClassifier(lines: lines)
                #endif
            case .appleIntelligence:
                #if canImport(FoundationModels)
                if #available(iOS 26.0, *) {
                    await populateWithFoundationModelsOnly(lines: lines)
                } else {
                    ocrErrorMessage = "Apple Intelligence は iOS 26 以降で利用できます。標準読み取りで処理しました。"
                    populateWithClassifier(lines: lines)
                }
                #else
                ocrErrorMessage = "Apple Intelligence は現在利用できません。標準読み取りで処理しました。"
                populateWithClassifier(lines: lines)
                #endif
            case .localLLM:
                ocrStage = "AIモデルで分析中..."
                await populateWithLocalLLMOnly(lines: lines)
            case .classifier:
                populateWithClassifier(lines: lines)
            }
        } catch {
            ocrErrorMessage = "OCR処理に失敗しました: \(error.localizedDescription)"
        }

        isProcessingOCR = false
    }

    // MARK: - 統一パイプライン

    /// 全 Tier 共通の分類パイプライン。
    ///
    /// 1. ルールベース前段処理（classifyStructuredFields）— 全 Tier 共通・1回だけ実行
    /// 2. 未分類行を LLM バックエンドに送信（Foundation Models / Qwen / なし）
    /// 3. LLM 結果を OCR テキストで照合バリデーション — 全 Tier 共通
    /// 4. ルールベース結果と LLM 結果をマージ — 全 Tier 共通
    private func runUnifiedPipeline(lines: [RecognizedLine], llmBackend: LLMBackend) async {
        // --- Step 1: ルールベース前段処理（全 Tier 共通） ---
        let ruleResult = classifier.classifyStructuredFields(lines: lines)
        var result = ruleResult.parsed
        let ocrTexts = lines.map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }

        // 未分類行が空ならルールベース結果のみで完了
        guard !ruleResult.unclassifiedLines.isEmpty else {
            print("[Pipeline] 全フィールドがルールベースで解決済み")
            apply(result)
            return
        }

        // --- Step 2: LLM バックエンドで未分類行を分類 ---
        let llmResult: CardFieldClassifier.ParsedCard? = await runLLMBackend(
            llmBackend,
            unclassifiedLines: ruleResult.unclassifiedLines,
            baseParsed: result
        )

        // --- Step 3: LLM 結果の OCR テキスト照合バリデーション + マージ（全 Tier 共通） ---
        if let llm = llmResult {
            if !llm.lastName.isEmpty && result.lastName.isEmpty { result.lastName = llm.lastName }
            if !llm.firstName.isEmpty && result.firstName.isEmpty { result.firstName = llm.firstName }

            // department/title/company は OCR テキストに存在するか照合（ハルシネーション防止）
            if !llm.department.isEmpty && result.department.isEmpty {
                if existsInOCR(llm.department, ocrTexts: ocrTexts) {
                    result.department = llm.department
                } else {
                    print("[Pipeline] 部署ハルシネーション除去: '\(llm.department)'")
                }
            }
            if !llm.title.isEmpty && result.title.isEmpty {
                if existsInOCR(llm.title, ocrTexts: ocrTexts) {
                    result.title = llm.title
                } else {
                    print("[Pipeline] 役職ハルシネーション除去: '\(llm.title)'")
                }
            }
            if !llm.company.isEmpty && result.company.isEmpty {
                if existsInOCR(llm.company, ocrTexts: ocrTexts) {
                    result.company = llm.company
                } else {
                    print("[Pipeline] 会社名ハルシネーション除去: '\(llm.company)'")
                }
            }
        }

        apply(result)
    }

    /// LLM バックエンドの種別
    private enum LLMBackend {
        case foundationModels
        case qwen
        case none  // Tier 3: ルールベースのみ
    }

    /// LLM バックエンド固有の推論を実行。ルールベース処理は呼び出し元で完了済み。
    private func runLLMBackend(
        _ backend: LLMBackend,
        unclassifiedLines: [String],
        baseParsed: CardFieldClassifier.ParsedCard
    ) async -> CardFieldClassifier.ParsedCard? {
        switch backend {
        case .foundationModels:
            #if canImport(FoundationModels)
            if #available(iOS 26.0, *) {
                return await runFoundationModelsLLM(
                    unclassifiedLines: unclassifiedLines,
                    baseParsed: baseParsed
                )
            }
            #endif
            return nil

        case .qwen:
            return await LocalLLMService.shared.classifyUnclassifiedLines(unclassifiedLines)

        case .none:
            return nil
        }
    }

    #if canImport(FoundationModels)
    /// Foundation Models 固有の推論（未分類行のみ処理）
    @available(iOS 26.0, *)
    private func runFoundationModelsLLM(
        unclassifiedLines: [String],
        baseParsed: CardFieldClassifier.ParsedCard
    ) async -> CardFieldClassifier.ParsedCard? {
        let unclassifiedText = unclassifiedLines.joined(separator: "\n")
        var contextHints: [String] = []
        if !baseParsed.company.isEmpty { contextHints.append("会社名: \(baseParsed.company)") }
        if !baseParsed.department.isEmpty { contextHints.append("部署: \(baseParsed.department)") }
        if !baseParsed.title.isEmpty { contextHints.append("役職: \(baseParsed.title)") }
        let contextBlock = contextHints.isEmpty ? "" : "\n既に判明している情報:\n\(contextHints.joined(separator: "\n"))\n"

        let session = LanguageModelSession()
        let prompt = """
            以下は名刺から読み取ったテキストのうち、まだ分類できていない行です。各フィールドに分類してください。
            姓と名は必ず分けてください。
            重要: テキストに明記されていない情報は絶対に推測せず、空文字列にしてください。
            特に部署名・役職はテキストに明記されている場合のみ設定し、推測は禁止です。
            \(contextBlock)
            未分類テキスト:
            \(unclassifiedText)
            """
        do {
            let response = try await session.respond(to: prompt, generating: ParsedCard.self)
            let p = response.content
            // Foundation Models の出力を CardFieldClassifier.ParsedCard に変換
            var llm = CardFieldClassifier.ParsedCard()
            llm.lastName = p.lastName
            llm.firstName = p.firstName
            llm.company = p.company
            llm.department = p.department
            llm.title = p.title
            return llm
        } catch {
            print("[FoundationModels] 推論エラー: \(error)")
            return nil
        }
    }
    #endif

    /// LLM出力値がOCRテキストに存在するか照合する
    private func existsInOCR(_ value: String, ocrTexts: [String]) -> Bool {
        guard !value.isEmpty else { return true }
        let v = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let joined = ocrTexts.joined(separator: "\n")
        return joined.contains(v) || ocrTexts.contains { $0.contains(v) || v.contains($0) }
    }

    // MARK: - Tier 別エントリポイント（統一パイプラインへのディスパッチ）

    #if canImport(FoundationModels)
    // 自動モード: Foundation Models → LocalLLM → Classifier の順にフォールバック
    @available(iOS 26.0, *)
    private func populateWithFoundationModels(lines: [RecognizedLine]) async {
        switch SystemLanguageModel.default.availability {
        case .available:
            await runUnifiedPipeline(lines: lines, llmBackend: .foundationModels)
        default:
            await populateWithLocalLLMOrClassifier(lines: lines)
        }
    }

    // 明示指定モード: Apple Intelligence のみ（利用不可の場合はエラー表示 + Classifier）
    @available(iOS 26.0, *)
    private func populateWithFoundationModelsOnly(lines: [RecognizedLine]) async {
        switch SystemLanguageModel.default.availability {
        case .available:
            await runUnifiedPipeline(lines: lines, llmBackend: .foundationModels)
        default:
            ocrErrorMessage = "Apple Intelligence が利用できません（設定を確認してください）。標準読み取りで処理しました。"
            await runUnifiedPipeline(lines: lines, llmBackend: .none)
        }
    }
    #endif

    // 明示指定モード: AIアシスト（Qwen）
    private func populateWithLocalLLMOnly(lines: [RecognizedLine]) async {
        guard LocalLLMService.shared.isModelAvailable else {
            ocrErrorMessage = "AIアシストのモデルが未取得です。設定からダウンロードしてください。標準読み取りで処理しました。"
            await runUnifiedPipeline(lines: lines, llmBackend: .none)
            return
        }
        await runUnifiedPipeline(lines: lines, llmBackend: .qwen)
    }

    // 自動モード: LocalLLM → Classifier のフォールバック
    private func populateWithLocalLLMOrClassifier(lines: [RecognizedLine]) async {
        if !LocalLLMService.shared.isModelAvailable {
            shouldPromptLLMDownload = true
            await runUnifiedPipeline(lines: lines, llmBackend: .none)
            return
        }
        await runUnifiedPipeline(lines: lines, llmBackend: .qwen)
    }

    private func populateWithClassifier(lines: [RecognizedLine]) {
        // Tier 3: ルールベースのみ（統一パイプラインの llmBackend: .none と同等だが同期版）
        let ruleResult = classifier.classifyStructuredFields(lines: lines)
        apply(ruleResult.parsed)
    }

    /// ParsedCard の内容をフォームフィールドに反映する共通ヘルパー
    private func apply(_ parsed: CardFieldClassifier.ParsedCard) {
        let lastR: String
        let firstR: String
        if !parsed.lastNameReading.isEmpty {
            // 優先1: フリガナ行（Classifier由来）
            lastR = parsed.lastNameReading
            firstR = parsed.firstNameReading.isEmpty
                ? NameReadingGenerator.generateReading(from: parsed.firstName) : parsed.firstNameReading
        } else if let emailReading = NameReadingGenerator.inferReadingFromEmail(
            email: parsed.email, lastName: parsed.lastName, firstName: parsed.firstName
        ) {
            // 優先2: メールアドレス由来
            lastR = emailReading.lastNameReading
            firstR = emailReading.firstNameReading
        } else {
            // 優先3: CFStringTokenizer
            lastR = NameReadingGenerator.generateReading(from: parsed.lastName)
            firstR = NameReadingGenerator.generateReading(from: parsed.firstName)
        }
        // 会社名読みは法人格を除いた読みで保存する（OCR/LLM由来でも除去する）
        let companyR: String = {
            let raw = parsed.companyReading.isEmpty
                ? NameReadingGenerator.generateReading(from: parsed.company)
                : parsed.companyReading
            return BusinessCard.stripLegalEntityReading(from: raw)
        }()
        apply(lastName: parsed.lastName, lastNameReading: lastR,
              firstName: parsed.firstName, firstNameReading: firstR,
              company: parsed.company, companyReading: companyR,
              department: parsed.department, title: parsed.title, phones: parsed.phones,
              email: parsed.email, address: parsed.address, website: parsed.website)
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

    func save() {
        let target = card ?? {
            let newCard = BusinessCard(context: context)
            newCard.id = UUID()
            newCard.createdAt = Date()
            return newCard
        }()

        target.lastName        = lastName.trimmingCharacters(in: .whitespacesAndNewlines)
        target.lastNameReading = lastNameReading.trimmingCharacters(in: .whitespacesAndNewlines)
        target.firstName       = firstName.trimmingCharacters(in: .whitespacesAndNewlines)
        target.firstNameReading = firstNameReading.trimmingCharacters(in: .whitespacesAndNewlines)
        target.company        = company.trimmingCharacters(in: .whitespacesAndNewlines)
        // 会社名読み：空なら自動生成、いずれの場合も法人格を除去して保存
        let companyReadingRaw = companyReading.trimmingCharacters(in: .whitespacesAndNewlines)
        let companyReadingFinal: String = {
            let raw = companyReadingRaw.isEmpty
                ? NameReadingGenerator.generateReading(from: company.trimmingCharacters(in: .whitespacesAndNewlines))
                : companyReadingRaw
            return BusinessCard.stripLegalEntityReading(from: raw)
        }()
        target.companyReading = companyReadingFinal
        target.department = department.trimmingCharacters(in: .whitespacesAndNewlines)
        target.title      = title.trimmingCharacters(in: .whitespacesAndNewlines)
        target.email     = email.trimmingCharacters(in: .whitespacesAndNewlines)
        target.phone     = phones
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        target.address   = address.trimmingCharacters(in: .whitespacesAndNewlines)
        target.website   = website.trimmingCharacters(in: .whitespacesAndNewlines)
        target.notes     = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        target.imageData = capturedImageData
        target.updatedAt = Date()

        // タグのリレーションを更新
        let tagRequest = Tag.fetchRequest()
        if let allTags = try? context.fetch(tagRequest) {
            // 既存のタグをすべて外す
            if let currentTags = target.tags as? Set<Tag> {
                for tag in currentTags {
                    target.removeFromTags(tag)
                }
            }
            // 選択されたタグを紐づけ
            for tag in allTags where selectedTags.contains(tag.id ?? UUID()) {
                target.addToTags(tag)
            }
        }

        do {
            try context.save()
        } catch {
            print("名刺の保存に失敗しました: \(error)")
        }
    }
}

// MARK: - ParsedCard（Foundation Models @Generable 定義）
#if canImport(FoundationModels)
@available(iOS 26.0, *)
@Generable
struct ParsedCard {
    @Guide(description: "姓（ファミリーネーム）。不明な場合は空文字列")          var lastName: String
    @Guide(description: "名（ファーストネーム）。不明な場合は空文字列")          var firstName: String
    @Guide(description: "会社名。不明な場合は空文字列")                          var company: String
    @Guide(description: "部署名。不明な場合は空文字列")                          var department: String
    @Guide(description: "役職。不明な場合は空文字列")                            var title: String
    @Guide(description: "電話番号。不明な場合は空文字列")                        var phone: String
    @Guide(description: "メールアドレス。不明な場合は空文字列")                  var email: String
    @Guide(description: "住所。不明な場合は空文字列")                            var address: String
    @Guide(description: "WebサイトURL。不明な場合は空文字列")                   var website: String
}
#endif
