#!/usr/bin/env bash

# ルートUIの表示状態を遷移先へ分散させる実装と、描画タイミング依存の
# 待機・完了通知が再導入されることを機械的に防ぐ。

set -euo pipefail

failures=0

fail() {
  echo "✗ $1" >&2
  failures=$((failures + 1))
}

mapfile_compat() {
  while IFS= read -r line; do
    [[ -n "$line" ]] && printf '%s\n' "$line"
  done
}

tab_bar_owners="$({ rg -l 'for: \.tabBar' eMeishi --glob '*.swift' || true; } | sort | mapfile_compat)"
if [[ "$tab_bar_owners" != "eMeishi/ContentView.swift" ]]; then
  fail "Tab Bar表示制御はTabViewを所有するContentViewだけに限定してください。現在: ${tab_bar_owners:-なし}"
fi

if rg -n 'NavigationLink[[:space:]]*\{' eMeishi/Views/CardListView.swift >/dev/null; then
  fail "CardListViewのルート遷移は親が所有する単一の詳細ルートを更新してください"
fi

if ! rg -Fq '@Published private(set) var activeCardsRoute: CardListRoute?' \
    eMeishi/Models/AppNavigationState.swift; then
  fail "名刺側NavigationSplitViewは単一の型付き詳細ルートを使用してください"
fi

if rg -n 'cardsPath|usesSplitView|pushCardsRoute|inSplitView' \
    eMeishi/ContentView.swift \
    eMeishi/Models/AppNavigationState.swift \
    eMeishi/Views/CardListView.swift >/dev/null; then
  fail "compact/regular別の旧Navigation経路を再導入しないでください"
fi

if rg -n '@State private var (cardForDetail|isShowingSettings|isShowingDuplicates)' eMeishi/Views/CardListView.swift >/dev/null; then
  fail "ルート遷移を画面ローカルBoolへ戻さないでください"
fi

if rg -n 'selectedCardForSplit:[[:space:]]*BusinessCard' \
    eMeishi/Models/AppNavigationState.swift >/dev/null; then
  fail "Split Viewの選択状態へNSManagedObjectを長期保持せず、永続IDを保持してください"
fi

split_view_count="$(rg -c 'NavigationSplitView' eMeishi/ContentView.swift || true)"
if [[ "$split_view_count" != "1" ]]; then
  fail "iPadの名刺ルートは単一のNavigationSplitViewで構成してください。現在: $split_view_count"
fi

if ! rg -q 'private var compactCardsRoot: some View' eMeishi/ContentView.swift \
    || ! rg -q 'private var regularCardsRoot: some View' eMeishi/ContentView.swift \
    || ! rg -Fq '.navigationDestination(item: activeCardsRouteBinding)' eMeishi/ContentView.swift; then
  fail "iPhoneはNavigationStack、iPadはNavigationSplitViewの安定した一覧ルートを使用してください"
fi

compact_add_button_owners="$({ rg -l 'accessibilityIdentifier[[:space:]]*=[[:space:]]*"cardAddButton"|accessibilityIdentifier\("cardAddButton"\)' eMeishi --glob '*.swift' || true; } | sort | mapfile_compat)"
expected_add_button_owners=$'eMeishi/ContentView.swift\neMeishi/Views/Components/SystemTabBarAddButtonHost.swift'
if [[ "$compact_add_button_owners" != "$expected_add_button_owners" ]]; then
  fail "追加アクションはContentViewと標準Tab Bar Hostだけで構成してください。現在: ${compact_add_button_owners:-なし}"
fi

if rg -q '\.tabPlacement\(\.pinned\)' eMeishi/ContentView.swift \
    || rg -q 'RootTabSelection\.add' eMeishi/ContentView.swift \
    || ! rg -q 'rootAddButtonOverlay' eMeishi/ContentView.swift \
    || ! rg -Fq 'RootAddButton(action:' eMeishi/ContentView.swift \
    || rg -q '\.buttonStyle\(\.glassProminent\)' eMeishi/ContentView.swift \
    || ! rg -q 'UIButton\.Configuration\.prominentGlass\(\)' eMeishi/Views/Components/SystemTabBarAddButtonHost.swift; then
  fail "追加アクションをTabへ戻さず、右端の独立した標準Glass Buttonとして維持してください"
fi

if rg -n -U 'resultType[[:space:]]*=[[:space:]]*\.dictionaryResultType(.|\n){0,500}fetchBatchSize[[:space:]]*=[[:space:]]*[1-9]' \
    eMeishi --glob '*.swift' >/dev/null; then
  fail "NSDictionaryResultTypeへ非ゼロfetchBatchSizeを指定しないでください。実機でCore DataがSIGTRAPします"
fi

if ! rg -q -U 'NotificationCenter\.default\.publisher\((.|\n){0,160}for: \.NSManagedObjectContextObjectsDidChange,(.|\n){0,100}object: context(.|\n){0,160}\.receive\(on: RunLoop\.main\)(.|\n){0,160}\.sink' \
    eMeishi/ViewModels/CardListViewModel.swift \
    || rg -q 'NotificationCenter\.default\.publisher\(for: \.NSManagedObjectContextObjectsDidChange\)' \
        eMeishi/ViewModels/CardListViewModel.swift; then
  fail "一覧更新通知はMain Queue Contextへ限定し、sinkより前にMain RunLoopへ配送してください"
