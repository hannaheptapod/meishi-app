import SwiftUI
import UIKit

/// ファイルアプリと同様に、並べ替え・フィルター・解除を1つの標準メニューへまとめる。
struct NativeSortFilterMenuButton: UIViewRepresentable {
    struct TagOption: Identifiable, Equatable {
        let id: UUID
        let name: String
    }

    /// SwiftUIの再評価と、メニュー内容の変更を分離するための値スナップショット。
    /// Navigation transition中の無関係なbody更新でUIMenuを作り直さない。
    fileprivate struct RenderState: Equatable {
        let sortKey: CardSortKey
        let sortAscending: Bool
        let showFavoritesOnly: Bool
        let tags: [TagOption]
        let selectedTagIDs: Set<UUID>
        let externalFilterTitle: String?
        let isFilterActive: Bool
        let accessibilityValue: String
    }

    let sortKey: CardSortKey
    let sortAscending: Bool
    let showFavoritesOnly: Bool
    let tags: [TagOption]
    let selectedTagIDs: Set<UUID>
    let externalFilterTitle: String?
    let isFilterActive: Bool
    let accessibilityValue: String
    let onSelectSort: (CardSortKey) -> Void
    let onSelectAllCards: () -> Void
    let onSetFavorites: (Bool) -> Void
    let onSetTag: (UUID, Bool) -> Void
    let onClearExternalFilter: () -> Void
    let onResetFilters: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(configuration: self)
    }

    func makeUIView(context: Context) -> UIButton {
        // ナビゲーションツールバーが標準のLiquid Glass外形を付けるため、
        // UIButton自身には背景を持たせず二重の輪郭を防ぐ。
        let button = UIButton(configuration: .plain())
        button.showsMenuAsPrimaryAction = true
        button.accessibilityLabel = "並べ替え・フィルター"
        button.accessibilityIdentifier = "sortFilterMenu"
        update(button, coordinator: context.coordinator)
        return button
    }

    func updateUIView(_ button: UIButton, context: Context) {
        context.coordinator.configuration = self
        update(button, coordinator: context.coordinator)
    }

    private func update(_ button: UIButton, coordinator: Coordinator) {
        let renderState = RenderState(
            sortKey: sortKey,
            sortAscending: sortAscending,
            showFavoritesOnly: showFavoritesOnly,
            tags: tags,
            selectedTagIDs: selectedTagIDs,
            externalFilterTitle: externalFilterTitle,
            isFilterActive: isFilterActive,
            accessibilityValue: accessibilityValue
        )
        guard coordinator.lastRenderState != renderState else { return }

        var configuration = UIButton.Configuration.plain()
        configuration.contentInsets = .zero
        configuration.image = UIImage(
            systemName: isFilterActive
                ? "line.3.horizontal.decrease.circle.fill"
                : "line.3.horizontal.decrease"
        )
        configuration.baseForegroundColor = isFilterActive
            ? UIColor(AppTheme.brandOrange)
            : .label
        button.configuration = configuration
        button.accessibilityValue = accessibilityValue
        button.menu = coordinator.makeMenu()
        coordinator.lastRenderState = renderState
    }

    @MainActor
    final class Coordinator {
        var configuration: NativeSortFilterMenuButton
        fileprivate var lastRenderState: RenderState?

        init(configuration: NativeSortFilterMenuButton) {
            self.configuration = configuration
        }

        func makeMenu() -> UIMenu {
            var sections: [UIMenuElement] = [sortMenu, filterMenu]
            if let externalFilterMenu {
                sections.append(externalFilterMenu)
            }
            sections.append(resetMenu)
            return UIMenu(children: sections)
        }

        private var sortMenu: UIMenu {
            let actions = CardSortKey.allCases.map { key in
                let isSelected = configuration.sortKey == key
                return UIAction(
                    title: key.rawValue,
                    subtitle: isSelected
                        ? (configuration.sortAscending ? "昇順" : "降順")
                        : nil,
                    image: nil,
                    identifier: UIAction.Identifier("sortOption_\(key.rawValue)"),
                    state: isSelected ? .on : .off
                ) { [weak self] _ in
                    self?.configuration.onSelectSort(key)
                }
            }
            return UIMenu(title: "並べ替え", options: .displayInline, children: actions)
        }

        private var filterMenu: UIMenu {
            var actions: [UIMenuElement] = [
                UIAction(
                    title: "すべての名刺",
                    image: UIImage(systemName: "rectangle.grid.1x2"),
                    identifier: UIAction.Identifier("allCardsFilterOption"),
                    state: configuration.isFilterActive ? .off : .on
                ) { [weak self] _ in
                    guard let configuration = self?.configuration,
                          configuration.isFilterActive else { return }
                    configuration.onSelectAllCards()
                },
                UIAction(
                    title: "お気に入り",
                    image: UIImage(systemName: "star"),
                    identifier: UIAction.Identifier("favoritesFilterOption"),
                    state: configuration.showFavoritesOnly ? .on : .off
                ) { [weak self] _ in
                    guard let configuration = self?.configuration else { return }
                    configuration.onSetFavorites(!configuration.showFavoritesOnly)
                },
            ]

            if !configuration.tags.isEmpty {
                let tagActions = configuration.tags.map { tag in
                    let isSelected = configuration.selectedTagIDs.contains(tag.id)
                    return UIAction(
                        title: tag.name,
                        image: UIImage(systemName: "tag"),
                        identifier: UIAction.Identifier("tagFilter_\(tag.name)"),
                        state: isSelected ? .on : .off
                    ) { [weak self] _ in
                        guard let configuration = self?.configuration else { return }
                        configuration.onSetTag(
                            tag.id,
                            !configuration.selectedTagIDs.contains(tag.id)
                        )
                    }
                }
                actions.append(
                    UIMenu(
                        title: "タグ",
                        image: UIImage(systemName: "tag"),
                        identifier: UIMenu.Identifier("tagFilterMenu"),
                        children: tagActions
                    )
                )
            }

            return UIMenu(title: "フィルター", options: .displayInline, children: actions)
        }

        private var externalFilterMenu: UIMenu? {
            guard let title = configuration.externalFilterTitle else { return nil }
            let action = UIAction(
                title: title,
                image: UIImage(systemName: "chart.line.uptrend.xyaxis"),
                identifier: UIAction.Identifier("externalFilterOption"),
                state: .on
            ) { [weak self] _ in
                self?.configuration.onClearExternalFilter()
            }
            return UIMenu(
                title: "Insightsからの絞り込み",
                options: .displayInline,
                children: [action]
            )
        }

        private var resetMenu: UIMenu {
            let action = UIAction(
                title: "フィルターをリセット",
                image: UIImage(systemName: "arrow.counterclockwise"),
                identifier: UIAction.Identifier("resetFiltersButton"),
                attributes: configuration.isFilterActive ? [] : .disabled
            ) { [weak self] _ in
                self?.configuration.onResetFilters()
            }
            return UIMenu(options: .displayInline, children: [action])
        }
    }
}

