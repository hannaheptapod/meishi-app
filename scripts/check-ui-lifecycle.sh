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
  fail "Tab Bar表示制御は遷移より長く生存するContentViewの1箇所だけにしてください。現在: ${tab_bar_owners:-なし}"
fi

if rg -n 'NavigationLink[[:space:]]*\{' eMeishi/Views/CardListView.swift >/dev/null; then
  fail "CardListViewのルート遷移は親が状態を所有するnavigationDestinationを使用してください"
fi

if ! rg -q '@Published var cardsPath: \[CardListRoute\]' eMeishi/Models/AppNavigationState.swift; then
  fail "名刺側NavigationStackは復帰状態を同期できる型付きPathを使用してください"
fi

if rg -n '@State private var (cardForDetail|isShowingSettings|isShowingDuplicates)' eMeishi/Views/CardListView.swift >/dev/null; then
  fail "ルート遷移を画面ローカルBoolへ戻さないでください"
fi

if ! rg -q 'rootAddButtonOverlay' eMeishi/ContentView.swift; then
  fail "追加ボタンの表示制御はContentViewのルートオーバーレイで所有してください"
fi

compact_add_button_owners="$({ rg -l 'accessibilityIdentifier\("cardAddButton"\)' eMeishi --glob '*.swift' || true; } | sort | mapfile_compat)"
if [[ "$compact_add_button_owners" != "eMeishi/ContentView.swift" ]]; then
  fail "iPhoneの独立追加ボタンはContentViewだけが所有してください。現在: ${compact_add_button_owners:-なし}"
fi

if ! rg -q 'placement: \.navigationBarDrawer\(displayMode: \.always\)' eMeishi/ContentView.swift; then
  fail "一覧検索は標準searchableのnavigationBarDrawerをContentViewで維持してください"
fi

if rg -n '\.searchable\(' eMeishi/Views/CardListView.swift >/dev/null; then
  fail "CardListViewへsearchableを戻さないでください。pop中の検索背景欠落を防ぐためContentViewが所有します"
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

sleep_owners="$({ rg -l 'Task\.sleep' eMeishi/Views --glob '*.swift' || true; } | sort | mapfile_compat)"
if [[ -n "$sleep_owners" ]]; then
  fail "View遷移の固定時間待機は禁止です。UIKit/SwiftUIの完了通知を使用してください。現在: $sleep_owners"
fi

if rg -n 'CADisplayLink' eMeishi/Views/Components/SystemTabBarFrameReader.swift >/dev/null; then
  fail "Tab Bar座標の常時ポーリングは禁止です"
fi

if [[ "$failures" -gt 0 ]]; then
  exit 1
fi

echo "UIライフサイクルガード: PASS"
