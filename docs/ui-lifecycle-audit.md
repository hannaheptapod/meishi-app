# UIライフサイクル監査

更新日: 2026-07-23

この文書は、画面遷移中だけ発生する表示欠落や背面誤反応を、症状ではなく状態所有の問題として追跡するための監査台帳です。

| ID | 重大度 | 問題 | 根因 | 恒久対応 | 回帰確認 |
|---|---|---|---|---|---|
| UI-001 | Critical | 一覧へ戻る途中に検索枠が消える | 幅ごとにNavigationルートを差し替え、検索UIの所有Viewまで作り直していた | 単一`NavigationSplitView`を全幅で維持し、一覧Navigation Itemと同じ寿命の`CardListView`が標準`searchable`を所有 | 戻る遷移の開始・中間・終了を動画とUIテストで確認 |
| UI-002 | Critical | Tab Barと追加ボタンが遅れて表示され、位置と高さもずれる | Tab Bar座標をアクセシビリティ階層から非同期探索し、実測値を再びレイアウトへ反映 | 座標探索を削除し、標準Tab配置だけで構成 | iPhone各表示状態で位置とタップ領域を確認 |
| UI-003 | High | 追加フローでシートが競合し、カメラが即閉じる | 複数Booleanとdismiss開始直後の次presentation、Window直present | 単一の型付き状態機械と単一presentation ownerへ集約し、dismiss要求と実完了を別状態にする | カメラ・写真・手入力・未完了OCRを連続実行 |
| UI-004 | High | コンテキストメニュー終了時に背面カードが光る | preview消失や固定時間をUIKitのdismiss完了と誤認 | session ID付きgateで実dismiss完了まで背面入力とメニュー起点の次操作を保留 | 同じ位置と別カード上でdismiss |
| UI-005 | High | 戻る際にカードやツールバーが別々に再描画される | 画面全体への暗黙アニメーションと広すぎるrevision | 変更要素だけの局所アニメーションへ限定 | 詳細・設定・重複確認からの連続復帰 |
| UI-006 | High | iPadで選択後の削除・同期により詳細参照が陳腐化する | Navigation状態が`NSManagedObject`を長期保持 | URIまたはobject IDで保持し、表示時にContextから解決 | 選択中削除・同期・サイズ変更 |
| UI-007 | Medium | Insightsの押下や更新で周辺レイアウトが動く | pressed styleがpadding/scaleを変更し、body内で全カードrevisionを再生成 | 寸法不変の押下表現と安定スナップショット | チャート連続操作・スクロール |
| UI-008 | Medium | UIテスト成功でも遷移途中の欠落を検出できない | 完了後の`exists`/`isHittable`だけを検証 | 中間チェックポイント、動画記録、0件実行防止を併用 | iPhone/iPadの遷移マトリクス |
| UI-009 | Medium | 起動直後に白画面が継続する場合がある | 起動初期化の区間計測がなく、同期処理の占有時間を識別不能 | 起動区間を計測し、UI成立に不要な処理を初期描画後へ移動 | cold/warm launch計測 |
| UI-010 | High | 詳細から戻った直後だけサムネイルがプレースホルダーになる | 画像以外の`updatedAt`変更で画像キャッシュまで無効化し、キャッシュヒットもactor越しに遅延 | 画像内容由来の安定キーと同期キャッシュ参照へ分離 | お気に入り・タグ・テキスト編集後の往復を動画確認 |
| UI-011 | High | iPadで設定・重複確認が狭い一覧列へ表示され、古い詳細が残る | compact/regularで別Navigationコンテナと別ルート状態を使用 | 全幅で単一`NavigationSplitView`と単一の型付き`activeCardsRoute`を共有し、compactは`preferredCompactColumn`だけを切り替える | iPadで設定・重複・名刺詳細・回転を往復 |
| UI-012 | High | 非同期処理完了時に別のsheet/alertと競合する | 1画面に複数の独立presentation状態を保持 | 型付き単一状態とrequest ID付きFIFOへ統合し、古いdismiss callbackを拒否 | 共有中のエラー・編集終了・連絡先保存を連続操作 |
| UI-013 | Critical | ストア読込み失敗後も通常画面とサービスが先に起動する | 非同期`loadPersistentStores`の結果をinit時の固定値として扱う | Observableな読込み状態でrootと起動サービスをゲート | 読込み遅延・失敗を注入して起動画面を確認 |
| UI-014 | High | インサイトを開くと初期描画・操作が止まる | MainActor上で全名刺を同期集計 | Sendableスナップショットをworker actorで集計し、世代一致時だけ反映 | 大量合成データでタブ切替・再読込みを計測 |
| UI-015 | Medium | iCloudの「同期中」が実処理と無関係に2秒表示される | 固定sleepを同期完了扱いに使用 | CloudKitイベント由来の状態だけを表示 | 成功・失敗・イベントなしを個別確認 |
| UI-016 | Critical | 起動案内と追加・Paywallが同時要求される | アプリルートと`ContentView`が別々のalert/sheetを所有 | 起動案内をFIFO requestとして共通追加フローへ渡し、ルートpresentation ownerを1つに限定 | cold launch直後に追加・AI検索を連続操作 |
| UI-017 | Critical | App Switcherのスナップショットへsystem sheet内容が残る | SwiftUI overlayは別presentation windowより下に描画される | sceneごとの非Key・非操作Privacy Shield Windowをsystem presentationより高いlevelに置く | sheet・alert・写真Picker表示中にinactive/backgroundへ移行 |
| UI-018 | High | 写真選択後に取込み表示とPicker dismissalが衝突する | 選択値の変更時点で次処理を開始 | 選択値を保留し、UIKit上でPickerが離脱した後にだけ順次decode・取込みを開始 | 選択・キャンセル・iCloud待機・部分失敗を連続確認 |
| UI-019 | High | 一覧復帰時に画像表示だけ遅れる | キャッシュヒットまでactor hopが必要で、画像以外の更新でもキーが変わる | 同期参照可能なlock付きcacheと`imageData`変更イベント由来のrevisionを使用 | テキスト・タグ・お気に入り変更後に往復 |
| UI-020 | High | 重複統合の確認で親sheetまで閉じる、または次dialogと競合する | sheet内のconfirmation dialogを別presentationとして重ねた | 同一sheet内の確認phaseへ切り替え、統合実行後だけ親を閉じる | 戻る・統合・保存失敗を個別確認 |
| UI-021 | High | 確認ダイアログの背後で削除・リセット処理が始まり、画面が先に更新される | ボタン処理をdialogのdismiss要求と同時に開始 | request ID付き`DismissalCommitState`で副作用を実dismiss完了後まで保留 | タグ・カード・モデル・iCloudリセットの確認とキャンセルを連続操作 |
| UI-022 | High | 閉じたカメラから遅れて画像が追加される、または再表示直後に前回結果が混入する | 撮影・切抜きTaskが画面ライフサイクルと独立して継続 | ライフサイクルIDと撮影IDを各`await`後に照合し、終了時にTaskとsessionを冪等に停止 | 撮影中キャンセル・背景移行・再起動を実機確認 |
| UI-023 | High | バッチ確認中に閉じると、表示位置と再開キューの先頭がずれる | 永続キュー更新中もinteractive dismiss可能 | 先頭削除中と復旧判断中はdismissを禁止し、削除完了後だけ次項目へ進む | 保存・スキップ・書込み失敗・再開を連続確認 |
| UI-024 | Medium | 詳細画像を開いた最初のフレームだけProgressViewになる | 同期キャッシュヒットがあっても非同期Task完了まで表示に使わない | bodyで同期キャッシュを最優先し、未キャッシュ時だけ非同期decode | 同じ画像を開閉して初期フレームを動画確認 |
| UI-025 | Medium | 一覧の初回設定が詳細から戻るたびに再実行され、検索・フィルターが揺れる | `onAppear`を初期化と継続同期の両方に使用 | 一度だけ行う準備と、毎回同期する外部フィルターを分離 | 詳細・設定・インサイト絞り込みから連続復帰 |
| UI-026 | Medium | ソート・フィルターメニューの内容が行再描画ごとに作り直される | `updateUIView`のたびにconfigurationとUIMenuを無条件再生成 | 表示に必要な値を`RenderState`へ集約し、変更時だけ再構成 | 一覧スクロール・フィルター切替時の応答を確認 |
| UI-027 | Medium | 画面に存在しない古いcompact/regular用遷移が残り、修正箇所により挙動が分岐する | `usesSplitView`固定後もfalse分岐と別Pathを温存 | 到達不能分岐を削除し、詳細列を単一`activeCardsRoute`へ縮約 | 静的ガードと状態テストで旧APIの再導入を拒否 |
| UI-028 | High | UIテスト名の誤指定や一部未実行を成功として扱う | `xcodebuild`終了コードと「1件以上実行」だけを確認 | ソース内のメソッド存在と指定件数＝実行件数をラッパーで照合 | 存在しない名前・0件・一部実行・正常実行を個別確認 |
| UI-029 | High | 初回表示やカード更新時に一覧操作・戻る遷移が止まる | MainActor上で全カードのO(n²)重複比較を同期実行 | Core DataからSendableスナップショットを作り、キャンセル可能なworkerで1回だけ比較し、世代一致時だけ反映 | 大量合成カードで表示・更新・連続キャンセルを確認 |
| UI-030 | Critical | カメラ権限確認後に撮影画面が即座に閉じる、または準備が完了しない | `scenePhase == inactive`を画面終了と同一視し、権限dialog表示中に構造化Taskをキャンセル | active/inactiveをforegroundへ正規化し、backgroundへの遷移だけでsessionを止める | 初回許可・拒否・設定復帰・背景移行を確認 |
| UI-031 | High | フィルター適用中の再取得で一瞬だけ全カードが見える | fetch結果を公開してから別々にfilter/group結果を更新 | 世代付きworkerで検索・ソート・グループ化を完了し、単一`CardListDisplaySnapshot`を1回だけ公開 | 外部・タグ・お気に入りfilter中に保存・同期・復帰 |
| UI-032 | Medium | 検索語を消しても空状態が短時間残る | 検索入力と検索解除へ同じdebounceを適用 | 非空入力だけをdebounceし、空白を含む検索解除は即時評価 | 0件検索からclear、キャンセル、戻るを確認 |
| UI-033 | High | 写真取込みを閉じてもdecodeやキュー保存が継続し、後から画面が切り替わる | 取込みTaskをpresentationの寿命へ束縛せず、互換形式への変換も先に要求 | 取込み・カメラ準備Taskを追跡取消し、元形式をImageIOで段階的に縮小decode | 10枚選択中のcancel・dismiss・再開始 |
| UI-034 | High | 大量バッチの保存・スキップが進むほど待ち時間とメモリが増える | 先頭削除のたびに残り画像を全読込み・全再書込み | manifestだけを原子的に置換し、確定後に消費済み1ファイルだけ削除 | 10枚キューの連続保存・書込み失敗・再開 |
| UI-035 | Critical | inactive復帰時に保護画面より先にPrivacy Shieldが外れ、内容が一瞬露出する | lock判定完了を保護UIの描画完了と誤認 | 保護UIの実レイアウト完了世代をprobeで通知し、一致した世代だけShield解除 | ロック有無・sheet表示中・連続active/inactive |
| UI-036 | High | コンテキストメニューを余白で閉じた直後に背面カードがhighlightする | root ViewControllerの状態や一定時間でdismiss完了を推測 | preview controllerの`viewWillDisappear`とtransition coordinator完了をsession単位で監視 | 背面カード上・余白・同一カード上でdismiss |
| UI-037 | High | OCR開始直後の停止が無視され、後から進捗・Live Activityが復活する | coordinatorのsession生成より先に届いたcancelを後続startが上書き | 未生成jobも終端cancel sessionとして記録し、startは既存終端状態を保持 | init直後停止・Debug遅延中停止・バッチ次項目開始 |
| UI-038 | High | 確認dialogを閉じる途中で削除・取込み・次presentationが始まる | dismiss要求と副作用開始を同じactionで実行 | 実dismiss完了をrequest IDで照合し、commit完了後だけ次要求を提示 | 設定・タグ・カード・モデル確認を連続操作 |
| UI-039 | High | 詳細・フォームを閉じた後に連絡先保存、URLオープン、OCR停止の完了が古い画面へ書き戻る | 画面から生成したTaskと完了ハンドラを画面寿命へ束縛していない | 画面世代とrequest IDを照合し、Taskを`@State`で所有して`onDisappear`で取消す。スキップ・閉じるはexactly-once状態機械へ集約 | 連絡先保存中の戻る、リンク直後の戻る、OCR中のスキップ連打・閉じるを確認 |
| UI-040 | High | インサイト初期表示や再集計中にタブ切替・スクロールが止まる | MainActorのview contextで全名刺をfetchし、タグrelationshipを含む値変換まで同期実行 | private queue contextでタグをprefetchしてSendableスナップショットへ変換し、集計完了値だけを世代照合後に公開 | 大量合成データで再集計中のタブ切替、取消し、再試行を確認 |
| UI-041 | Critical | 一覧初期表示・復帰時に検索枠、Tab Bar、カードが一瞬遅れる | MainActorのview contextで全名刺をfetchし、検索値・タグ・表示値を全件展開していた | private queue contextでfetch・prefetch・値型化まで完結し、URIから管理オブジェクトを解決して完成スナップショットと同時に公開 | 大量合成データで詳細からの連続pop、検索clear、保存後復帰を確認 |
| UI-042 | High | 一覧カードが初回だけ名前なし・タグなしで描かれてから更新される | 管理オブジェクト配列と行表示値を別々のタイミングで公開していた | `CardRowDisplaySnapshot`を検索スナップショットと同じprivate fetchから生成し、行表示値を先に揃えてから一覧をpublish | cold launchと同期直後の各行を動画確認 |
| UI-043 | High | 一覧更新直後に重複検出用の全属性採取で遷移が詰まる | O(n²)比較だけをworkerへ移し、その入力生成はMainActorで全カードを再走査していた | 一覧private fetchから`DuplicateCardSnapshot`も生成し、比較入力を管理オブジェクトへ戻さない | 大量合成データ更新中のスクロール・pop応答を確認 |
| UI-044 | High | 追加シートをキャンセルしただけで一覧全体が再取得され、dismiss途中の表示が揺れる | 保存有無に関係なくdismiss時にfetchし、保存通知も別途fetchしていた | 保存成功を記録し、Core Data通知をsheet寿命中だけ保留して、実dismiss後に必要な再取得を1回だけ実行 | カメラ・写真・手入力のキャンセルと保存を連続確認 |
| UI-045 | Medium | タグ管理や一括タグ画面の表示・更新でスクロールが止まる | View評価中またはMainActorで`Tag.cards`・`BusinessCard.tags`を繰り返し展開していた | private queueの`TagDisplaySnapshotLoader`と一覧のtag IDスナップショットから件数・付与状態を算出 | 大量タグ・大量選択でsheet開閉と連続トグルを確認 |
| UI-046 | High | 起動直後に一覧操作が止まり、会社名読みの移行完了フラグだけ先に立つ可能性がある | view context上で全名刺を移行し、保存失敗と完了状態を分離していなかった | `CompanyReadingMigrationWorker`のprivate contextで移行・保存し、保存成功後だけ該当フラグを記録 | 大量合成データ、保存失敗、取消しを単体テスト |
| UI-047 | Medium | 一覧画像が多いほどcontext生成が増え、復帰時の画像表示がばらつく | 行ごとの画像要求でprivate contextを毎回生成していた | persistent store coordinator単位の読取専用contextを再利用し、各BLOB取得後にreset | 大量画像一覧の往復とメモリグラフを確認 |
| UI-048 | High | 設定・課金・モデル・一括タグ画面を閉じた後に古い結果が次の画面へ反映される | 画面起点Taskの取消しだけに依存し、既に完了へ向かうservice Taskの結果世代を照合していなかった | `SecondaryViewTaskGate`でoperation IDと画面寿命を照合し、古い結果を破棄 | 処理中の戻る・再表示・連打を各画面で確認 |
| UI-049 | Medium | 一覧を一度表示した後、非表示中に完了した共有・連絡先結果が復帰しても出ない | `onAppear`全体を一度限りの初期化guardより後ろへ置いていた | 復帰ごとの外部filter・presentation signal取込みと、一度限りのスクリーンショット準備を分離 | 詳細・共有sheet・連絡先権限からの復帰を確認 |
| UI-050 | Critical | 詳細から戻る途中にカード、検索枠、Tab Barの一部が遅れて現れる | `ForEach`・選択・遷移先が`BusinessCard`を保持し、遷移transaction中にCore Data faultとrelationshipをMainActorで解決していた | private contextで`CardListItemSnapshot`まで完成させ、一覧・ピーク・詳細・画像要求・選択を永続URI付きの同じ値型へ統一する | 大量合成カードで詳細を連続push/popし、遷移中のMain Thread hangとfault発生を確認 |
| UI-051 | Critical | Split Viewで詳細を開いただけなのに一覧の検索・保留操作が破棄され、戻り時に再生成される | sidebarが非表示になった`onDisappear`を、名刺機能全体からの離脱と同一視して画面世代・Task・presentationを無効化していた | `NavigationSplitView`内の列表示と機能ルート寿命を分離し、名刺タブ自体を離れた時だけ一覧操作を無効化する | iPhone・iPadで詳細往復、列表示切替、タブ往復を連続確認 |
| UI-052 | High | 選択モード切替時に上部操作が組み直され、検索枠やToolbarが一瞬欠落する | 条件分岐でToolbar item群そのものを丸ごと差し替えていた | Toolbarのスロット数と所有Viewを安定させ、表示内容・有効状態だけを切り替える | 選択開始・全選択・完了をスクロール位置別に確認 |
| UI-053 | High | コンテキストメニューを余白で閉じると検索・Toolbar・別カードが反応する、または遮断状態が残る | 入力遮断overlayが`List`内だけを覆い、画面離脱時にgateとobserver sessionを破棄していなかった | 一覧Navigation Item全体を最前面で遮断し、observer dismantleと画面離脱時resetを冪等に行う | 検索欄・Toolbar・カード・余白の各位置でdismissし、即時再表示も確認 |
| UI-054 | High | 右端の索引を操作すると背後のカードもhighlight・遷移する | 44ptの索引タップ領域をカードのscroll content上へ重ねていた | 索引と同じ44ptのscroll content marginを確保し、索引とカードのhit領域を分離する | 最大Dynamic Typeと各セクション位置でドラッグ・タップを確認 |
| UI-055 | High | フォーム・一括タグ・タグ管理の表示中に行が遅れて更新される | `Tag`や`Tag.cards`をViewの`ForEach`とbodyで直接評価していた | `TagDisplaySnapshot`へ永続URI・永続UUID・色・使用件数を確定し、編集時だけURIから管理オブジェクトを解決する | 大量合成タグでフォーム展開、複数選択、一括付与、編集を連続確認 |
| UI-056 | High | 名刺タブを離れた後に古い確認処理やsheet要求が戻ってくる | 詳細列の非表示とタブ離脱を区別せず、逆にタブ離脱時の一時状態を残していた | 選択タブの変更時だけ画面世代を更新し、確認Task・presentation queue・入力gateを一括終了する | 確認中・メニュー表示中・sheet要求中にタブを往復 |
| UI-057 | High | 編集開始時に詳細が保持する管理オブジェクトをそのままフォームへ渡し、同期後に古い値を表示する | 表示スナップショットと編集対象の解決境界がView内に散在していた | 詳細は永続URIだけを渡し、ViewModelが現在のview contextから編集対象を直前解決する | 詳細表示中の同期・削除・編集開始を連続確認 |

