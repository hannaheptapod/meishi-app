import XCTest

// MARK: - 名刺アプリ UIテスト

@MainActor
final class EMeishiUITests: XCTestCase {

    private var app: XCUIApplication!

    override func setUp() async throws {
        try await super.setUp()
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
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

    /// LazyVStack でまだ生成されていない行を、限定回数スクロールして探す。
    private func waitForCardRow(_ name: String, maxSwipes: Int = 3) -> Bool {
        let row = cardRow(name)
        if row.waitForExistence(timeout: Self.shortTimeout) { return true }

        for _ in 0..<maxSwipes {
            app.swipeUp()
            if row.waitForExistence(timeout: 1) { return true }
        }
        return false
    }

    /// CI の表示領域差で下位行がまだ materialize されない場合があるため、
    /// コンテキストメニュー系は先頭付近の安定して見えるカードを使う。
    private var stableVisibleCardName: String { "山田 太郎" }

    /// confirmationDialog が表示されているか（iOS 26: sheetとして表示される）
    private func confirmationDialogIsPresented() -> Bool {
        app.sheets.count > 0
    }

    /// SwiftUI Menu は端末によって identifier が伝播しない場合があるため、表示ラベルも使う。
    private func waitForMenuItem(identifier: String, label: String) -> Bool {
        let predicate = NSPredicate(
            format: "identifier == %@ OR label == %@",
            identifier,
            label
        )
        return app.descendants(matching: .any)
            .matching(predicate)
            .firstMatch
            .waitForExistence(timeout: Self.defaultTimeout)
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
        XCTAssertTrue(waitForCardRow("山田 花子"))
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
        let card = cardRow(stableVisibleCardName)
        showContextMenu(for: card)

        // コンテキストメニューの項目が表示される
        XCTAssertTrue(
            app.buttons["お気に入りに追加"].waitForExistence(timeout: Self.shortTimeout)
            || app.buttons["お気に入り解除"].waitForExistence(timeout: Self.shortTimeout)
        )
        XCTAssertTrue(app.buttons["編集"].exists)
        XCTAssertTrue(app.buttons["vCardとして共有"].exists)
        XCTAssertTrue(app.buttons["連絡先に保存"].exists)
        XCTAssertTrue(app.buttons["削除"].exists)
    }

    @MainActor
    func testContextMenuFavoriteToggle() throws {
        let card = cardRow(stableVisibleCardName)
        showContextMenu(for: card)

        let addFavoriteButton = app.buttons["お気に入りに追加"]
        let removeFavoriteButton = app.buttons["お気に入り解除"]
        let wasFavorite = removeFavoriteButton.waitForExistence(timeout: Self.shortTimeout)
        if wasFavorite {
            removeFavoriteButton.tap()
        } else {
            XCTAssertTrue(addFavoriteButton.waitForExistence(timeout: Self.shortTimeout))
            addFavoriteButton.tap()
        }

        // 再度長押ししてトグル後の文言になっていることを確認
        // コンテキストメニューが閉じるのを待つ
        XCTAssertTrue(card.waitForExistence(timeout: Self.shortTimeout))
        showContextMenu(for: card)
        let expectedIdentifier = wasFavorite ? "お気に入りに追加" : "お気に入り解除"
        XCTAssertTrue(app.buttons[expectedIdentifier].waitForExistence(timeout: Self.shortTimeout))

        // メニューを閉じる（背景タップ）
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.1)).tap()
    }

    @MainActor
    func testContextMenuDeleteShowsConfirmation() throws {
        let card = cardRow(stableVisibleCardName)
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
        XCTAssertTrue(cardRow(stableVisibleCardName).waitForExistence(timeout: Self.shortTimeout))
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
        // iOS 26 の SwiftUI Menu は要素種別や identifier の伝播が端末構成で異なるため、
        // identifier または表示ラベルで項目を確認する
        XCTAssertTrue(
            waitForMenuItem(identifier: "importFromContacts", label: "連絡先からインポート")
        )
        XCTAssertTrue(
            waitForMenuItem(identifier: "tagManager", label: "タグ管理")
        )
        XCTAssertTrue(
            waitForMenuItem(identifier: "settingsMenu", label: "設定")
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