fi

if ! rg -q -U 'NotificationCenter\.default\.publisher\((.|\n){0,180}for: \.NSManagedObjectContextObjectsDidChange(.|\n){0,220}\.receive\(on: RunLoop\.main\)' \
    eMeishi/ContentView.swift; then
  fail "選択中詳細の削除通知はNavigation状態へ触れる前にMain RunLoopへ移してください"
fi

if rg -n 'NavigationItemSearchPlacementConfigurator|UISearchTextField|searchBarPlacementAllowsToolbarIntegration|preferredSearchBarPlacement' \
    eMeishi --glob '*.swift' >/dev/null; then
  fail "一覧検索はUIKitで再構成せず、標準searchableの配置・外観・遷移を維持してください"
fi

if rg -n '\.tabBarMinimizeBehavior\(\.never\)' eMeishi/ContentView.swift >/dev/null; then
  fail "標準Tab Barのスクロール連動縮小を無効化しないでください"
fi

if ! rg -q '\.searchable\(' eMeishi/ContentView.swift \
    || ! rg -q 'placement: \.navigationBarDrawer\(displayMode: \.always\)' \
        eMeishi/ContentView.swift; then
  fail "一覧検索は一覧側Navigation Itemが所有する標準searchableで維持してください"
fi

if rg -n 'searchableCardsRoot' eMeishi/ContentView.swift >/dev/null \
    || ! rg -q 'private func cardsListRoot\(usesSidebarLayout: Bool\)' \
        eMeishi/ContentView.swift \
    || ! rg -q -U 'CardListView\(usesSidebarLayout: usesSidebarLayout\)(.|\n){0,120}\.searchable\(' \
        eMeishi/ContentView.swift; then
  fail "searchableをNavigationコンテナの外側へ付けず、iPhone一覧／iPad sidebarのルートViewへ固定してください"
fi

if ! rg -q 'final class RootAddButtonOverlayContainer: UIView' \
        eMeishi/Views/Components/SystemTabBarAddButtonHost.swift \
    || ! rg -q 'rootView\.addSubview\(container\)' \
        eMeishi/Views/Components/SystemTabBarAddButtonHost.swift \
    || rg -q 'tabBar\.addSubview\(container\)' \
        eMeishi/Views/Components/SystemTabBarAddButtonHost.swift; then
  fail "iPhone追加ボタン本体はUITabBar内へ入れず、UITabBarController.viewの兄弟として所有してください"
fi

if rg -n 'isSettingsRequested|presentRequestedSettingsIfNeeded|consumeSettingsRequest' \
    eMeishi/ContentView.swift eMeishi/Models/AppNavigationState.swift eMeishi/Views/CardListView.swift >/dev/null; then
  fail "画面表示後のonAppearで設定遷移を復元せず、型付きPathを直接更新してください"
fi

if rg -n 'Color\.clear\.onAppear[[:space:]]*\{[[:space:]]*onComplete\(' eMeishi/Views --glob '*.swift' >/dev/null; then
  fail "描画ライフサイクルを処理完了通知に使用しないでください"
fi

if rg -n 'DispatchQueue\.main\.asyncAfter' eMeishi/Views --glob '*.swift' >/dev/null; then
  fail "Viewの固定時間待機は禁止です。完了コールバックまたは状態遷移を使用してください"
fi

if rg -n -U '\.onAppear[[:space:]]*\{[[:space:]]*(editName|editColor)[[:space:]]*=' \
    eMeishi/Views/TagManagementView.swift >/dev/null; then
  fail "編集シートの初期値をonAppear後に注入せず、State初期化時に設定してください"
fi

if rg -n 'presentationSignature|value:[[:space:]]*presentationSignature' \
    eMeishi/Views/Components/CardRowView.swift >/dev/null; then
  fail "一覧復帰時に行全体を暗黙アニメーションさせず、変化する要素だけへ限定してください"
fi

if rg -n 'suppressCardTapUntil|addingTimeInterval\(0\.35\)' \
    eMeishi/Views/CardListView.swift >/dev/null; then
  fail "コンテキストメニュー終了後の誤タップ抑止に固定時間を使わないでください"
fi

if rg -n -U '\.onDisappear[[:space:]]*\{[^}]*(viewLifetimeID[[:space:]]*=|presentationState\.removeAll|confirmationCommitState\.removeAll)' \
        eMeishi/Views/CardListView.swift >/dev/null \
    || ! rg -q '\.onChange\(of: navigationState\.selectedTab\)' eMeishi/Views/CardListView.swift \
    || ! rg -q 'deactivateTransientInteractionState' eMeishi/Views/CardListView.swift \
    || ! rg -q 'viewLifetimeID = UUID\(\)' eMeishi/Views/CardListView.swift; then
  fail "Split Viewのsidebar非表示を画面寿命の終了と扱わず、名刺タブ自体を離れた時だけ一時操作を無効化してください"
fi

if rg -n -U '\.toolbar[[:space:]]*\{[[:space:]]*if[[:space:]]+editMode' \
        eMeishi/Views/CardListView.swift >/dev/null \
    || ! rg -q -U '\.toolbar[[:space:]]*\{[[:space:]]*normalToolbarContent[[:space:]]*selectionToolbarContent' \
        eMeishi/Views/CardListView.swift; then
  fail "選択モードでToolbar item群を丸ごと差し替えず、固定スロット内の内容と有効状態だけを更新してください"
