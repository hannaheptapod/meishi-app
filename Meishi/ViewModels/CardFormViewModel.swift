import Foundation
import CoreData
import Combine
import UIKit
// import FoundationModels  // フレームワーク未リンクのためコメントアウト

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
                // FoundationModels 未リンクのため LocalLLM → Classifier にフォールバック
                await populateWithLocalLLMOrClassifier(lines: lines)
            case .appleIntelligence:
                // FoundationModels 未リンクのため Classifier で代替
                ocrErrorMessage = "Apple Intelligence は現在利用できません。標準読み取りで処理しました。"
                populateWithClassifier(lines: lines)
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

    // 自動モード: Foundation Models → Classifier の順にフォールバック
    // FoundationModels framework 未リンクのためコメントアウト
//    @available(iOS 18.0, *)
//    private func populateWithFoundationModels(lines: [RecognizedLine]) async {
//        switch SystemLanguageModel.default.availability {
//        case .available:
//            do {
//                try await runFoundationModels(lines: lines)
//            } catch {
//                populateWithClassifier(lines: lines)
//            }
//        default:
//            populateWithClassifier(lines: lines)
//        }
//    }

    // 明示指定モード: Apple Intelligence のみ（利用不可の場合はエラー表示 + Classifier）
    // FoundationModels framework 未リンクのためコメントアウト
//    @available(iOS 18.0, *)
//    private func populateWithFoundationModelsOnly(lines: [RecognizedLine]) async {
//        switch SystemLanguageModel.default.availability {
//        case .available:
//            do {
//                try await runFoundationModels(lines: lines)
//            } catch {
//                ocrErrorMessage = "Apple Intelligence での処理に失敗しました。標準読み取りで処理しました。"
//                populateWithClassifier(lines: lines)
//            }
//        default:
//            ocrErrorMessage = "Apple Intelligence が利用できません（設定を確認してください）。標準読み取りで処理しました。"
//            populateWithClassifier(lines: lines)
//        }
//    }

    // FoundationModels framework 未リンクのためコメントアウト
