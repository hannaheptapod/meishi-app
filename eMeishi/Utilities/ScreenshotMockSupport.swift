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
//   2. eMeishiApp が ScreenshotMode.startScreen を読み、Duplicate なら
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

    /// App Store スクリーンショット撮影の実行中か。
    /// 通常の UI テストは START_SCREEN を渡さないため、撮影専用の
    /// データ増強・Pro 表示・AI 結果モックはこの判定でだけ有効化する
    static var isCaptureRun: Bool {
        isActive && startScreen != nil
    }
}

/// スクリーンショット撮影用のモックデータ生成
enum ScreenshotMockSupport {

    // MARK: - モック名刺画像（CardFormView の OCR 直後プレビュー用）

    /// 撮影用のデザインバリエーション。実在企業を想起させない抽象配色に留める
    struct CardImageVariant {
        let company: String
        let department: String
        let title: String
        let name: String
        let contacts: [String]
        let accent: UIColor
        let layout: Int   // 0: 上部バー / 1: 左帯 / 2: ロゴ円
    }

    /// バリエーション指定つきの擬似名刺画像を生成する
    static func mockBusinessCardImage(variant v: CardImageVariant) -> UIImage {
        let size = CGSize(width: 1050, height: 600)
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { ctx in
            UIColor(white: 0.98, alpha: 1.0).setFill()
            ctx.fill(CGRect(origin: .zero, size: size))

            v.accent.setFill()
            switch v.layout {
            case 1:
                ctx.fill(CGRect(x: 0, y: 0, width: 14, height: size.height))
            case 2:
                ctx.cgContext.fillEllipse(in: CGRect(x: size.width - 150, y: 60, width: 80, height: 80))
            default:
                ctx.fill(CGRect(x: 0, y: 0, width: size.width, height: 12))
            }

            let companyAttrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 36, weight: .bold),
                .foregroundColor: UIColor.label
            ]
            (v.company as NSString).draw(at: CGPoint(x: 60, y: 70), withAttributes: companyAttrs)