fi

if rg -n 'UIApplication\.shared\.connectedScenes|rootViewController|snapshotView' \
    eMeishi/Views/CameraView.swift >/dev/null; then
  fail "カメラ表示をWindow探索や外部ViewControllerから管理しないでください"
fi

if ! rg -q 'SystemCameraBatchHostViewController' eMeishi/Views/CameraView.swift \
    || ! rg -q 'UIImagePickerController' eMeishi/Views/CameraView.swift \
    || ! rg -q 'showsCameraControls = true' eMeishi/Views/CameraView.swift \
    || rg -q 'AVCaptureSession' eMeishi/Views/CameraView.swift; then
  fail "連続撮影は固定HostがApple標準カメラUIを所有し、独自AVCaptureSessionを使用しないでください"
fi

if rg -n 'as![[:space:]]+AVCaptureVideoPreviewLayer' \
    eMeishi/Views/CameraView.swift >/dev/null; then
  fail "カメラプレビューのCALayerを強制castしないでください"
fi

if rg -n 'URL\(string:[^)]*\)!' \
    eMeishi/Views eMeishi/ContentView.swift --glob '*.swift' >/dev/null; then
  fail "UIの固定URLもfailable初期化を強制アンラップしないでください"
fi

if rg -n 'buckets\[[^]]+\]!' \
    eMeishi/Utilities/CardGroupingService.swift >/dev/null \
    || rg -n 'items\.(first|last)!' \
        eMeishi/Views/Components/SectionIndexView.swift >/dev/null; then
  fail "一覧のグループ化・索引でコレクション要素を強制アンラップしないでください"
fi

if rg -n 'pendingAddAction|isShowing(AddOptions|Camera|PhotoPicker|ManualForm|BatchReview)' \
    eMeishi/Views/Components/CardAdditionFlowModifier.swift >/dev/null; then
  fail "名刺追加presentationを独立Boolへ戻さず、CardAdditionFlowStateで排他管理してください"
fi

if ! rg -q '@State private var flowState: CardAdditionFlowState' \
    eMeishi/Views/Components/CardAdditionFlowModifier.swift; then
  fail "名刺追加フローは型付き状態機械を唯一のpresentation状態として使用してください"
fi

if rg -n 'card\.updatedAt|updatedAt:' eMeishi/Services/CardImageDecodingService.swift >/dev/null \
    || rg -n 'businessCard\([^)]*dataCount:' eMeishi --glob '*.swift' >/dev/null; then
  fail "画像以外の更新でサムネイルを再デコードしないよう、画像内容由来のキャッシュキーを使用してください"
fi

if rg -n 'sampleFingerprint|prefix\(|suffix\(' \
    eMeishi/Services/CardImageDecodingService.swift >/dev/null \
    || ! rg -q 'CardImageRevisionStore' eMeishi/Services/CardImageDecodingService.swift \
    || ! rg -q 'changedValuesForCurrentEvent\(\).*imageData' \
        eMeishi/Services/CardImageDecodingService.swift; then
  fail "画像キャッシュはDataの部分サンプルではなく、imageData変更イベント由来の定数時間revisionを使用してください"
fi

if rg -n 'Task\.sleep|asyncAfter|func triggerSync' \
    eMeishi/Services/CloudSyncMonitor.swift eMeishi/Views/SettingsView.swift >/dev/null; then
  fail "iCloud同期表示へ手動トリガーや固定時間の疑似進捗を再導入しないでください。実イベントだけを表示してください"
fi

if rg -n '@State private var (isShowingEditForm|exportItem|isShowingCardImage|isShowingAlert)' \
    eMeishi/Views/CardDetailView.swift >/dev/null; then
  fail "CardDetailViewのpresentationは単一の型付きキューで排他管理してください"
fi

if rg -n '\.(sheet|fullScreenCover|alert|confirmationDialog)\(' \
    eMeishi/App/eMeishiApp.swift eMeishi/ContentView.swift >/dev/null; then
  fail "アプリルートのpresentationはCardAdditionFlowModifierだけが所有してください"
fi

if ! rg -q '\.cardAdditionFlow\(\)' eMeishi/ContentView.swift \
    || ! rg -q 'AppRootPresentationRequests' eMeishi/App/eMeishiApp.swift; then
  fail "追加・Paywall・起動案内は共通のルートpresentation状態へ集約してください"
fi

if ! rg -q 'case dismissingSheet' eMeishi/Models/CardAdditionFlowState.swift \
    || ! rg -q 'case dismissingPhotoPicker' eMeishi/Models/CardAdditionFlowState.swift \
    || ! rg -q 'case dismissingAlert' eMeishi/Models/CardAdditionFlowState.swift \
    || ! rg -q 'onDismiss: handleSheetDismissed' \
        eMeishi/Views/Components/CardAdditionFlowModifier.swift; then
  fail "追加フローはdismiss要求とUIKit/SwiftUIの実完了を別状態として管理してください"
fi

if ! rg -q 'PresentationDismissalObserver' \
    eMeishi/Views/Components/CardAdditionFlowModifier.swift \
    || ! rg -q 'deferUntilDismissal' \
        eMeishi/Views/CardListView.swift eMeishi/Views/TagManagementView.swift; then
  fail "Alert・PhotosPicker・コンテキストメニューは実dismiss完了まで背面操作と次presentationを保留してください"
