import XCTest

// MARK: - App Store スクリーンショット撮影ランナー
//
// 6 枚のスクリーンショットを 1 デバイス × 1 回のテスト実行で取得する。
// 各テストメソッドはアプリを `-UITestMode` + `START_SCREEN=<name>` で起動し、
// 該当画面が描画されるのを待ってから XCTAttachment として screenshot を保存する。
//
// 使い方:
//   xcodebuild test \
//     -scheme eMeishi \
//     -destination 'platform=iOS Simulator,id=<UDID>' \
//     -only-testing:eMeishiUITests/ScreenshotRunnerTests \
//     -resultBundlePath build/screenshots-<device>.xcresult
//
// 取得した PNG は `scripts/capture-shots.sh` が xcresulttool で抽出する。
//
// 命名規則: 01_form_ocr / 02_card_list / 03_ai_search / 04_insights /
//          05_duplicate / 06_tags
@MainActor
final class ScreenshotRunnerTests: XCTestCase {

    private var app: XCUIApplication!

    override func setUp() async throws {
        try await super.setUp()
        continueAfterFailure = false
        app = XCUIApplication()
    }

    override func tearDown() async throws {
        app = nil
        try await super.tearDown()
    }

    // MARK: - 共通ヘルパー

    /// 指定の START_SCREEN でアプリを起動する
    private func launchApp(startScreen: String) {
        app.launchArguments = ["-UITestMode"]
        app.launchEnvironment = ["START_SCREEN": startScreen]
        app.launch()
    }

    /// アプリの状態が落ち着くのを待つ（シート展開・onAppear 完了など）
    private func waitForUI(_ seconds: TimeInterval = 2.0) async {
        try? await Task.sleep(for: .seconds(seconds))
    }

    /// アプリ全体のスクリーンショットを XCTAttachment として保存
    private func saveScreenshot(named name: String) {
        let screenshot = app.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    // MARK: - 撮影テスト

    @MainActor
    func test01_FormOCR() async throws {
        launchApp(startScreen: "FormOCR")
        // CardFormView シートのナビゲーションタイトル「名刺を追加」が表示されるまで待つ
        let title = app.navigationBars["名刺を追加"]
        XCTAssertTrue(title.waitForExistence(timeout: 8))
        await waitForUI(1.5)
        saveScreenshot(named: "01_form_ocr")
    }

    @MainActor
    func test02_CardList() async throws {
        launchApp(startScreen: "List")
        XCTAssertTrue(app.buttons["selectButton"].waitForExistence(timeout: 8))
        await waitForUI(1.0)
        saveScreenshot(named: "02_card_list")
    }

    @MainActor
    func test03_UnifiedSearch() async throws {
        launchApp(startScreen: "AIChat")
        let searchField = app.searchFields.firstMatch
        XCTAssertTrue(searchField.waitForExistence(timeout: 8))
        await waitForUI(1.5)
        saveScreenshot(named: "03_ai_search")
    }

    @MainActor
    func test04_Insights() async throws {
        launchApp(startScreen: "Insights")
        let insightsTitle = app.navigationBars["インサイト"]
        XCTAssertTrue(insightsTitle.waitForExistence(timeout: 8))
        // 集計完了（バーが描画される）まで少し待つ
        await waitForUI(2.0)
        saveScreenshot(named: "04_insights")
    }

    @MainActor
    func test05_Duplicate() async throws {
        launchApp(startScreen: "Duplicate")
        let dupTitle = app.navigationBars["重複チェック"]
        XCTAssertTrue(dupTitle.waitForExistence(timeout: 8))
        await waitForUI(1.5)
        saveScreenshot(named: "05_duplicate")
    }

    @MainActor
    func test06_TagManagement() async throws {
        launchApp(startScreen: "Tags")
        let tagsTitle = app.navigationBars["タグ管理"]
        XCTAssertTrue(tagsTitle.waitForExistence(timeout: 8))
        await waitForUI(1.0)
        saveScreenshot(named: "06_tags")
    }

    // ASC Subscription の App Store Review Screenshot 用。
    // 通常の 6 枚とは別用途なので `07_paywall` として保存し、
    // capture-shots.sh 経由で抽出後に `asc subscriptions review screenshots create` でアップロードする。
    @MainActor
    func test07_Paywall() async throws {
        launchApp(startScreen: "Paywall")
        let paywallNav = app.navigationBars["eMeishi Pro"]
        XCTAssertTrue(paywallNav.waitForExistence(timeout: 8))
        // StoreKit Configuration の商品ロード完了を待つ
        await waitForUI(3.0)
        saveScreenshot(named: "07_paywall")
    }
}