            let subAttrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 22, weight: .regular),
                .foregroundColor: UIColor.secondaryLabel
            ]
            (v.department as NSString).draw(at: CGPoint(x: 60, y: 130), withAttributes: subAttrs)
            (v.title as NSString).draw(at: CGPoint(x: 60, y: 165), withAttributes: subAttrs)

            let nameAttrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 56, weight: .bold),
                .foregroundColor: UIColor.label
            ]
            (v.name as NSString).draw(at: CGPoint(x: 60, y: 220), withAttributes: nameAttrs)

            let contactAttrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 20, weight: .regular),
                .foregroundColor: UIColor.label
            ]
            for (i, line) in v.contacts.enumerated() {
                (line as NSString).draw(
                    at: CGPoint(x: 60, y: 360 + CGFloat(i) * 36),
                    withAttributes: contactAttrs
                )
            }
        }
    }

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

    // MARK: - 撮影用データ増強

    /// App Store スクリーンショット撮影時だけ、preview シードへ追加名刺を流し込む。
    ///
    /// 通常 UI テストは 9 件の基本シードに対する件数・並び順の assert を持つため、
    /// この増強は ScreenshotMode.isCaptureRun のときにしか呼ばない。
    /// - 一覧が埋まる件数（+24 枚・過去 5 ヶ月に分布）
    /// - インサイトの月別推移グラフが多点の折れ線になる分布
    /// - 大半の名刺へ擬似カード画像（サムネイル）を付与
    static func enrichPreviewForCapture(
        context: NSManagedObjectContext,
        baseCards: [BusinessCard],
        tags: [Tag]
    ) {
        let accents: [UIColor] = [
            .systemBlue, .systemTeal, .systemIndigo, .systemGreen,
            .systemOrange, .systemPurple, .systemBrown, .systemRed
        ]

        // (姓, 姓読み, 名, 名読み, 会社, 会社読み, 部署, 役職, 経過日数)
        // 経過日数は「今月がピークの右肩上がり」の月別推移になるよう、
        // 当月へ厚く・前月以前へ薄く分布させる（当月 12 + 基本シード、前月 5 前後）
        typealias Row = (String, String, String, String, String, String, String, String, Int)
        let rows: [Row] = [
            ("高橋", "たかはし", "健司", "けんじ",   "イプシロン医療株式会社",   "いぷしろんいりょう",   "医療情報部",     "システム課長",         0),
            ("伊藤", "いとう",   "真由", "まゆ",     "ゼータファイナンス株式会社","ぜーたふぁいなんす",  "財務部",         "主任",                 0),
            ("渡辺", "わたなべ", "拓也", "たくや",   "エータ教育株式会社",       "えーたきょういく",     "コンテンツ部",   "ディレクター",         1),
            ("小林", "こばやし", "剛",   "つよし",   "イオタ物流株式会社",       "いおたぶつりゅう",     "物流管理部",     "部長",                 1),
            ("加藤", "かとう",   "奈々", "なな",     "カッパ出版株式会社",       "かっぱしゅっぱん",     "編集部",         "編集長",               1),
            ("松本", "まつもと", "浩二", "こうじ",   "ラムダコンサルティング",   "らむだこんさるてぃんぐ","戦略部",        "シニアコンサルタント", 2),
            ("井上", "いのうえ", "千恵", "ちえ",     "ミュー保険株式会社",       "みゅーほけん",         "損害保険部",     "営業課長",             2),
            ("木村", "きむら",   "亮",   "りょう",   "ニューメディア株式会社",   "にゅーめでぃあ",       "広告部",         "ディレクター",         2),
            ("林",   "はやし",   "明美", "あけみ",   "クシー食品株式会社",       "くしーしょくひん",     "商品開発部",     "研究員",               3),
            ("清水", "しみず",   "大輔", "だいすけ", "オミクロンソフト株式会社", "おみくろんそふと",     "開発2部",        "テックリード",         3),
            ("山口", "やまぐち", "恵子", "けいこ",   "パイコンサルタンツ",       "ぱいこんさるたんつ",   "人事部",         "人事部長",             3),
            ("斎藤", "さいとう", "直樹", "なおき",   "ローエナジー株式会社",     "ろーえなじー",         "技術部",         "技術部長",             3),
            ("松田", "まつだ",   "由美", "ゆみ",     "シグマアパレル株式会社",   "しぐまあぱれる",       "デザイン部",     "パタンナー",           38),
            ("藤田", "ふじた",   "正人", "まさと",   "タウリクス株式会社",       "たうりくす",           "製品部",         "プロダクトマネージャー",44),
            ("岡田", "おかだ",   "麻衣", "まい",     "ウプシロン保険有限会社",   "うぷしろんほけん",     "総務部",         "総務課長",             50),
            ("後藤", "ごとう",   "博",   "ひろし",   "ファイテック株式会社",     "ふぁいてっく",         "品質管理部",     "QAエンジニア",         58),
            ("村田", "むらた",   "友美", "ともみ",   "カイアドバンス株式会社",   "かいあどばんす",       "マーケティング部","マネージャー",        66),
            ("坂本", "さかもと", "哲也", "てつや",   "プサイテクノロジー",       "ぷさいてくのろじー",   "AI研究部",       "主任研究員",           74),
            ("橋本", "はしもと", "百合子","ゆりこ",  "オメガリテール株式会社",   "おめがりてーる",       "店舗開発部",     "エリアマネージャー",   88),
            ("石田", "いしだ",   "修",   "おさむ",   "アルゴリズム株式会社",     "あるごりずむ",         "データ分析部",   "データサイエンティスト",96),
            ("藤井", "ふじい",   "香織", "かおり",   "バイオサイエンス株式会社", "ばいおさいえんす",     "研究開発部",     "研究員",               110),
            ("前田", "まえだ",   "慎一", "しんいち", "クラウドネット株式会社",   "くらうどねっと",       "インフラ部",     "インフラエンジニア",   118),
            ("小川", "おがわ",   "雅子", "まさこ",   "デジタルウェーブ",         "でじたるうぇーぶ",     "事業開発部",     "ビジネスデベロッパー", 132),
            ("池田", "いけだ",   "俊",   "しゅん",   "エコソリューションズ",     "えこそりゅーしょんず", "環境部",         "コンサルタント",       146),
        ]

        // ステータスバー固定（9:41）と登録日時表示を一致させる
        let calendar = Calendar(identifier: .gregorian)
        func capturedDate(daysAgo: Int) -> Date {
            let day = calendar.date(byAdding: .day, value: -daysAgo, to: Date()) ?? Date()
            return calendar.date(bySettingHour: 9, minute: 41, second: 0, of: day) ?? day
        }

        var enriched: [BusinessCard] = []
        for (i, r) in rows.enumerated() {
            let card = BusinessCard(context: context)
            card.id               = UUID()
            card.lastName         = r.0
            card.lastNameReading  = r.1
            card.firstName        = r.2
            card.firstNameReading = r.3
            card.company          = r.4
            card.companyReading   = r.5
            card.department       = r.6
            card.title            = r.7
            card.email            = "contact\(i)@example.com"
            card.phone            = String(format: "03-0000-%04d", i)
            card.createdAt        = capturedDate(daysAgo: r.8)
            card.updatedAt        = card.createdAt
            if i % 4 == 0 { card.isFavorite = true }
            if !tags.isEmpty { card.addToTags(tags[i % tags.count]) }
            enriched.append(card)
        }

        // 基本シードの登録時刻も 9:41 へ正規化する（詳細画面の登録日時が撮影時刻とズレないように）
        for card in baseCards {
            if let createdAt = card.createdAt {
                let normalized = calendar.date(
                    bySettingHour: 9, minute: 41, second: 0, of: createdAt
                ) ?? createdAt
                card.createdAt = normalized
                card.updatedAt = normalized
            }
        }

        // 重複チェック画面用：表記ゆれの重複候補を 2 組追加する（語彙ベース検出で拾える距離）
        let duplicateSeeds: [(BusinessCard, String)] = [
            (enriched[0], "イプシロン医療"),
            (enriched[9], "オミクロンソフト")
        ]
        for (original, alteredCompany) in duplicateSeeds {
            let dup = BusinessCard(context: context)
            dup.id               = UUID()
            dup.lastName         = original.lastName
            dup.lastNameReading  = original.lastNameReading
            dup.firstName        = original.firstName
            dup.firstNameReading = original.firstNameReading
            dup.company          = alteredCompany
            dup.companyReading   = original.companyReading
            dup.department       = original.department
            dup.title            = original.title
            dup.email            = original.email
            dup.phone            = original.phone
            dup.createdAt        = capturedDate(daysAgo: 160)
            dup.updatedAt        = dup.createdAt
            enriched.append(dup)
        }

        // サムネイル付与：基本シード + 追加分の大半に擬似画像を付ける
        // （4 枚に 1 枚だけイニシャル表示を残し、実運用らしい混在にする）
        let allCards = baseCards + enriched
        for (i, card) in allCards.enumerated() where i % 4 != 3 {
            let variant = CardImageVariant(
                company: card.company ?? "",
                department: card.department ?? "",
                title: card.title ?? "",
                name: "\(card.lastName ?? "") \(card.firstName ?? "")",
                contacts: [
                    "TEL  \(card.phone ?? "")",
                    "MAIL \(card.email ?? "")"
                ],
                accent: accents[i % accents.count],
                layout: i % 3
            )
            card.imageData = mockBusinessCardImage(variant: variant)
                .jpegData(compressionQuality: 0.82)
        }

        try? context.save()
    }

    // MARK: - モック CardFormViewModel（OCR 完了状態）

    /// OCR 直後の状態を再現した CardFormViewModel を返す
    /// 画像プレビュー＋全フィールド埋まり済み＋isProcessingOCR=false
    @MainActor
    static func makeMockOCRFinishedViewModel() -> CardFormViewModel {
        let context = PersistenceController.preview.container.viewContext
        let vm = CardFormViewModel(context: context)
        vm.setPreparedImageData(mockBusinessCardImage().jpegData(compressionQuality: 0.9))
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

}

// MARK: - スクリーンショット用ホストビュー

/// 一覧の重複候補状態に依存する画面を、単独のルートViewとして表示するホスト。
struct ScreenshotHostView: View {

    let screen: String
    @StateObject private var viewModel = CardListViewModel()
    @StateObject private var navigationState = AppNavigationState()

    var body: some View {
        NavigationStack {
            content
        }
        .environmentObject(viewModel)
        .environmentObject(navigationState)
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
        case "Duplicate":
            DuplicateListView(pairs: .constant(viewModel.duplicatePairs), onMerge: { })
        default:
            EmptyView()
        }
    }
}