fi

if rg -q 'SystemMenuActionGate|requestSystemMenuAction|completeSystemMenuDismissal' \
    eMeishi/Views/CardListView.swift \
    eMeishi/Views/Components/ContextMenuInteractionGate.swift; then
  fail "標準Menuは独自のUIKit表示検出を挟まず、標準actionから直接処理してください"
fi

if ! rg -q 'PresentationPathTracker<ObjectIdentifier>' \
    eMeishi/Views/Components/PresentationDismissalObserver.swift \
    || ! rg -q 'pathTracker\.begin\(' \
        eMeishi/Views/Components/PresentationDismissalObserver.swift \
    || ! rg -q 'scopePrefix: snapshot\.scopePrefix' \
        eMeishi/Views/Components/PresentationDismissalObserver.swift \
    || ! rg -q 'controller\(\$0, contains: host\)' \
        eMeishi/Views/Components/PresentationDismissalObserver.swift; then
  fail "Alert監視はprobeの所属Controllerまでをscopeにし、その上のpresentationだけを追跡してください"
fi

for owner in \
    eMeishi/Views/CardListView.swift \
    eMeishi/Views/SettingsView.swift \
    eMeishi/Views/TagManagementView.swift \
    eMeishi/Views/AdvancedSettingsView.swift \
    eMeishi/Views/ModelManagementView.swift; do
  if ! rg -q 'DismissalCommitState<' "$owner"; then
    fail "確認UIの副作用は実dismiss完了後まで保留してください: $owner"
  fi
done

if ! rg -q 'StoredCardImageLoader' \
    eMeishi/Views/Components/FullScreenCardImageView.swift \
    || ! rg -q 'fallbackMaximumPixelSizes:' \
        eMeishi/Views/Components/FullScreenCardImageView.swift \
    || ! rg -q 'cachedImage\(for: request\)' \
        eMeishi/Views/Components/StoredCardImageView.swift; then
  fail "全画面画像は共通背景ローダーを使い、詳細画像の同期キャッシュを初期フレームへ流用してください"
fi

if rg -n 'card\.imageData' \
    eMeishi/Views/CardDetailView.swift \
    eMeishi/Views/Components/CardPeekView.swift \
    eMeishi/Views/Components/CardThumbnailView.swift \
    eMeishi/Views/Components/FullScreenCardImageView.swift >/dev/null \
    || ! rg -q 'storedImage\(' eMeishi/Views/Components/StoredCardImageView.swift \
    || ! rg -q 'storedImage\(' eMeishi/Views/Components/CardThumbnailView.swift; then
  fail "保存済み画像BLOBをView評価やMainActor contextから読まず、背景contextの共通ローダーを使用してください"
fi

if ! rg -q 'didPrepareInitialAppearance' eMeishi/Views/CardListView.swift; then
  fail "CardListViewの一度限りの初期化と復帰ごとの同期を分離してください"
fi

if ! rg -q 'struct RenderState: Equatable' eMeishi/Views/Components/CardListControls.swift \
    || ! rg -q 'lastRenderState != renderState' eMeishi/Views/Components/CardListControls.swift \
    || rg -n '\[configuration\]' eMeishi/Views/Components/CardListControls.swift >/dev/null; then
  fail "ソート・フィルターのUIKitメニューは入力変更時だけ再構成してください"
fi

if ! rg -q 'interactiveDismissDisabled(isAdvancing || queuePersistenceWarning != nil)' \
    eMeishi/Views/BatchReviewView.swift; then
  fail "バッチ確認は永続キュー更新中と復旧判断中のdismissを禁止してください"
fi

if ! rg -q 'Task\.detached\(priority: \.userInitiated\)' \
    eMeishi/Utilities/DuplicateChecker.swift \
    || rg -n 'duplicatePairs[[:space:]]*=[[:space:]]*checker\.findDuplicates\(' \
        eMeishi/ViewModels/CardListViewModel.swift >/dev/null; then
  fail "全カードのO(n²)重複比較をMainActorで同期実行しないでください"
fi

if ! rg -q 'CardListDisplaySnapshot' eMeishi/ViewModels/CardListViewModel.swift \
    || ! rg -q '@Published private var listDisplaySnapshot' \
        eMeishi/ViewModels/CardListViewModel.swift \
    || rg -n '@Published[^\n]*(filteredCards|groupedCards)' \
        eMeishi/ViewModels/CardListViewModel.swift >/dev/null; then
  fail "一覧のfiltered/grouped結果は1つのPublishedスナップショットとして原子的に公開してください"
fi

if ! rg -Fq 'scheduleListUpdate(debounce: !normalizedSearchText.isEmpty)' \
    eMeishi/ViewModels/CardListViewModel.swift; then
  fail "検索解除はdebounceせず、一覧セクションへ即時復帰してください"
fi

if ! rg -q 'actor CardListQueryWorker' eMeishi/ViewModels/CardListViewModel.swift \
    || ! rg -q 'snapshotGeneration:' eMeishi/ViewModels/CardListViewModel.swift; then
  fail "一覧の正規化・検索・ソート・グループ化は世代付きworkerへ集約してください"
fi

