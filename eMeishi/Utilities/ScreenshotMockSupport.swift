import SwiftUI
import UIKit
import CoreData

// App Store スクリーンショット撮影用のモックサポート
//
// XCUITest（ScreenshotRunner）が `-UITestMode` 引数 + `START_SCREEN` 環境変数を
// 渡してアプリを起動した場合のみ動作する。本番ビルドからは触られない。
//
// 起動経路:
//   1. XCUITest が `app.launchEnvironment["START_SCREEN"] = "FormOCR"` などをセット
//   2. eMeishiApp が ScreenshotMode.startScreen を読み、Insights/Duplicate なら
//      ScreenshotHostView へ、それ以外は通常 ContentView へルーティング
//   3. CardListView.onAppear が START_SCREEN に応じて該当シートを開く
/// XCUITest 起動引数・環境変数の検出
enum ScreenshotMode {

    static var isActive: Bool {
        ProcessInfo.processInfo.arguments.contains("-UITestMode")
    }

    static var startScreen: String? {
        ProcessInfo.processInfo.environment["START_SCREEN"]
    }
}

/// スクリーンショット撮影用のモックデータ生成
enum ScreenshotMockSupport {

    // MARK: - モック名刺画像（CardFormView の OCR 直後プレビュー用）

    /// 白背景＋会社ロゴ風の擬似名刺画像をプログラム生成する
    /// 実画像をバンドルしないことで、ライセンス・肖像権の懸念を回避する
    static func mockBusinessCardImage() -> UIImage {
        let size = CGSize(width: 1050, height: 600) // 名刺の比率 1.75:1
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { ctx in
            // 背景：オフホワイト
            UIColor(white: 0.98, alpha: 1.0).setFill()
            ctx.fill(CGRect(origin: .zero, size: size))

            // 上部アクセントライン
            UIColor.systemBlue.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: size.width, height: 12))

            // 会社名
            let companyAttrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 36, weight: .bold),
                .foregroundColor: UIColor.label
            ]
            ("株式会社テックビジョン" as NSString).draw(
                at: CGPoint(x: 60, y: 70), withAttributes: companyAttrs
            )

            // 部署
            let deptAttrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 22, weight: .regular),
                .foregroundColor: UIColor.secondaryLabel
            ]
            ("営業部" as NSString).draw(
                at: CGPoint(x: 60, y: 130), withAttributes: deptAttrs
            )

            // 役職
            let titleAttrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 22, weight: .regular),
                .foregroundColor: UIColor.secondaryLabel
            ]
            ("営業部長" as NSString).draw(
                at: CGPoint(x: 60, y: 165), withAttributes: titleAttrs
            )

            // 氏名
            let nameAttrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 56, weight: .bold),
                .foregroundColor: UIColor.label
            ]
            ("山田 太郎" as NSString).draw(
                at: CGPoint(x: 60, y: 220), withAttributes: nameAttrs
            )

            // 連絡先
            let contactAttrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 20, weight: .regular),
                .foregroundColor: UIColor.label
            ]
            let lines = [
                "TEL  03-1234-5678",
                "MAIL yamada.taro@techvision.co.jp",
                "WEB  techvision.co.jp",
                "ADDR 東京都千代田区丸の内 1-2-3"
            ]
            for (i, line) in lines.enumerated() {
                (line as NSString).draw(
                    at: CGPoint(x: 60, y: 360 + CGFloat(i) * 36),
                    withAttributes: contactAttrs
                )
            }
        }
    }

    // MARK: - モック CardFormViewModel（OCR 完了状態）

    /// OCR 直後の状態を再現した CardFormViewModel を返す
    /// 画像プレビュー＋全フィールド埋まり済み＋isProcessingOCR=false
    @MainActor
    static func makeMockOCRFinishedViewModel() -> CardFormViewModel {
        let context = PersistenceController.preview.container.viewContext
        let vm = CardFormViewModel(context: context)
        vm.capturedImageData = mockBusinessCardImage().jpegData(compressionQuality: 0.9)
        vm.lastName = "山田"
        vm.lastNameReading = "やまだ"
        vm.firstName = "太郎"
        vm.firstNameReading = "たろう"
        vm.company = "株式会社テックビジョン"
        vm.companyReading = "てっくびじょん"
        vm.department = "営業部"
        vm.title = "営業部長"
        vm.email = "yamada.taro@techvision.co.jp"
        vm.phones = ["03-1234-5678"]
        vm.address = "東京都千代田区丸の内 1-2-3"
        vm.website = "techvision.co.jp"
        vm.isProcessingOCR = false
        return vm
    }

    // MARK: - モックチャット（AISearchChatView 用）

    /// 「IT 関連の担当者を探して」 → アシスタント応答 のサンプル会話
    /// 「IT」タグが付いたカードのみを対象にすることで、
    /// 重複検出デモ用カード（タグ無し）が結果に混ざらないようにする
    static func mockChatMessages(cards: [BusinessCard]) -> [AISearchService.ChatMessage] {
        let matched: [BusinessCard] = cards.filter { card in
            let tags = (card.tags as? Set<Tag>) ?? []
            return tags.contains(where: { $0.name == "IT" })
        }
        let matchedIDs: [UUID] = matched.compactMap { $0.id }

        let user = AISearchService.ChatMessage(
            role: .user,
            text: "IT 関連の担当者を探して",
            matchedCardIDs: []
        )
        let assistant = AISearchService.ChatMessage(
            role: .assistant,
            text: "「IT」タグが付いた名刺を \(matchedIDs.count) 件見つけました。",
            matchedCardIDs: matchedIDs
        )
        return [user, assistant]
    }
}

// MARK: - スクリーンショット用ホストビュー

/// Insights / Duplicate のように NavigationLink で push される画面を
/// 単独のルート View として表示するためのホスト
struct ScreenshotHostView: View {

    let screen: String
    @StateObject private var viewModel = CardListViewModel()

    var body: some View {
        NavigationStack {
            content
        }
        .environmentObject(viewModel)
        .onAppear {
            // 重複検出はサンプルデータがロードされてから走らせる
            if screen == "Duplicate" && viewModel.duplicatePairs.isEmpty {
                viewModel.detectDuplicates()
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch screen {
        case "Insights":
            InsightsView()
        case "Duplicate":
            DuplicateListView(pairs: .constant(viewModel.duplicatePairs), onMerge: { })
        default:
            EmptyView()
        }
    }
}
