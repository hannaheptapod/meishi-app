import XCTest

// MARK: - 名刺アプリ UIテスト

@MainActor
final class EMeishiUITests: XCTestCase {

    private var app: XCUIApplication!

    override func setUp() async throws {
        try await super.setUp()
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-UITestMode"]
        app.launch()
    }

    override func tearDown() async throws {
        app = nil
        try await super.tearDown()
    }

    // MARK: - ヘルパー

    /// カード行をアクセシビリティIDで取得（.accessibilityElement(children: .combine) 対応）
    private func cardRow(_ name: String) -> XCUIElement {
        app.descendants(matching: .any)["cardRow_\(name)"]
    }

    /// confirmationDialog が表示されているか（iOS 26: sheetとして表示される）
    private func confirmationDialogIsPresented() -> Bool {
        app.sheets.count > 0
    }

    /// SwiftUI Menu の項目を取得する（iOS 26 で menuItems として公開される場合がある）
    private func menuItem(identifier: String) -> XCUIElement {
        let asButton = app.buttons[identifier]
        if asButton.exists { return asButton }
        let asMenuItem = app.menuItems[identifier]
        if asMenuItem.exists { return asMenuItem }
        // どちらにも見つからない場合は descendants 全体から探す
        return app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    /// confirmationDialog を閉じる（iOS 26: キャンセルボタンが非表示のためシート外タップで閉じる）
    private func dismissConfirmationDialog() {
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.1)).tap()
    }

    // タイムアウト定数
    private static let defaultTimeout: TimeInterval = 5
    private static let shortTimeout: TimeInterval = 3

    /// 選択モードに入る（共通ヘルパー）
    @MainActor
    private func enterSelectionMode() {
        let selectButton = app.buttons["selectButton"]
        XCTAssertTrue(selectButton.waitForExistence(timeout: Self.defaultTimeout))
        selectButton.tap()
        XCTAssertTrue(app.buttons["doneButton"].waitForExistence(timeout: Self.shortTimeout))
    }

    /// コンテキストメニューを表示する（共通ヘルパー）
    @MainActor
    private func showContextMenu(for element: XCUIElement) {
        XCTAssertTrue(element.waitForExistence(timeout: Self.defaultTimeout))
        element.press(forDuration: 1.5)
    }

    // MARK: - 起動・一覧表示

    @MainActor
    func testLaunchShowsCardList() throws {
        // カード一覧画面が表示される（ツールバーの選択ボタンが存在する）
        XCTAssertTrue(app.buttons["selectButton"].waitForExistence(timeout: 5))
        // サンプルデータのカードが表示される
        XCTAssertTrue(cardRow("山田 太郎").waitForExistence(timeout: 5))
    }

    @MainActor
    func testCardListShowsCards() throws {
        // サンプルデータのカード名が表示される（上位2件を確認）
        XCTAssertTrue(cardRow("山田 太郎").waitForExistence(timeout: 5))
        XCTAssertTrue(cardRow("山田 花子").exists)
    }

    // MARK: - ツールバーボタンの存在確認

    @MainActor
    func testToolbarButtonsExist() throws {
        // 選択ボタン
        let selectButton = app.buttons["selectButton"]
        XCTAssertTrue(selectButton.waitForExistence(timeout: 5))

        // 追加ボタン
        let addButton = app.buttons["addButton"]
        XCTAssertTrue(addButton.exists)

        // 3点メニュー
        let ellipsisMenu = app.buttons["ellipsisMenu"]
        XCTAssertTrue(ellipsisMenu.exists)
    }

    // MARK: - 選択モード

    @MainActor
    func testEnterSelectionMode() throws {
        enterSelectionMode()

        // すべて選択ボタンが表示される
        XCTAssertTrue(app.buttons["selectAllButton"].exists)

        // ナビゲーションタイトルが「項目を選択」になる
        XCTAssertTrue(app.navigationBars.staticTexts["項目を選択"].waitForExistence(timeout: Self.shortTimeout))

        // 一括削除ボタンが表示される
        XCTAssertTrue(app.buttons["bulkDeleteButton"].exists)
    }

    @MainActor
    func testExitSelectionMode() throws {
        enterSelectionMode()

        // 完了ボタンで抜ける
        app.buttons["doneButton"].tap()

        // 選択ボタンが再び表示される
        XCTAssertTrue(app.buttons["selectButton"].waitForExistence(timeout: Self.shortTimeout))
    }

    @MainActor
    func testSelectAllAndDeselectAll() throws {
        enterSelectionMode()

        // すべて選択
        let selectAllButton = app.buttons["selectAllButton"]
        XCTAssertTrue(selectAllButton.waitForExistence(timeout: Self.shortTimeout))
        selectAllButton.tap()

        // ナビゲーションタイトルに「件選択中」が表示される
        let selectionPredicate = NSPredicate(format: "label CONTAINS '件選択中'")
        let selectionText = app.navigationBars.staticTexts.matching(selectionPredicate).firstMatch
        XCTAssertTrue(selectionText.waitForExistence(timeout: Self.shortTimeout))

        // 全解除ボタンに変わっている
        XCTAssertTrue(app.buttons["selectAllButton"].label == "全解除")

        // 全解除
        app.buttons["selectAllButton"].tap()

        // ナビゲーションタイトルが「項目を選択」に戻る
        XCTAssertTrue(app.navigationBars.staticTexts["項目を選択"].waitForExistence(timeout: Self.shortTimeout))
    }

    @MainActor
    func testSelectionModeHidesDeleteIcons() throws {
        enterSelectionMode()

        // 赤丸の削除ボタンが表示されていないことを確認
        // .onDelete による削除ボタンは "Delete" アクセシビリティラベルを持つ
        let deleteControls = app.buttons.matching(identifier: "Delete")
        XCTAssertEqual(deleteControls.count, 0, "選択モード時に行ごとの削除アイコンが表示されてはいけない")
    }

    // MARK: - カード詳細への遷移

    @MainActor
    func testNavigateToCardDetail() throws {
        // カードをタップして詳細画面に遷移
        let card = cardRow("山田 太郎")
        XCTAssertTrue(card.waitForExistence(timeout: 5))
        card.tap()

        // 詳細画面のナビゲーションタイトルが表示される
        XCTAssertTrue(app.navigationBars.staticTexts["山田 太郎"].waitForExistence(timeout: 3))
    }

    @MainActor
    func testNavigateBackNoHighlightPersistence() throws {
        // カードをタップして詳細に遷移
        let card = cardRow("山田 太郎")
        XCTAssertTrue(card.waitForExistence(timeout: 5))
        card.tap()

        // 詳細画面が表示される
        XCTAssertTrue(app.navigationBars.staticTexts["山田 太郎"].waitForExistence(timeout: 3))

        // 戻る
        app.navigationBars.buttons.element(boundBy: 0).tap()

        // リスト画面に戻ったことを確認（選択ボタンが表示される）
        XCTAssertTrue(app.buttons["selectButton"].waitForExistence(timeout: 3))
    }

    // MARK: - コンテキストメニュー（長押し）

    @MainActor
    func testLongPressShowsContextMenu() throws {
        // 非お気に入りの山田花子を使用（山田太郎はpreviewデータでisFavorite=true）
        let card = cardRow("山田 花子")
        showContextMenu(for: card)

        // コンテキストメニューの項目が表示される
        XCTAssertTrue(app.buttons["お気に入りに追加"].waitForExistence(timeout: Self.shortTimeout))
        XCTAssertTrue(app.buttons["編集"].exists)
        XCTAssertTrue(app.buttons["vCardとして共有"].exists)
        XCTAssertTrue(app.buttons["連絡先に保存"].exists)
        XCTAssertTrue(app.buttons["削除"].exists)
    }

    @MainActor
    func testContextMenuFavoriteToggle() throws {
        // 非お気に入り→お気に入りへのトグルを検証するので、初期状態が非お気に入りのカードを使う
        let card = cardRow("山田 花子")
        showContextMenu(for: card)

        // お気に入りに追加
        let favoriteButton = app.buttons["お気に入りに追加"]
        XCTAssertTrue(favoriteButton.waitForExistence(timeout: Self.shortTimeout))
        favoriteButton.tap()

        // 再度長押しして「お気に入り解除」になっていることを確認
        // コンテキストメニューが閉じるのを待つ
        XCTAssertTrue(card.waitForExistence(timeout: Self.shortTimeout))
        showContextMenu(for: card)
        XCTAssertTrue(app.buttons["お気に入り解除"].waitForExistence(timeout: Self.shortTimeout))

        // メニューを閉じる（背景タップ）
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.1)).tap()
    }

    @MainActor
    func testContextMenuDeleteShowsConfirmation() throws {
        // カードを長押し（リスト上位のカードを使用：Landscape対応）
        let card = cardRow("山田 花子")
        showContextMenu(for: card)

        // コンテキストメニューの削除をタップ
        let deleteButton = app.buttons["削除"]
        XCTAssertTrue(deleteButton.waitForExistence(timeout: Self.shortTimeout))
        deleteButton.tap()

        // 確認ダイアログ（confirmationDialog）がシートとして表示される
        XCTAssertTrue(app.sheets.firstMatch.waitForExistence(timeout: Self.shortTimeout),
                      "削除の確認ダイアログが表示されるべき")

        // シート外タップで閉じる
        dismissConfirmationDialog()

        // カードがまだ存在する
        XCTAssertTrue(cardRow("山田 花子").waitForExistence(timeout: Self.shortTimeout))
    }

    // MARK: - 一括削除

    @MainActor
    func testBulkDeleteConfirmation() throws {
        enterSelectionMode()

        // すべて選択
        let selectAllButton = app.buttons["selectAllButton"]
        XCTAssertTrue(selectAllButton.waitForExistence(timeout: Self.shortTimeout))
        selectAllButton.tap()

        // ナビゲーションタイトルに「件選択中」が表示されるのを待つ（選択状態の反映を確認）
        let countPredicate = NSPredicate(format: "label CONTAINS '件選択中'")
        let countText = app.navigationBars.staticTexts.matching(countPredicate).firstMatch
        XCTAssertTrue(countText.waitForExistence(timeout: Self.shortTimeout))

        // 一括削除ボタンをタップ
        let bulkDeleteButton = app.buttons["bulkDeleteButton"]
        XCTAssertTrue(bulkDeleteButton.waitForExistence(timeout: Self.shortTimeout))
        bulkDeleteButton.tap()

        // 確認ダイアログ（confirmationDialog）がシートとして表示される
        XCTAssertTrue(app.sheets.firstMatch.waitForExistence(timeout: Self.shortTimeout),
                      "一括削除の確認ダイアログが表示されるべき")

        // シート外タップで閉じる
        dismissConfirmationDialog()
    }

    // MARK: - 検索

    @MainActor
    func testSearchFiltersCards() throws {
        // 検索バーをタップ
        let searchField = app.searchFields.firstMatch
        XCTAssertTrue(searchField.waitForExistence(timeout: 5))
        searchField.tap()
        searchField.typeText("山田")

        // 山田の名刺が表示される
        XCTAssertTrue(app.staticTexts["山田 太郎"].waitForExistence(timeout: 3))

        // 佐藤は非表示
        XCTAssertFalse(app.staticTexts["佐藤 誠"].exists)
    }

    // MARK: - 3点メニュー

    @MainActor
    func testEllipsisMenuShowsOptions() throws {
        let ellipsisMenu = app.buttons["ellipsisMenu"]
        XCTAssertTrue(ellipsisMenu.waitForExistence(timeout: Self.defaultTimeout))
        ellipsisMenu.tap()

        // メニュー項目が表示される
        // iOS 26 の SwiftUI Menu では buttons / menuItems のどちらで公開されるか
        // バージョンによって異なるため、accessibilityIdentifier を付与した上で両方を探す
        XCTAssertTrue(
            menuItem(identifier: "importFromContacts").waitForExistence(timeout: Self.defaultTimeout)
        )
        XCTAssertTrue(
            menuItem(identifier: "tagManager").waitForExistence(timeout: Self.shortTimeout)
        )
        XCTAssertTrue(
            menuItem(identifier: "settingsMenu").waitForExistence(timeout: Self.shortTimeout)
        )
    }

    // MARK: - フィルタ時のカウント表示

    @MainActor
    func testSearchShowsFilteredResults() throws {
        // 検索バーで検索すると該当カードのみが表示される
        let searchField = app.searchFields.firstMatch
        XCTAssertTrue(searchField.waitForExistence(timeout: 5))
        searchField.tap()
        searchField.typeText("山田")

        // 検索結果に「山田」を含むカードが表示される
        XCTAssertTrue(cardRow("山田 太郎").waitForExistence(timeout: 3))
        XCTAssertTrue(cardRow("山田 花子").exists)
        XCTAssertTrue(cardRow("山田 健一").exists)

        // 「山田」を含まないカードは非表示
        XCTAssertFalse(cardRow("佐藤 誠").exists)
        XCTAssertFalse(cardRow("鈴木 一郎").exists)
    }
}