if ! rg -q 'actor CardListQuerySnapshotLoader' eMeishi/ViewModels/CardListViewModel.swift \
    || ! rg -q 'NSManagedObjectContext\(concurrencyType: \.privateQueueConcurrencyType\)' \
        eMeishi/ViewModels/CardListViewModel.swift \
    || ! rg -q 'NSFetchRequest<NSDictionary>\(entityName: "BusinessCard"\)' \
        eMeishi/ViewModels/CardListViewModel.swift \
    || ! rg -q 'request\.propertiesToFetch = propertiesToFetch' \
        eMeishi/ViewModels/CardListViewModel.swift \
    || ! rg -q 'request\.fetchBatchSize = 100' eMeishi/ViewModels/CardListViewModel.swift \
    || ! rg -q 'listQuerySnapshotLoadGeneration' eMeishi/ViewModels/CardListViewModel.swift; then
  fail "一覧検索スナップショットはprivate queueで必要属性だけを辞書取得し、世代管理して生成してください"
fi

card_list_loader_source="$(sed -n '/actor CardListQuerySnapshotLoader/,/^\/\/ 名刺一覧画面のViewModel/p' eMeishi/ViewModels/CardListViewModel.swift)"
if printf '%s\n' "$card_list_loader_source" | rg -q 'scalarPropertyKeys[[:space:]]*=.*imageData|"imageData"'; then
  fail "一覧検索スナップショットで画像BLOBを取得しないでください"
fi

if rg -n 'listQuerySnapshots[[:space:]]*=[[:space:]]*cards\.enumerated\(\)\.map' \
    eMeishi/ViewModels/CardListViewModel.swift >/dev/null; then
  fail "全カード・全タグの一覧検索スナップショットをMainActorで同期生成しないでください"
fi

if ! rg -q 'let item: CardListItemSnapshot' eMeishi/Views/Components/CardRowView.swift \
    || rg -n 'BusinessCard|@ObservedObject|card\.(tags|tagArray|fullName|company|department|title|isFavorite)' \
        eMeishi/Views/Components/CardRowView.swift >/dev/null; then
  fail "一覧行はBusinessCardを保持せず、CardListItemSnapshotだけから描画してください"
fi

if rg -n 'viewModel\.(filteredCards|groupedCards)|BusinessCard\.ID|Set<NSManagedObjectID>' \
        eMeishi/Views/CardListView.swift >/dev/null \
    || ! rg -q 'viewModel\.filteredCardItems' eMeishi/Views/CardListView.swift \
    || ! rg -q 'viewModel\.groupedCardItemSections' eMeishi/Views/CardListView.swift; then
  fail "一覧の描画・選択・削除はNSManagedObject配列ではなく、永続URIをIDに持つ値型itemを使用してください"
fi

if rg -n 'BusinessCard\.ID|Set<NSManagedObjectID>' \
        eMeishi/ViewModels/CardListViewModel.swift >/dev/null; then
  fail "一覧ViewModelの選択・一括操作APIはCore Dataの一時IDではなく永続URIへ統一してください"
fi

card_list_display_source="$(sed -n '/private struct CardListDisplaySnapshot/,/^}/p' eMeishi/ViewModels/CardListViewModel.swift)"
if printf '%s\n' "$card_list_display_source" | rg -q 'BusinessCard|CardSection|NSManagedObjectID'; then
  fail "Published一覧スナップショットへBusinessCardやNSManagedObjectIDを保持せず、Sendableな表示値だけを原子的に公開してください"
fi

if ! rg -q 'listItem\(for:' eMeishi/ContentView.swift \
    || rg -n 'existingObject\([^)]*\)[^\n]*BusinessCard|object\(with:[^)]*\)[^\n]*BusinessCard' \
        eMeishi/ContentView.swift >/dev/null; then
  fail "詳細遷移先はContentViewのbodyでCore Dataを再解決せず、一覧と同じCardListItemSnapshotを使用してください"
fi

for value_view in \
    eMeishi/Views/CardDetailView.swift \
    eMeishi/Views/Components/CardPeekView.swift \
    eMeishi/Views/Components/CardThumbnailView.swift; do
  if ! rg -q 'CardListItemSnapshot' "$value_view" \
      || rg -n '@(ObservedObject|State)[^\n]*BusinessCard|let card: BusinessCard|var card: BusinessCard' "$value_view" >/dev/null; then
    fail "一覧から派生する表示ViewはBusinessCardを保持せずCardListItemSnapshotを共有してください: $value_view"
  fi
done

if rg -n '\.contentTransition\(' \
    eMeishi/Views/Components/CardRowView.swift \
    eMeishi/Views/CardDetailView.swift \
    eMeishi/Views/Components/CardPeekView.swift >/dev/null; then
  fail "一覧復帰のNavigation transactionを文字・画像へ継承させないよう、遷移先と行の暗黙contentTransitionを使用しないでください"
fi

if ! rg -q 'let duplicateSnapshots: \[DuplicateCardSnapshot\]' \
        eMeishi/ViewModels/CardListViewModel.swift \
    || ! rg -q 'duplicateSnapshots\.append\(makeDuplicateSnapshot\(' \
        eMeishi/ViewModels/CardListViewModel.swift \
    || ! rg -q 'detectDuplicatesIfCardsChanged\(revisions, snapshots: result\.duplicateSnapshots\)' \
        eMeishi/ViewModels/CardListViewModel.swift \
    || rg -n 'makeSnapshots\(from: cards\)|cards\.map[[:space:]]*\{[^}]*DuplicateCardSnapshot|cardRevisions\(for:' \
        eMeishi/ViewModels/CardListViewModel.swift >/dev/null; then
  fail "重複判定の入力も一覧private contextの完成スナップショットから渡し、MainActorで全カードを再走査しないでください"
