import XCTest

// MARK: - 名刺アプリ UIテスト

final class EMeishiUITests: XCTestCase {

    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-UITestMode"]
        app.launch()
    }

    override func tearDownWithError() throws {
        app = nil
    }

    // MARK: - 起動・一覧表示

    @MainActor
    func testLaunchShowsCardList() throws {
        // ナビゲーションタイトル「名刺」が表示される
        XCTAssertTrue(app.navigationBars.staticTexts["名刺"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testCardListShowsCards() throws {
        // サンプルデータのカード名が表示される
        XCTAssertTrue(app.staticTexts["山田 太郎"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["佐藤 誠"].exists)
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
        let selectButton = app.buttons["selectButton"]
        XCTAssertTrue(selectButton.waitForExistence(timeout: 5))
        selectButton.tap()

        // 完了ボタンが表示される
        let doneButton = app.buttons["doneButton"]
        XCTAssertTrue(doneButton.waitForExistence(timeout: 3))

        // すべて選択ボタンが表示される
        let selectAllButton = app.buttons["selectAllButton"]
        XCTAssertTrue(selectAllButton.exists)

        // ガイドテキストが表示される
        let guideText = app.staticTexts["selectionGuideText"]
        XCTAssertTrue(guideText.exists)

        // 一括削除ボタンが表示される
        let bulkDeleteButton = app.buttons["bulkDeleteButton"]
        XCTAssertTrue(bulkDeleteButton.exists)
    }

    @MainActor
    func testExitSelectionMode() throws {
        // 選択モードに入る
        let selectButton = app.buttons["selectButton"]
        XCTAssertTrue(selectButton.waitForExistence(timeout: 5))
        selectButton.tap()

        // 完了ボタンで抜ける
        let doneButton = app.buttons["doneButton"]
        XCTAssertTrue(doneButton.waitForExistence(timeout: 3))
        doneButton.tap()

        // 選択ボタンが再び表示される
        XCTAssertTrue(selectButton.waitForExistence(timeout: 3))
    }

    @MainActor
    func testSelectAllAndDeselectAll() throws {
        // 選択モードに入る
        let selectButton = app.buttons["selectButton"]
        XCTAssertTrue(selectButton.waitForExistence(timeout: 5))
        selectButton.tap()

        // すべて選択
        let selectAllButton = app.buttons["selectAllButton"]
        XCTAssertTrue(selectAllButton.waitForExistence(timeout: 3))
        selectAllButton.tap()

        // 選択件数テキストが表示される
        let countText = app.staticTexts["selectionCountText"]
        XCTAssertTrue(countText.waitForExistence(timeout: 3))

        // 全解除ボタンに変わっている
        XCTAssertTrue(app.buttons["selectAllButton"].label == "全解除")

        // 全解除
        app.buttons["selectAllButton"].tap()

        // ガイドテキストに戻る
        let guideText = app.staticTexts["selectionGuideText"]
        XCTAssertTrue(guideText.waitForExistence(timeout: 3))
    }

    @MainActor
    func testSelectionModeHidesDeleteIcons() throws {
        // 選択モードに入る
        let selectButton = app.buttons["selectButton"]
        XCTAssertTrue(selectButton.waitForExistence(timeout: 5))
        selectButton.tap()

        // 完了ボタンが出たことを確認（選択モード中）
        XCTAssertTrue(app.buttons["doneButton"].waitForExistence(timeout: 3))

        // 赤丸の削除ボタンが表示されていないことを確認
        // .onDelete による削除ボタンは "Delete" アクセシビリティラベルを持つ
        let deleteControls = app.buttons.matching(identifier: "Delete")
        XCTAssertEqual(deleteControls.count, 0, "選択モード時に行ごとの削除アイコンが表示されてはいけない")
    }

    // MARK: - カード詳細への遷移

    @MainActor
    func testNavigateToCardDetail() throws {
        // カードをタップして詳細画面に遷移
        let cardText = app.staticTexts["山田 太郎"]
        XCTAssertTrue(cardText.waitForExistence(timeout: 5))
        cardText.tap()

        // 詳細画面のナビゲーションタイトルが表示される
        XCTAssertTrue(app.navigationBars.staticTexts["山田 太郎"].waitForExistence(timeout: 3))
    }

    @MainActor
    func testNavigateBackNoHighlightPersistence() throws {
        // カードをタップして詳細に遷移
        let cardText = app.staticTexts["山田 太郎"]
        XCTAssertTrue(cardText.waitForExistence(timeout: 5))
        cardText.tap()

        // 詳細画面が表示される
        XCTAssertTrue(app.navigationBars.staticTexts["山田 太郎"].waitForExistence(timeout: 3))

        // 戻る
        app.navigationBars.buttons.element(boundBy: 0).tap()

        // リスト画面に戻ったことを確認
        XCTAssertTrue(app.navigationBars.staticTexts["名刺"].waitForExistence(timeout: 3))

        // 選択モードに入ってないことを確認（選択ボタンが表示されている）
        XCTAssertTrue(app.buttons["selectButton"].exists)
    }

    // MARK: - コンテキストメニュー（長押し）

    @MainActor
    func testLongPressShowsContextMenu() throws {
        // カードを長押し
        let cardText = app.staticTexts["山田 太郎"]
        XCTAssertTrue(cardText.waitForExistence(timeout: 5))
        cardText.press(forDuration: 1.5)

        // コンテキストメニューの項目が表示される
        XCTAssertTrue(app.buttons["お気に入りに追加"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["編集"].exists)
        XCTAssertTrue(app.buttons["vCardとして共有"].exists)
        XCTAssertTrue(app.buttons["連絡先に保存"].exists)
        XCTAssertTrue(app.buttons["削除"].exists)
    }

    @MainActor
    func testContextMenuFavoriteToggle() throws {
        // カードを長押し
        let cardText = app.staticTexts["山田 太郎"]
        XCTAssertTrue(cardText.waitForExistence(timeout: 5))
        cardText.press(forDuration: 1.5)

        // お気に入りに追加
        let favoriteButton = app.buttons["お気に入りに追加"]
        XCTAssertTrue(favoriteButton.waitForExistence(timeout: 3))
        favoriteButton.tap()

        // 再度長押しして「お気に入り解除」になっていることを確認
        // コンテキストメニューが閉じるのを少し待つ
        sleep(1)
        cardText.press(forDuration: 1.5)
        XCTAssertTrue(app.buttons["お気に入り解除"].waitForExistence(timeout: 3))

        // メニューを閉じる（背景タップ）
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.1)).tap()
    }

    @MainActor
    func testContextMenuDeleteShowsConfirmation() throws {
        // カードを長押し
        let cardText = app.staticTexts["鈴木 一郎"]
        XCTAssertTrue(cardText.waitForExistence(timeout: 5))
        cardText.press(forDuration: 1.5)

        // 削除をタップ
        let deleteButton = app.buttons["削除"]
        XCTAssertTrue(deleteButton.waitForExistence(timeout: 3))
        deleteButton.tap()

        // 確認ダイアログが表示される
        XCTAssertTrue(app.buttons["削除"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["キャンセル"].exists)

        // キャンセル
        app.buttons["キャンセル"].tap()

        // カードがまだ存在する
        XCTAssertTrue(app.staticTexts["鈴木 一郎"].waitForExistence(timeout: 3))
    }

    // MARK: - 一括削除

    @MainActor
    func testBulkDeleteConfirmation() throws {
        // 選択モードに入る
        let selectButton = app.buttons["selectButton"]
        XCTAssertTrue(selectButton.waitForExistence(timeout: 5))
        selectButton.tap()

        // すべて選択
        let selectAllButton = app.buttons["selectAllButton"]
        XCTAssertTrue(selectAllButton.waitForExistence(timeout: 3))
        selectAllButton.tap()

        // 一括削除ボタンをタップ
        let bulkDeleteButton = app.buttons["bulkDeleteButton"]
        XCTAssertTrue(bulkDeleteButton.waitForExistence(timeout: 3))
        bulkDeleteButton.tap()

        // 確認ダイアログが表示される
        XCTAssertTrue(app.buttons["キャンセル"].waitForExistence(timeout: 3))

        // キャンセルで戻る
        app.buttons["キャンセル"].tap()
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
        XCTAssertTrue(ellipsisMenu.waitForExistence(timeout: 5))
        ellipsisMenu.tap()

        // メニュー項目が表示される
        XCTAssertTrue(app.buttons["連絡先からインポート"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["タグ管理"].exists)
        XCTAssertTrue(app.buttons["設定"].exists)
    }

    // MARK: - フィルタ時のカウント表示

    @MainActor
    func testSearchShowsFilteredCount() throws {
        // 検索バーで検索するとタイトルに件数が表示される
        let searchField = app.searchFields.firstMatch
        XCTAssertTrue(searchField.waitForExistence(timeout: 5))
        searchField.tap()
        searchField.typeText("山田")

        // ナビゲーションタイトルに件数が含まれることを確認
        // 「名刺（3件）」のような表示
        let predicate = NSPredicate(format: "label CONTAINS '名刺（'")
        let titleWithCount = app.navigationBars.staticTexts.matching(predicate)
        XCTAssertTrue(titleWithCount.firstMatch.waitForExistence(timeout: 3),
                      "検索時にナビゲーションタイトルに件数が表示されるべき")
    }
}