//    @available(iOS 18.0, *)
//    private func runFoundationModels(lines: [RecognizedLine]) async throws {
//        let rawText = lines.map { $0.text }.joined(separator: "\n")
//        let session = LanguageModelSession()
//        let prompt = """
//            以下は名刺から読み取ったテキストです。各フィールドに分類してください。
//            姓と名は必ず分けてください。
//            \(rawText)
//            """
//        let response = try await session.respond(to: prompt, generating: ParsedCard.self)
//        let p = response.content
//        apply(lastName: p.lastName,
//              lastNameReading: Self.generateReading(from: p.lastName),
//              firstName: p.firstName,
//              firstNameReading: Self.generateReading(from: p.firstName),
//              company: p.company,
//              companyReading: Self.generateReading(from: p.company),
//              department: p.department, title: p.title,
//              phones: p.phone.isEmpty ? [] : [p.phone],
//              email: p.email, address: p.address, website: p.website)
//    }

    // 明示指定モード: AIアシストのみ（未取得・失敗時はエラー表示 + Classifier）
    private func populateWithLocalLLMOnly(lines: [RecognizedLine]) async {
        guard LocalLLMService.shared.isModelAvailable else {
            ocrErrorMessage = "AIアシストのモデルが未取得です。設定からダウンロードしてください。標準読み取りで処理しました。"
            populateWithClassifier(lines: lines)
            return
        }
        if let parsed = await LocalLLMService.shared.classify(lines: lines.map { $0.text }) {
            apply(parsed)
        } else {
            ocrErrorMessage = "AIアシストでの処理に失敗しました。標準読み取りで処理しました。"
            populateWithClassifier(lines: lines)
        }
    }

    // 自動モード: LocalLLM → Classifier のフォールバック
    private func populateWithLocalLLMOrClassifier(lines: [RecognizedLine]) async {
        if !LocalLLMService.shared.isModelAvailable {
            shouldPromptLLMDownload = true
            populateWithClassifier(lines: lines)
            return
        }
        if let parsed = await LocalLLMService.shared.classify(lines: lines.map { $0.text }) {
            apply(parsed)
        } else {
            populateWithClassifier(lines: lines)
        }
    }

    private func populateWithClassifier(lines: [RecognizedLine]) {
        apply(classifier.classify(lines: lines))
    }

    /// ParsedCard の内容をフォームフィールドに反映する共通ヘルパー
    private func apply(_ parsed: CardFieldClassifier.ParsedCard) {
        let lastR    = parsed.lastNameReading.isEmpty
            ? Self.generateReading(from: parsed.lastName)
            : parsed.lastNameReading
        let firstR   = parsed.firstNameReading.isEmpty
            ? Self.generateReading(from: parsed.firstName)
            : parsed.firstNameReading
        // 会社名読みはフル社名から生成（法人格の除去はソートキー生成時のみ）
        let companyR = parsed.companyReading.isEmpty
            ? Self.generateReading(from: parsed.company)
            : parsed.companyReading
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

    // MARK: - 読み仮名自動生成

    /// CFStringTokenizer のラテン転写属性からひらがな読みを生成する
    static func generateReading(from text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        // ひらがな・カタカナのみなら変換不要でそのまま返す（カタカナはひらがなへ）
        if trimmed.unicodeScalars.allSatisfy({ (0x3040...0x30FF).contains($0.value) || $0.value == 0x20 || $0.value == 0x3000 }) {
            let mutable = NSMutableString(string: trimmed)
            CFStringTransform(mutable, nil, kCFStringTransformHiraganaKatakana, true)
            return mutable as String
        }

        // ASCII のみ（英語名など）はそのまま返す
        if trimmed.unicodeScalars.allSatisfy({ $0.isASCII }) { return trimmed }

        let cfText   = trimmed as CFString
        let cfLocale = Locale(identifier: "ja_JP") as CFLocale
        guard let tokenizer = CFStringTokenizerCreate(
            kCFAllocatorDefault, cfText,
            CFRangeMake(0, CFStringGetLength(cfText)),
            kCFStringTokenizerUnitWord, cfLocale
        ) else { return trimmed }

        var result = ""
        while CFStringTokenizerAdvanceToNextToken(tokenizer).rawValue != 0 {
            if let latin = CFStringTokenizerCopyCurrentTokenAttribute(
                tokenizer, kCFStringTokenizerAttributeLatinTranscription
            ) as? String {
                let mutable = NSMutableString(string: latin)
                CFStringTransform(mutable, nil, kCFStringTransformLatinHiragana, false)
                result += mutable as String
            } else {
                let cfRange = CFStringTokenizerGetCurrentTokenRange(tokenizer)
                let nsRange = NSRange(location: cfRange.location, length: cfRange.length)
                if let swiftRange = Range(nsRange, in: trimmed) {
                    result += String(trimmed[swiftRange])
                }
            }
        }
        return result
    }

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
        target.companyReading = companyReading.trimmingCharacters(in: .whitespacesAndNewlines)
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

        do {
            try context.save()
        } catch {
            print("名刺の保存に失敗しました: \(error)")
        }
    }
}

// MARK: - ParsedCard（Foundation Models @Generable 定義）
// FoundationModels framework 未リンクのためコメントアウト
//@Generable
//struct ParsedCard {
//    @Guide(description: "姓（ファミリーネーム）")          var lastName: String
//    @Guide(description: "名（ファーストネーム）")          var firstName: String
//    @Guide(description: "会社名")                          var company: String
//    @Guide(description: "部署名（営業部・zzz課など）")    var department: String
//    @Guide(description: "役職（部長・Directorなど）")      var title: String
//    @Guide(description: "電話番号")                        var phone: String
//    @Guide(description: "メールアドレス")                  var email: String
//    @Guide(description: "住所")                            var address: String
//    @Guide(description: "WebサイトURL")                   var website: String
//}