fi

if ! rg -q 'actor InsightsSnapshotLoader' eMeishi/Services/InsightsService.swift \
    || ! rg -q 'NSManagedObjectContext\(concurrencyType: \.privateQueueConcurrencyType\)' \
        eMeishi/Services/InsightsService.swift \
    || ! rg -q 'relationshipKeyPathsForPrefetching = \["tags"\]' \
        eMeishi/Services/InsightsService.swift \
    || ! rg -q 'request\.fetchBatchSize = 100' eMeishi/Services/InsightsService.swift \
    || ! rg -q 'try await snapshotLoader\.load' eMeishi/Services/InsightsService.swift; then
  fail "インサイトの全件fetch・タグ評価・スナップショット化をMainActorで行わないでください"
fi

if rg -n 'let cards = try\? context\.fetch|let snapshots = cards\.map' \
    eMeishi/Services/InsightsService.swift >/dev/null; then
  fail "InsightsService.generateInsightsで管理オブジェクトをMainActor上から全件走査しないでください"
fi

if rg -q 'scenePhase|\.task\(id: scenePhase\)|cameraLifecycleActivity' \
    eMeishi/Views/CameraView.swift \
    || ! rg -q 'resolveAuthorization' eMeishi/Views/CameraView.swift; then
  fail "標準カメラの権限要求をscenePhase連動Taskで再起動しないでください"
fi

if ! rg -q '@State private var photoImportTask: Task<Void, Never>\?' \
    eMeishi/Views/Components/CardAdditionFlowModifier.swift \
    || ! rg -q 'photoImportTask\?\.cancel\(\)' \
        eMeishi/Views/Components/CardAdditionFlowModifier.swift \
    || ! rg -q 'preferredItemEncoding:[[:space:]]*\.current' \
        eMeishi/Views/Components/CardAdditionFlowModifier.swift; then
  fail "写真取込みTaskを画面寿命へ束縛し、不要な互換形式変換を避けてください"
fi

if rg -n 'viewModel\.fetchCards\(\)' \
    eMeishi/Views/Components/CardAdditionFlowModifier.swift >/dev/null \
    || ! rg -q 'didSaveCardInCurrentSheet' \
        eMeishi/Views/Components/CardAdditionFlowModifier.swift \
    || ! rg -q 'beginContextRefreshDeferral' \
        eMeishi/Views/Components/CardAdditionFlowModifier.swift \
    || ! rg -q 'endContextRefreshDeferral' \
        eMeishi/Views/Components/CardAdditionFlowModifier.swift; then
  fail "追加シートは保存成功時だけ、実dismiss後にCore Data通知と一覧更新を1回へまとめてください"
fi

if ! rg -q '@State private var modelDownloadTask: Task<Void, Never>\?' \
    eMeishi/Views/Components/CardAdditionFlowModifier.swift \
    || ! rg -q 'modelDownloadGeneration == generation' \
        eMeishi/Views/Components/CardAdditionFlowModifier.swift \
    || ! rg -q 'modelDownloadTask\?\.cancel\(\)' \
        eMeishi/Views/Components/CardAdditionFlowModifier.swift; then
  fail "追加フローから開始するモデルダウンロードを画面寿命と世代へ束縛してください"
fi

if rg -n 'cardArray|viewModel\.allTags' \
    eMeishi/Views/TagManagementView.swift \
    eMeishi/Views/BulkTagAssignView.swift \
    eMeishi/Views/CardFormView.swift >/dev/null \
    || ! rg -q 'TagDisplaySnapshot' \
        eMeishi/ViewModels/CardListViewModel.swift \
    || ! rg -q 'tagDisplaySnapshots' eMeishi/Views/TagManagementView.swift \
    || ! rg -q 'tagDisplaySnapshots' eMeishi/Views/BulkTagAssignView.swift \
    || ! rg -q 'tagDisplaySnapshots' eMeishi/Views/CardFormView.swift; then
  fail "タグ管理・一括付与・フォームはTag管理オブジェクトをForEachせず、同じTagDisplaySnapshotを共有してください"
fi

if rg -n 'card\.(tags|tagArray)|BusinessCard\.ID|Set<NSManagedObjectID>' \
    eMeishi/Views/BulkTagAssignView.swift >/dev/null \
    || ! rg -q 'let selectedCardURIs: Set<URL>' eMeishi/Views/BulkTagAssignView.swift \
    || ! rg -q 'let tagID: UUID\?' eMeishi/ViewModels/CardListViewModel.swift \
    || rg -n 'for tag in card\.tags' \
        eMeishi/ViewModels/CardListViewModel.swift >/dev/null; then
  fail "一括タグ画面は永続URIと一覧スナップショットのtag IDで集計し、View/MainActorでrelationshipを全件走査しないでください"
fi

if ! rg -q 'cardASummary: DuplicateCardSummary' \
        eMeishi/Utilities/DuplicateChecker.swift; then
  fail "重複候補行は検出時の値スナップショットを使い、body評価中にCore Dataを再解決しないでください"
fi