## 実装上の禁止事項

- Tab BarやNavigation Barの座標をWindow階層・アクセシビリティ階層から探索しない。
- presentation制御や誤タップ防止に固定時間待機を使わない。
- 同じ画面階層で複数のsheet用Booleanを独立管理しない。
- Navigationコンテナの外側へ、そのコンテナに属する`searchable`を置かない。
- サイズクラスの条件分岐でNavigationコンテナそのものを交換しない。
- 画面全体の連結文字列や全Entity配列を暗黙アニメーションの値にしない。
- UI状態として`NSManagedObject`を長期保持しない。
- 非同期ストア読込み完了前に、Core Data依存画面や課金・同期サービスを開始しない。
- キャッシュ世代へ、対象データと無関係な更新日時を流用しない。
- dismiss後の次操作を`Task.yield()`や固定delayで開始しない。
- コンテキストメニューの項目から、メニューが実際に離脱する前にsheet・dialog・Navigation遷移を開始しない。
- アプリルートへ独立したalert・sheet ownerを追加しない。
- SwiftUI overlayだけでsystem presentationを含むプライバシースナップショットを保護しない。
- confirmation dialogのボタンから破壊的副作用を直接開始しない。
- `onAppear`へ画面の一度限りの初期化と、復帰ごとの同期処理を混在させない。
- `UIViewRepresentable.updateUIView`で入力が不変なのにconfigurationやmenuを再構成しない。
- UIテストは`xcodebuild`成功だけで合格にせず、要求件数と実行件数を照合する。
- MainActor上で全カードの全ペア比較を実行しない。
- MainActor上でインサイト用の全件fetch・relationship評価・スナップショット変換を実行しない。
- フィルター済み一覧とセクション一覧を別々の`@Published`値として順次更新しない。
- 写真取込み・カメラ準備・OCRなど、画面を閉じても継続すべきでないTaskを未追跡で生成しない。
- 画面から開始したTaskやURL完了ハンドラは、画面世代とrequest IDを照合せずに状態を書き戻さない。
- Privacy Shieldを、保護対象Viewの実描画より先に解除しない。
- 画像キャッシュキーへ部分Dataサンプルを使用しない。
- 一覧・ピーク・詳細・サムネイルの描画状態として`BusinessCard`や`NSManagedObjectID`を保持しない。
- 一覧の選択・一括操作APIへ`BusinessCard.ID`や`NSManagedObjectID`を渡さず、永続URIを使う。
- `NavigationSplitView`のsidebarが非表示になる`onDisappear`を、名刺機能全体の離脱通知として使わない。
- タブ離脱時に、前の画面世代へ属する確認Task・presentation・入力gateを残さない。
- `CardFormView`・`BulkTagAssignView`・`TagManagementView`の`ForEach`へ`Tag`管理オブジェクトを直接渡さない。
- セクション索引のタップ領域を一覧カードのscroll contentへ重ねない。
- Navigation遷移中の行・詳細へ暗黙の`contentTransition`を適用しない。

## 合格条件

- 遷移開始から完了まで、検索、ツールバー、Tab Bar、追加操作の外形が欠落しない。
- 最前面の操作をタップしても背面カードがhighlight・遷移しない。
- 追加フローのどの終了経路でもpresentationが1つだけ残り、元のタブとNavigationPathを維持する。
- compact/regularの切替中もNavigation route・検索query・選択中詳細を失わない。
- 写真Picker・Alert・コンテキストメニューのdismiss途中に次presentationを開始しない。
- inactive/backgroundのスナップショットへ名刺・system sheet・alert内容を残さない。
- Reduce Motion、Reduce Transparency、最大Dynamic Typeでも操作の順序とタップ領域が変わらない。
- 確認UIが完全に消える前に削除・リセット・次presentationを開始しない。
- カメラや画像decodeの古い非同期結果を、閉じた画面や次のセッションへ反映しない。
- 詳細往復中に一覧の検索語・フィルター・選択状態・Toolbar所有者を再生成しない。
- 一覧・詳細の初期フレームは、同一世代の値型スナップショットだけで完全に描画できる。
- 索引、検索、Toolbar、コンテキストメニューの最前面操作で背面カードがhighlightしない。