/// カメラ・写真・手入力・未完了OCRを同じ操作階層で提示する追加シート。
struct AddCardSheet: View {
    let pendingCount: Int
    let isImporting: Bool
    let onCamera: () -> Void
    let onPhotos: () -> Void
    let onManual: () -> Void
    let onResume: (() -> Void)?

    var body: some View {
        NavigationStack {
            VStack(spacing: AppTheme.Spacing.medium) {
                addAction(
                    title: "カメラで撮影",
                    detail: "名刺を撮影して文字を読み取ります",
                    systemImage: "camera",
                    action: onCamera
                )
                addAction(
                    title: "写真から読み込む",
                    detail: "写真ライブラリから最大10枚選べます",
                    systemImage: "photo.on.rectangle.angled",
                    action: onPhotos
                )
                addAction(
                    title: "手動で入力",
                    detail: "画像を使わずに名刺を登録します",
                    systemImage: "square.and.pencil",
                    action: onManual
                )
                if let onResume {
                    addAction(
                        title: "未完了の読み取りを再開",
                        detail: "\(pendingCount)枚の確認を続けます",
                        systemImage: "arrow.clockwise",
                        action: onResume
                    )
                }
                Spacer(minLength: 0)
            }
            .padding(AppTheme.Spacing.large)
            .navigationTitle("名刺を追加")
            .navigationBarTitleDisplayMode(.inline)
        }
        .disabled(isImporting)
    }

    private func addAction(
        title: String,
        detail: String,
        systemImage: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: AppTheme.Spacing.medium) {
                Image(systemName: systemImage)
                    .font(.title3)
                    .foregroundStyle(.primary)
                    .frame(width: 32)
                VStack(alignment: .leading, spacing: AppTheme.Spacing.xSmall) {
                    Text(title)
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(AppTheme.Spacing.large)
            .frame(maxWidth: .infinity, minHeight: 76, alignment: .leading)
            .contentShape(.rect(cornerRadius: AppTheme.contentCornerRadius, style: .continuous))
        }
        .buttonStyle(.glass)
        .tint(Color.primary)
        .accessibilityLabel(title)
    }
}