if ! rg -q 'actor CompanyReadingMigrationWorker' \
    eMeishi/App/PersistenceController.swift \
    || ! rg -q 'privateQueueConcurrencyType' \
        eMeishi/App/PersistenceController.swift \
    || rg -n '@MainActor[[:space:]]+private static func migrateCompanyReading' \
        eMeishi/App/PersistenceController.swift >/dev/null; then
  fail "起動時の会社名読み移行はprivate context workerで実行し、MainActorを全件処理で占有しないでください"
fi

if ! rg -q 'private var readContexts:' \
    eMeishi/Services/CardImageDecodingService.swift \
    || ! rg -q 'private func readContext\(' \
        eMeishi/Services/CardImageDecodingService.swift; then
  fail "一覧画像の読取りcontextはpersistent coordinator単位で再利用し、行ごとのcontext生成を避けてください"
fi

if rg -n 'cardDestinationChrome' eMeishi --glob '*.swift' >/dev/null; then
  fail "遷移先からルートTab Bar表示を上書きする旧chrome modifierを再導入しないでください"
fi

for owner in \
    eMeishi/Views/SettingsView.swift \
    eMeishi/Views/AdvancedSettingsView.swift \
    eMeishi/Views/ModelManagementView.swift \
    eMeishi/Views/Billing/PaywallView.swift \
    eMeishi/Views/BulkTagAssignView.swift; do
  if ! rg -q 'SecondaryViewTaskGate' "$owner"; then
    fail "画面起点の非同期結果は画面世代とoperation IDで破棄してください: $owner"
  fi
done

if ! rg -q 'actor TagDisplaySnapshotLoader' \
        eMeishi/ViewModels/CardListViewModel.swift \
    || ! rg -q 'context\.name = "TagDisplaySnapshotLoader"' \
        eMeishi/ViewModels/CardListViewModel.swift \
    || ! rg -q 'tagDisplaySnapshotLoadGeneration' \
        eMeishi/ViewModels/CardListViewModel.swift \
    || ! rg -q 'try await loader\.load\(' \
        eMeishi/ViewModels/CardListViewModel.swift; then
  fail "タグ使用件数はprivate queueの世代付きloaderで値スナップショット化してください"
fi

if rg -n 'makeAssignmentSummary|card\.(tags|tagArray)' \
        eMeishi/Views/BulkTagAssignView.swift >/dev/null \
    || ! rg -q '@State private var assignmentSummary' \
        eMeishi/Views/BulkTagAssignView.swift \
    || ! rg -q 'viewModel\.bulkTagAssignmentSummary' \
        eMeishi/Views/BulkTagAssignView.swift; then
  fail "一括タグ画面はbody評価中に選択カードのrelationshipを走査せず、更新時だけ集計してください"
fi

if rg -n 'persist\([^\n]*dropFirst|restore\(\)[^\n]*dropFirst' \
    eMeishi/Services/PendingOCRStore.swift >/dev/null \
    || ! rg -q 'func advance\(queueID: UUID, expectedInputID: UUID\) throws -> Int' \
        eMeishi/Services/PendingOCRStore.swift \
    || ! rg -q 'func discard\(queueID: UUID\) throws' \
        eMeishi/Services/PendingOCRStore.swift; then
  fail "未完了OCRはqueue IDと先頭input IDを照合し、manifestだけを進めてください"
fi

if ! rg -q 'PrivacyRevealReadinessProbe' eMeishi/App/eMeishiApp.swift \
    || ! rg -q 'renderedProtectionGeneration == protectionRenderGeneration' \
        eMeishi/App/eMeishiApp.swift; then
  fail "Privacy Shieldは保護画面の実レイアウト完了を世代照合してから解除してください"
fi

if ! rg -q 'ContextMenuPreviewLifecycleObserver' \
    eMeishi/Views/Components/ContextMenuInteractionGate.swift \
    || ! rg -q 'transitionCoordinator\.animate\(' \
        eMeishi/Views/Components/ContextMenuInteractionGate.swift \
    || ! rg -q 'static func dismantleUIViewController' \
        eMeishi/Views/Components/ContextMenuInteractionGate.swift \
    || ! rg -q 'func reset\(\)' eMeishi/Views/Components/ContextMenuInteractionGate.swift \
    || ! rg -q 'contextMenuInteractionGate\.reset\(\)' eMeishi/Views/CardListView.swift \
    || ! rg -q 'isCardListBackgroundInteractionBlocked' eMeishi/ContentView.swift; then
  fail "コンテキストメニューdismissはtransition完了で確定し、一覧全体の遮断と画面離脱時resetを行ってください"
fi

if ! rg -q '\.contentMargins\(\.trailing, showIndex \? 44 : 0, for: \.scrollContent\)' \
        eMeishi/Views/CardListView.swift; then
  fail "セクション索引のhit領域がカードに重ならないよう、索引幅分のscroll content marginを確保してください"
fi

if ! rg -q 'if let existing = sessions\[jobID\], existing\.isTerminal' \
    eMeishi/Services/OCRProcessingCoordinator.swift \
    || ! rg -q 'guard var session = sessions\[jobID\] else' \
        eMeishi/Services/OCRProcessingCoordinator.swift; then
  fail "セッション生成前のOCRキャンセルをstartで上書きしないでください"
fi

