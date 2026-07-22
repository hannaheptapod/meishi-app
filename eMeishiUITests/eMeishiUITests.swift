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

    private var cardSearchField: XCUIElement {
        app.searchFields.firstMatch
    }

    private var nativeTabBar: XCUIElement {
        app.tabBars.firstMatch
    }

    private var cardsTab: XCUIElement {
        rootTabButton(identifier: "cardsRootTab", named: "名刺")
    }

    private var insightsTab: XCUIElement {
        rootTabButton(identifier: "insightsRootTab", named: "インサイト")
    }

    /// iPhoneではXCUIElementTypeTabBar、iPadの上部Tab Barでは通常のButtonとして
    /// 公開されるため、表示形式に依存せず同じ標準Tabを取得する。
    private func rootTabButton(identifier: String, named name: String) -> XCUIElement {
        let identifiedMatches = app.descendants(matching: .any)
            .matching(identifier: identifier)
            .allElementsBoundByIndex
        if let identified = identifiedMatches.first(where: \.isHittable) {
            return identified
        }
        let tabBarMatches = nativeTabBar.buttons
            .matching(NSPredicate(format: "label == %@", name))
            .allElementsBoundByIndex
        if let tabBarButton = tabBarMatches.first(where: \.isHittable) {
            return tabBarButton
        }
        let labelMatches = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@", name))
            .allElementsBoundByIndex
        return labelMatches.first(where: \.isHittable)
            ?? app.descendants(matching: .any)[identifier]
    }

    private var addButton: XCUIElement {
        app.buttons.matching(NSPredicate(
            format: "identifier == %@ OR label == %@",
            "cardAddButton",
            "追加"
        )).firstMatch
    }

    private var sortFilterMenu: XCUIElement {
        app.buttons
            .matching(NSPredicate(
                format: "identifier == %@ OR label == %@",
                "sortFilterMenu",
                "並べ替え・フィルター"
            ))
            .firstMatch
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

    /// UIMenu は identifier がUIテストへ伝播しない場合があるため、表示ラベルも使う。
    private func waitForMenuItem(identifier: String, label: String) -> Bool {
        let predicate = NSPredicate(
            format: "identifier == %@ OR label == %@ OR label BEGINSWITH %@",
            identifier,
            label,
            "\(label), "
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

        XCTAssertTrue(nativeTabBar.waitForExistence(timeout: Self.shortTimeout))
        XCTAssertTrue(cardsTab.waitForExistence(timeout: Self.shortTimeout))
        XCTAssertTrue(insightsTab.waitForExistence(timeout: Self.shortTimeout))
        XCTAssertTrue(cardsTab.isSelected)

        // 標準Tab Barと独立Glass追加ボタンを左右へ分離する
        XCTAssertTrue(addButton.waitForExistence(timeout: Self.shortTimeout))
        let navigationTabsFrame = cardsTab.frame.union(insightsTab.frame)
        XCTAssertLessThan(navigationTabsFrame.maxX, addButton.frame.minX)
        XCTAssertGreaterThan(addButton.frame.maxX, app.frame.width * 0.8)
        XCTAssertEqual(addButton.frame.width, addButton.frame.height, accuracy: 1)
        XCTAssertLessThanOrEqual(
            abs(navigationTabsFrame.height - addButton.frame.height),
            4,
            "標準Tab項目のアクセシビリティ余白を除き、標準Glass Buttonの寸法を維持する"
        )
        XCTAssertEqual(
            navigationTabsFrame.maxY,
            addButton.frame.maxY,
            accuracy: 1,
            "追加ボタンと標準Tab Barの下端を揃える"
        )

        // 通常検索と自然言語検索は1つの標準検索欄を共有し、独立ボタンを置かない
        XCTAssertTrue(cardSearchField.waitForExistence(timeout: Self.shortTimeout))
        XCTAssertFalse(app.buttons["aiSearchButton"].exists)

        // 3点メニュー
        let ellipsisMenu = app.buttons["ellipsisMenu"]
        XCTAssertTrue(ellipsisMenu.exists)

        XCTAssertFalse(nativeTabBar.buttons["めくる"].exists)
        XCTAssertFalse(nativeTabBar.buttons["設定"].exists)
    }

    @MainActor
    func testNativeTabBarSupportsDragSelection() throws {
        XCTAssertTrue(cardsTab.waitForExistence(timeout: Self.shortTimeout))
        XCTAssertTrue(insightsTab.waitForExistence(timeout: Self.shortTimeout))

        cardsTab.press(forDuration: 0.15, thenDragTo: insightsTab)

        XCTAssertTrue(
            app.navigationBars.staticTexts["インサイト"].waitForExistence(timeout: Self.shortTimeout),
            "純正タブバー上のドラッグでインサイトへ切り替わるべき"
        )
        XCTAssertTrue(insightsTab.isSelected)
    }

    @MainActor
    func testForegroundControlsDoNotActivateCardsBehindThem() throws {
        XCTAssertTrue(cardSearchField.waitForExistence(timeout: Self.shortTimeout))
        XCTAssertTrue(cardsTab.waitForExistence(timeout: Self.shortTimeout))

        // コンテンツを前面操作面の背後までスクロールさせた状態で検証する。
        app.swipeUp()
        app.swipeUp()

        cardSearchField.tap()
        XCTAssertFalse(
            app.navigationBars.staticTexts["名刺詳細"].exists,
            "検索欄の背面にあるカードを開かない"
        )

        cardsTab.tap()
        XCTAssertTrue(cardsTab.isSelected)
        XCTAssertFalse(
            app.navigationBars.staticTexts["名刺詳細"].exists,
            "選択中タブの背面にあるカードを開かない"
        )
    }

    @MainActor
    func testTrailingAddOpensAdditionChoices() throws {
        XCTAssertTrue(addButton.waitForExistence(timeout: Self.shortTimeout))
        addButton.tap()

        XCTAssertTrue(app.navigationBars.staticTexts["名刺を追加"].waitForExistence(timeout: Self.shortTimeout))
        XCTAssertTrue(app.buttons["カメラで撮影"].exists)
        XCTAssertTrue(app.buttons["写真から読み込む"].exists)
        XCTAssertTrue(app.buttons["手動で入力"].exists)
    }

    @MainActor
    func testTrailingAddPreservesPreviouslySelectedTab() throws {
        XCTAssertTrue(insightsTab.waitForExistence(timeout: Self.shortTimeout))
        insightsTab.tap()
        XCTAssertTrue(insightsTab.isSelected)

        XCTAssertTrue(addButton.waitForExistence(timeout: Self.shortTimeout))
        addButton.tap()
        XCTAssertTrue(app.navigationBars.staticTexts["名刺を追加"].waitForExistence(timeout: Self.shortTimeout))
        XCTAssertTrue(insightsTab.isSelected, "追加画面を開いても直前のタブを維持するべき")
    }

    @MainActor
    func testUnifiedSearchUsesOneStandardSearchField() throws {
        let searchField = cardSearchField
        XCTAssertTrue(searchField.waitForExistence(timeout: Self.shortTimeout))
        searchField.tap()
        searchField.typeText("山田")
        searchField.typeText("\n")

        XCTAssertTrue(cardRow("山田 太郎").waitForExistence(timeout: Self.shortTimeout))
        XCTAssertFalse(app.buttons["aiSearchButton"].exists)
    }

    @MainActor
    func testUnifiedSearchExplainsAIFallbackBeforeSubmit() throws {
        let searchField = cardSearchField
        XCTAssertTrue(searchField.waitForExistence(timeout: Self.shortTimeout))
        searchField.tap()
        searchField.typeText("東京の営業")

        // UIテスト環境はPro権限なし。検索確定でAI検索の案内へ進むことを事前表示する。
        XCTAssertTrue(app.staticTexts["AI検索を利用できます"].waitForExistence(timeout: Self.shortTimeout))
        XCTAssertTrue(
            app.staticTexts["キーボードの「検索」を押すと、Pro機能のAI検索をご案内します。"]
                .waitForExistence(timeout: Self.shortTimeout)
        )
        XCTAssertFalse(app.buttons["aiSearchButton"].exists)
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
        XCTAssertFalse(nativeTabBar.isHittable)
    }

    @MainActor
    func testSortFilterMenuStaysInTopToolbarWhileScrolling() throws {
        XCTAssertTrue(sortFilterMenu.waitForExistence(timeout: Self.shortTimeout))
        let selectButton = app.buttons["selectButton"]
        XCTAssertTrue(selectButton.waitForExistence(timeout: Self.shortTimeout))
        let moreMenu = app.buttons["ellipsisMenu"]
        XCTAssertTrue(moreMenu.waitForExistence(timeout: Self.shortTimeout))
        let searchField = cardSearchField
        XCTAssertTrue(searchField.waitForExistence(timeout: Self.shortTimeout))
        let initialSortFrame = sortFilterMenu.frame
        XCTAssertEqual(
            initialSortFrame.width,
            initialSortFrame.height,
            accuracy: 1,
            "並べ替え・フィルターは真円のタップ領域にする"
        )
        XCTAssertEqual(
            initialSortFrame.midY,
            selectButton.frame.midY,
            accuracy: 2,
            "並べ替え・フィルターは選択と同じ列へ置く"
        )
        XCTAssertLessThan(
            initialSortFrame.maxX,
            selectButton.frame.minX,
            "並べ替え・フィルターを選択の左へ置く"
        )
        XCTAssertLessThan(
            selectButton.frame.maxX,
            moreMenu.frame.minX,
            "三点メニューは選択の右へ置く"
        )
        XCTAssertEqual(
            initialSortFrame.midY,
            moreMenu.frame.midY,
            accuracy: 2,
            "右上の3操作は同じ列へ置く"
        )
        XCTAssertLessThanOrEqual(
            initialSortFrame.maxY,
            searchField.frame.minY,
            "並べ替え・フィルターを検索欄とは別の上部ツールバーへ置く"
        )

        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "sort-filter-toolbar"
        attachment.lifetime = .keepAlways
        add(attachment)

        app.swipeUp()
        app.swipeUp()

        XCTAssertTrue(sortFilterMenu.isHittable, "右上メニューはスクロール後も操作できる")
        XCTAssertEqual(sortFilterMenu.frame.midY, initialSortFrame.midY, accuracy: 2)
        XCTAssertEqual(sortFilterMenu.frame.midX, initialSortFrame.midX, accuracy: 2)
    }

    @MainActor
    func testVisibleRowsDoNotOverlapRootNavigationAtBottom() throws {
        XCTAssertTrue(nativeTabBar.waitForExistence(timeout: Self.shortTimeout))
        XCTAssertTrue(cardsTab.waitForExistence(timeout: Self.shortTimeout))
        XCTAssertTrue(addButton.waitForExistence(timeout: Self.shortTimeout))

        for _ in 0..<6 { app.swipeUp() }

        // 標準Tab Barがスクロールに応じて縮小しても、pinned追加アクションは
        // 同じシステムレイアウト内で高さと中心を追従する。
        XCTAssertTrue(addButton.isHittable, "スクロール後も独立追加ボタンが操作できる")
        let navigationTabsFrame = cardsTab.frame.union(insightsTab.frame)
        XCTAssertLessThan(navigationTabsFrame.maxX, addButton.frame.minX)
        XCTAssertEqual(addButton.frame.width, addButton.frame.height, accuracy: 1)
        XCTAssertLessThanOrEqual(
            abs(navigationTabsFrame.height - addButton.frame.height),
            4,
            "スクロール後も標準Glass Buttonの寸法を維持する"
        )
        XCTAssertEqual(
            navigationTabsFrame.maxY,
            addButton.frame.maxY,
            accuracy: 1,
            "スクロール後も追加ボタンと標準Tab Barの下端を揃える"
        )
        let navigationTop = min(nativeTabBar.frame.minY, addButton.frame.minY)

        let visibleRows = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'cardRow_'"))
        XCTAssertGreaterThan(visibleRows.count, 0)
        for index in 0..<visibleRows.count {
            let row = visibleRows.element(boundBy: index)
            guard row.isHittable else { continue }
            XCTAssertLessThanOrEqual(
                row.frame.maxY,
                navigationTop + 1,
                "最終行までルートナビゲーションの上へスクロールできる"
            )
        }

        addButton.tap()
        XCTAssertTrue(app.navigationBars.staticTexts["名刺を追加"].waitForExistence(timeout: Self.shortTimeout))
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
        XCTAssertTrue(app.navigationBars.staticTexts["名刺詳細"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["saveToContactsButton"].waitForExistence(timeout: Self.shortTimeout))
        XCTAssertTrue(app.buttons["shareCardButton"].waitForExistence(timeout: Self.shortTimeout))
        if UIDevice.current.userInterfaceIdiom == .pad {
            // Split Viewでは検索欄とTabは一覧列の操作なので残す。詳細列へ複製されないことは、
            // 検索欄が1件だけで一覧列内のまま操作可能なことから確認する。
            XCTAssertEqual(app.searchFields.count, 1)
            XCTAssertTrue(cardSearchField.isHittable)
            XCTAssertTrue(cardsTab.isHittable)
            XCTAssertTrue(addButton.isHittable, "Split Viewでは一覧側の追加操作を維持する")
        } else {
            XCTAssertFalse(cardSearchField.exists, "検索欄を詳細のNavigation Itemへ持ち越さない")
            XCTAssertFalse(nativeTabBar.isHittable)
        }

        // 詳細自体は下スワイプでdismissせず、標準の戻る導線を使う。
        app.swipeDown()
        XCTAssertTrue(app.navigationBars.staticTexts["名刺詳細"].exists)
    }

    @MainActor
    func testNavigateBackNoHighlightPersistence() throws {
        // カードをタップして詳細に遷移
        let card = cardRow("山田 太郎")
        XCTAssertTrue(card.waitForExistence(timeout: 5))
        card.tap()

        // 詳細画面が表示される
        XCTAssertTrue(app.navigationBars.staticTexts["名刺詳細"].waitForExistence(timeout: 3))

        if UIDevice.current.userInterfaceIdiom == .pad {
            // Split Viewには「一覧へ戻る」遷移がない。別の行へ切り替えても一覧列の
            // 操作面が失われず、詳細列だけが更新されることを検証する。
            let nextCard = cardRow("佐藤 誠")
            XCTAssertTrue(nextCard.waitForExistence(timeout: Self.shortTimeout))
            nextCard.tap()
            XCTAssertTrue(app.navigationBars.staticTexts["名刺詳細"].waitForExistence(timeout: Self.shortTimeout))
            XCTAssertTrue(cardSearchField.isHittable)
            XCTAssertTrue(cardsTab.isHittable)
            XCTAssertTrue(addButton.isHittable)
            return
        }

        // compact幅では標準の戻る操作で一覧へ復帰する。
        app.navigationBars.buttons.element(boundBy: 0).tap()

        // リスト画面に戻ったことを確認（選択ボタンが表示される）
        XCTAssertTrue(app.buttons["selectButton"].waitForExistence(timeout: 3))
        XCTAssertTrue(nativeTabBar.isHittable, "Tab Barは一覧への復帰と同時に操作可能になる")
        XCTAssertTrue(addButton.exists, "追加ボタンは一覧と同時に復帰する")
        XCTAssertTrue(cardSearchField.isHittable, "検索欄は一覧への復帰と同時に操作可能になる")
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
        let searchField = cardSearchField
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
        XCTAssertFalse(
            app.descendants(matching: .any)["aiSearchMenu"].exists,
            "自然言語検索は標準検索欄へ統合し、3点メニューには置かない"
        )
    }

    @MainActor
    func testSettingsOpensFromMenuAndHidesRootNavigation() throws {
        let ellipsisMenu = app.buttons["ellipsisMenu"]
        XCTAssertTrue(ellipsisMenu.waitForExistence(timeout: Self.defaultTimeout))
        ellipsisMenu.tap()

        let settings = app.buttons["設定"]
        XCTAssertTrue(settings.waitForExistence(timeout: Self.shortTimeout))
        settings.tap()

        XCTAssertTrue(app.navigationBars.staticTexts["設定"].waitForExistence(timeout: Self.shortTimeout))
        if UIDevice.current.userInterfaceIdiom == .pad {
            XCTAssertEqual(app.searchFields.count, 1)
            XCTAssertTrue(cardSearchField.isHittable, "Split Viewの一覧列は設定表示中も操作可能に保つ")
            XCTAssertTrue(cardsTab.isHittable)
            XCTAssertTrue(addButton.isHittable, "Split Viewでは一覧側の追加操作を維持する")

            let card = cardRow("山田 太郎")
            XCTAssertTrue(card.waitForExistence(timeout: Self.shortTimeout))
            card.tap()
            XCTAssertTrue(app.navigationBars.staticTexts["名刺詳細"].waitForExistence(timeout: Self.shortTimeout))
            return
        }

        XCTAssertFalse(cardSearchField.exists, "検索欄を設定のNavigation Itemへ持ち越さない")
        XCTAssertFalse(nativeTabBar.isHittable)

        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(nativeTabBar.isHittable)
        XCTAssertTrue(
            addButton.isHittable,
            "追加ボタン復帰状態: exists=\(addButton.exists), frame=\(addButton.frame), appFrame=\(app.frame)"
        )
        XCTAssertTrue(cardSearchField.isHittable)
    }

    @MainActor
    func testDuplicateCheckUsesRootOwnedNavigationChrome() throws {
        let ellipsisMenu = app.buttons["ellipsisMenu"]
        XCTAssertTrue(ellipsisMenu.waitForExistence(timeout: Self.defaultTimeout))
        ellipsisMenu.tap()

        let duplicateAction = app.buttons
            .matching(NSPredicate(format: "label BEGINSWITH %@", "重複チェック"))
            .firstMatch
        XCTAssertTrue(duplicateAction.waitForExistence(timeout: Self.shortTimeout))
        duplicateAction.tap()

        XCTAssertTrue(app.navigationBars.staticTexts["重複チェック"].waitForExistence(timeout: Self.shortTimeout))
        XCTAssertFalse(cardSearchField.exists, "検索欄を重複確認のNavigation Itemへ持ち越さない")
        XCTAssertFalse(nativeTabBar.isHittable)

        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(nativeTabBar.isHittable)
        XCTAssertTrue(addButton.isHittable)
        XCTAssertTrue(cardSearchField.isHittable)
    }

    // MARK: - フィルタ時のカウント表示

    @MainActor
    func testSearchShowsFilteredResults() throws {
        // 検索バーで検索すると該当カードのみが表示される
        let searchField = cardSearchField
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

    // MARK: - 1.2.0 回帰テスト

    @MainActor
    func testNativeSortFilterMenuKeepsItsTriggerPosition() throws {
        XCTAssertTrue(sortFilterMenu.waitForExistence(timeout: Self.defaultTimeout))
        let initialFrame = sortFilterMenu.frame
        sortFilterMenu.tap()

        let sortTitles = ["名前", "会社名", "登録日時", "更新日時"]
        for title in sortTitles {
            XCTAssertTrue(waitForMenuItem(identifier: "sortOption_\(title)", label: title))
        }
        XCTAssertFalse(
            app.descendants(matching: .any)["displayMode_card"].exists,
            "廃止したカード表示モードをメニューへ戻さない"
        )
        XCTAssertFalse(app.buttons["sortDirectionAscending"].exists)
        XCTAssertFalse(app.buttons["sortDirectionDescending"].exists)

        // 既定の「登録日時」を再選択すると方向だけが反転する。
        // 左端の選択状態とサブタイトルを検証し、旧来の独立方向UIが復活しないことも担保する。
        let activeSortOption = app.descendants(matching: .any)
            .matching(NSPredicate(
                format: "identifier == %@ OR label == %@ OR label BEGINSWITH %@",
                "sortOption_登録日時",
                "登録日時",
                "登録日時, "
            ))
            .firstMatch
        activeSortOption.tap()
        sortFilterMenu.tap()
        XCTAssertTrue(waitForMenuItem(identifier: "sortOption_登録日時", label: "登録日時"))

        let sortOptionWithDirection = app.buttons
            .matching(NSPredicate(format: "label BEGINSWITH %@", "登録日時, "))
            .firstMatch
        XCTAssertTrue(sortOptionWithDirection.waitForExistence(timeout: Self.shortTimeout))
        XCTAssertTrue(sortOptionWithDirection.isSelected, "ソートの選択状態は左端の標準チェック列で示す")
        XCTAssertTrue(
            sortOptionWithDirection.label.contains("昇順")
                || sortOptionWithDirection.label.contains("降順"),
            "現在の方向はファイルアプリと同じサブタイトルで示す"
        )

        XCTAssertTrue(waitForMenuItem(identifier: "allCardsFilterOption", label: "すべての名刺"))
        XCTAssertTrue(waitForMenuItem(identifier: "favoritesFilterOption", label: "お気に入り"))
        XCTAssertTrue(waitForMenuItem(identifier: "tagFilterMenu", label: "タグ"))
        XCTAssertTrue(waitForMenuItem(identifier: "resetFiltersButton", label: "フィルターをリセット"))

        let initialResetButton = app.descendants(matching: .any)
            .matching(NSPredicate(
                format: "identifier == %@ OR label == %@",
                "resetFiltersButton",
                "フィルターをリセット"
            ))
            .firstMatch
        XCTAssertFalse(initialResetButton.isEnabled, "フィルター未適用時はリセットを無効にする")

        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "native-sort-filter-menu"
        attachment.lifetime = .keepAlways
        add(attachment)

        let tagMenu = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier == %@ OR label == %@", "tagFilterMenu", "タグ"))
            .firstMatch
        tagMenu.tap()
        XCTAssertTrue(waitForMenuItem(identifier: "tagFilter_IT", label: "IT"))
        let itFilter = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier == %@ OR label == %@", "tagFilter_IT", "IT"))
            .firstMatch
        itFilter.tap()

        XCTAssertEqual(sortFilterMenu.frame.midX, initialFrame.midX, accuracy: 2)
        XCTAssertEqual(sortFilterMenu.frame.midY, initialFrame.midY, accuracy: 2)
        XCTAssertTrue(
            String(describing: sortFilterMenu.value).contains("フィルター1件"),
            "タグ選択後もトリガー位置は変えず、適用件数だけを更新する"
        )

        sortFilterMenu.tap()
        let resetButton = app.descendants(matching: .any)
            .matching(NSPredicate(
                format: "identifier == %@ OR label == %@",
                "resetFiltersButton",
                "フィルターをリセット"
            ))
            .firstMatch
        XCTAssertTrue(resetButton.waitForExistence(timeout: Self.shortTimeout))
        XCTAssertTrue(resetButton.isEnabled, "フィルター適用後はリセットを有効にする")
        resetButton.tap()

        XCTAssertTrue(
            String(describing: sortFilterMenu.value).contains("フィルターなし"),
            "リセット後は全フィルターを解除する"
        )
        XCTAssertEqual(sortFilterMenu.frame.midX, initialFrame.midX, accuracy: 2)
        XCTAssertEqual(sortFilterMenu.frame.midY, initialFrame.midY, accuracy: 2)
    }

    @MainActor
    func testContextMenuBackgroundDismissDoesNotOpenUnderlyingCard() throws {
        let card = cardRow(stableVisibleCardName)
        showContextMenu(for: card)
        XCTAssertTrue(app.buttons["編集"].waitForExistence(timeout: Self.shortTimeout))

        app.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.75)).tap()

        XCTAssertTrue(app.buttons["selectButton"].waitForExistence(timeout: Self.shortTimeout))
        XCTAssertFalse(app.navigationBars.staticTexts["名刺詳細"].exists)

        // dismiss入力の終了後は通常のタップを取りこぼさず、同じカードを開ける。
        XCTAssertTrue(card.waitForExistence(timeout: Self.shortTimeout))
        card.tap()
        XCTAssertTrue(
            app.navigationBars.staticTexts["名刺詳細"].waitForExistence(timeout: Self.shortTimeout)
        )
    }

    @MainActor
    func testFullScreenCardImageSupportsZoomAndDismiss() throws {
        let card = cardRow("山田 太郎")
        XCTAssertTrue(card.waitForExistence(timeout: Self.defaultTimeout))
        card.tap()
        XCTAssertTrue(app.navigationBars.staticTexts["名刺詳細"].waitForExistence(timeout: Self.shortTimeout))

        let preview = app.buttons["cardImagePreview"]
        XCTAssertTrue(preview.waitForExistence(timeout: Self.shortTimeout))
        preview.tap()

        let fullScreenImage = app.scrollViews["fullScreenCardImage"]
        XCTAssertTrue(fullScreenImage.waitForExistence(timeout: Self.shortTimeout))
        fullScreenImage.swipeLeft()
        XCTAssertTrue(
            app.scrollViews["fullScreenCardImage"].exists,
            "横方向のパンで全画面画像を閉じない"
        )
        fullScreenImage.pinch(withScale: 2.0, velocity: 1.0)
        fullScreenImage.doubleTap()
        XCTAssertTrue(app.buttons["閉じる"].waitForExistence(timeout: Self.shortTimeout))
        fullScreenImage.swipeDown()
        XCTAssertTrue(app.navigationBars.staticTexts["名刺詳細"].waitForExistence(timeout: Self.shortTimeout))

        preview.tap()
        XCTAssertTrue(app.scrollViews["fullScreenCardImage"].waitForExistence(timeout: Self.shortTimeout))
        app.buttons["閉じる"].tap()
        XCTAssertTrue(app.navigationBars.staticTexts["名刺詳細"].waitForExistence(timeout: Self.shortTimeout))
    }

    @MainActor
    func testInsightsSurvivesContinuousScrolling() throws {
        XCTAssertTrue(insightsTab.waitForExistence(timeout: Self.shortTimeout))
        insightsTab.tap()
        XCTAssertTrue(app.navigationBars.staticTexts["インサイト"].waitForExistence(timeout: Self.shortTimeout))

        let scrollView = app.scrollViews["insightsScrollView"]
        XCTAssertTrue(scrollView.waitForExistence(timeout: Self.shortTimeout))
        for _ in 0..<8 { scrollView.swipeUp() }
        for _ in 0..<4 { scrollView.swipeDown() }

        XCTAssertEqual(app.state, .runningForeground)
        XCTAssertTrue(app.navigationBars.staticTexts["インサイト"].exists)
    }

    @MainActor
    func testInsightActionShowsFilterAtTopOfCardList() throws {
        XCTAssertTrue(insightsTab.waitForExistence(timeout: Self.shortTimeout))
        insightsTab.tap()
        XCTAssertTrue(app.navigationBars.staticTexts["インサイト"].waitForExistence(timeout: Self.shortTimeout))

        let recentAction = app.buttons["insightAction_clock"]
        XCTAssertTrue(recentAction.waitForExistence(timeout: Self.shortTimeout))
        recentAction.tap()

        let activeFilter = app.descendants(matching: .any)["activeExternalFilter"]
        XCTAssertTrue(activeFilter.waitForExistence(timeout: Self.shortTimeout))
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS '30日以内'")).firstMatch.exists)
    }
}