if ! rg -q '@State private var contactsExportTask: Task<Void, Never>\?' \
    eMeishi/Views/CardDetailView.swift \
    || ! rg -q 'viewLifetimeID == lifetimeID' eMeishi/Views/CardDetailView.swift \
    || ! rg -q 'contactsExportTask\?\.cancel\(\)' eMeishi/Views/CardDetailView.swift; then
  fail "詳細画面の連絡先保存とURL完了は画面世代へ束縛し、離脱時に取消してください"
fi

if rg -n 'card\.(tagArray|phoneList|fullName|fullNameReading|company|department|title|email|address|website|notes|createdAt|isFavorite)' \
        eMeishi/Views/CardDetailView.swift \
        eMeishi/Views/Components/CardPeekView.swift >/dev/null \
    || ! rg -q 'CardListItemSnapshot' eMeishi/Views/CardDetailView.swift \
    || ! rg -q 'CardListItemSnapshot' eMeishi/Views/Components/CardPeekView.swift; then
  fail "詳細・ピークのbodyはCore Data属性やrelationshipを繰り返し評価せず、一覧と同じ値型itemを共有してください"
fi

if ! rg -Fq '@Environment(\.scenePhase) private var scenePhase' \
        eMeishi/Views/SettingsView.swift \
    || ! rg -q '@State private var biometricType:' \
        eMeishi/Views/SettingsView.swift \
    || ! rg -Fq '.task(id: scenePhase)' eMeishi/Views/SettingsView.swift \
    || ! rg -q 'refreshAvailableBiometricType' eMeishi/Views/SettingsView.swift \
    || ! rg -q 'cachedBiometricType' eMeishi/Services/AuthenticationService.swift \
    || ! rg -q 'SettingsDateFormatters' eMeishi/Views/SettingsView.swift; then
  fail "設定画面の生体認証可否と日付formatterはbody評価ごとに再生成せず、foreground更新とキャッシュへ集約してください"
fi

if ! rg -q '@State private var advanceTaskGate = SecondaryViewTaskGate' \
        eMeishi/Views/BatchReviewView.swift \
    || ! rg -q 'advanceTaskGate\.cancel\(\)' eMeishi/Views/BatchReviewView.swift \
    || ! rg -q 'advancingInputID = nil' eMeishi/Views/BatchReviewView.swift \
    || ! rg -q 'isAdvancing = false' eMeishi/Views/BatchReviewView.swift; then
  fail "バッチ送りは操作世代を照合し、画面離脱時にTask・入力ID・操作ロックをすべて無効化してください"
fi

if ! rg -q '@State private var confirmationCommitTask: Task<Void, Never>\?' \
    eMeishi/Views/CardListView.swift \
    || ! rg -q 'viewLifetimeID == lifetimeID' eMeishi/Views/CardListView.swift \
    || ! rg -q 'confirmationCommitTask\?\.cancel\(\)' eMeishi/Views/CardListView.swift; then
  fail "一覧の確認UI後に開始するTaskを画面世代へ束縛してください"
fi

if ! rg -q '@State private var authenticationTask: Task<Void, Never>\?' \
    eMeishi/Views/LockScreenView.swift \
    || ! rg -q 'viewLifetimeID == lifetimeID' eMeishi/Views/LockScreenView.swift \
    || ! rg -q 'authenticationTask\?\.cancel\(\)' eMeishi/Views/LockScreenView.swift; then
  fail "生体認証Taskをロック画面の寿命へ束縛してください"
fi

if ! rg -q 'CardFormExitLifecycle' eMeishi/Views/CardFormView.swift \
    || ! rg -q '@State private var exitTask: Task<Void, Never>\?' \
        eMeishi/Views/CardFormView.swift \
    || ! rg -q -U '\.interactiveDismissDisabled\([[:space:]]*viewModel\.isProcessingOCR[[:space:]]*\|\|[[:space:]]*exitLifecycle\.isExiting[[:space:]]*\|\|[[:space:]]*viewModel\.isSaving[[:space:]]*\)' \
        eMeishi/Views/CardFormView.swift; then
  fail "フォームのスキップ・閉じるは画面寿命付きの単一終了Taskへ集約してください"
fi

if [[ ! -f eMeishi/App/PrivacyShieldWindow.swift ]] \
    || ! rg -q '\.privacyShieldWindow\(' eMeishi/App/eMeishiApp.swift; then
  fail "system sheetを含むApp Switcherスナップショットはscene専用Privacy Shield Windowで保護してください"
fi

if rg -n 'Task\.yield\(\)' \
    eMeishi/Views/CardListView.swift \
    eMeishi/Views/CardDetailView.swift \
    eMeishi/Views/CardFormView.swift \
    eMeishi/Views/SettingsView.swift \
    eMeishi/Views/TagManagementView.swift \
    eMeishi/Views/Components/CardAdditionFlowModifier.swift \
    eMeishi/Views/Components/ContextMenuInteractionGate.swift >/dev/null; then
  fail "presentation完了をMainActorの1ターン待機で推測しないでください"
fi

sleep_owners="$({ rg -l 'Task\.sleep' eMeishi/Views --glob '*.swift' || true; } | sort | mapfile_compat)"
if [[ -n "$sleep_owners" ]]; then
  fail "View遷移の固定時間待機は禁止です。UIKit/SwiftUIの完了通知を使用してください。現在: $sleep_owners"
fi

if [[ "$failures" -gt 0 ]]; then
  exit 1
fi

echo "UIライフサイクルガード: PASS"
