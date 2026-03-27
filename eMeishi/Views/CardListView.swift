import SwiftUI
import UIKit

// 名刺一覧画面
struct CardListView: View {

    @StateObject private var viewModel = CardListViewModel()
    @State private var isShowingForm = false
    @State private var isShowingCamera = false
    @State private var capturedImage: UIImage? = nil
    @State private var isShowingSettings = false
    @State private var isShowingImportConfirm = false
    @State private var isShowingTagManager = false

    var body: some View {
        NavigationStack {
            Group {
                if viewModel.cards.isEmpty {
                    emptyState
                } else {
                    cardList
                }
            }
            .navigationTitle("名刺")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $viewModel.searchText, placement: .toolbar, prompt: "検索")
            .toolbar {
                // 右上: 3点リーダーメニュー
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        if !viewModel.cards.isEmpty {
                            NavigationLink {
                                DuplicateListView(pairs: viewModel.duplicatePairs, onMerge: viewModel.fetchCards)
                            } label: {
                                Label(
                                    viewModel.duplicatePairs.isEmpty ? "重複チェック" : "重複チェック（\(viewModel.duplicatePairs.count)件）",
                                    systemImage: "person.2.slash"
                                )
                            }
                            Divider()
                        }
                        Button {
                            isShowingImportConfirm = true
                        } label: {
                            Label("連絡先からインポート", systemImage: "person.crop.circle.badge.plus")
                        }
                        .disabled(viewModel.isImporting)
                        if !viewModel.cards.isEmpty {
                            Divider()
                            Button { viewModel.exportCSV() } label: {
                                Label("CSV としてエクスポート", systemImage: "tablecells")
                            }
                            Button { viewModel.exportVCard() } label: {
                                Label("vCard としてエクスポート", systemImage: "person.crop.rectangle")
                            }
                        }
                        Divider()
                        Button { isShowingTagManager = true } label: {
                            Label("タグ管理", systemImage: "tag")
                        }
                        Divider()
                        Button { isShowingSettings = true } label: {
                            Label("設定", systemImage: "gearshape")
                        }
                    } label: {
                        Label("メニュー", systemImage: "ellipsis")
                    }
                }

                // 左: 並び替え・フィルタ統合メニュー
                ToolbarItem(placement: .bottomBar) {
                    Menu {
                        // ── フィルタ ──
                        Section("フィルタ") {
                            Button { viewModel.toggleFavoritesFilter() } label: {
                                Label("お気に入りのみ", systemImage: viewModel.showFavoritesOnly ? "checkmark.circle.fill" : "circle")
                            }
                            .menuActionDismissBehavior(.disabled)
                            if !viewModel.allTags.isEmpty {
                                ForEach(viewModel.allTags) { tag in
                                    Button { viewModel.toggleTagFilter(tag) } label: {
                                        Label(tag.tagName, systemImage: viewModel.selectedTagIDs.contains(tag.id ?? UUID()) ? "checkmark.circle.fill" : "circle")
                                    }
                                    .menuActionDismissBehavior(.disabled)
                                }
                            }
                        }

                        // ── 並び替え ──
                        Section("並び替え") {
                            ForEach(CardSortKey.allCases) { key in
                                Button { viewModel.toggleSort(key: key) } label: {
                                    if viewModel.sortKey == key {
                                        Label(key.rawValue, systemImage: viewModel.sortAscending ? "arrow.up" : "arrow.down")
                                    } else {
                                        Text(key.rawValue)
                                    }
                                }
                                .menuActionDismissBehavior(.disabled)
                            }
                        }
                    } label: {
                        Label(
                            "並び替え・フィルタ",
                            systemImage: viewModel.isFilterActive
                                ? "line.3.horizontal.decrease.circle.fill"
                                : "line.3.horizontal.decrease.circle"
                        )
                    }
                }

                // 中央: 検索バー（システム提供・Liquid Glass自動適用）
                ToolbarSpacer(.flexible, placement: .bottomBar)
                DefaultToolbarItem(kind: .search, placement: .bottomBar)
                ToolbarSpacer(.flexible, placement: .bottomBar)

                // 右: 追加ボタン
                ToolbarItem(placement: .bottomBar) {
                    Button {
                        isShowingCamera = true
                    } label: {
                        Label("追加", systemImage: "plus")
                    }
                }
            }
            .sheet(isPresented: $isShowingForm, onDismiss: viewModel.fetchCards) {
                CardFormView(onSave: { isShowingForm = false })
            }
            .fullScreenCover(isPresented: $isShowingCamera) {
                CameraView(capturedImage: $capturedImage)
                    .ignoresSafeArea()
            }
            .sheet(item: $capturedImage, onDismiss: viewModel.fetchCards) { image in
                CardFormView(image: image, onSave: { capturedImage = nil })
            }
            .sheet(item: $viewModel.exportItem) { item in
                ShareSheet(activityItems: [item.url])
            }
            .alert("エラー", isPresented: Binding(
                get: { viewModel.errorMessage != nil },
                set: { if !$0 { viewModel.errorMessage = nil } }
            )) {
                Button("OK", role: .cancel) { viewModel.errorMessage = nil }
            } message: {
                Text(viewModel.errorMessage ?? "")
            }
            .sheet(isPresented: $isShowingSettings) {
                SettingsView()
                    .environmentObject(viewModel)
            }
            .sheet(isPresented: $isShowingTagManager) {
                TagManagementView()
                    .environmentObject(viewModel)
            }
            .alert("連絡先からインポート", isPresented: $isShowingImportConfirm) {
                Button("インポート") { viewModel.importFromContacts() }
                Button("キャンセル", role: .cancel) {}
            } message: {
                Text("iPhoneの連絡先をすべて名刺としてインポートします。")
            }
            .alert("インポート完了", isPresented: Binding(
                get: { viewModel.importResultMessage != nil },
                set: { if !$0 { viewModel.importResultMessage = nil } }
            )) {
                Button("OK", role: .cancel) { viewModel.importResultMessage = nil }
            } message: {
                Text(viewModel.importResultMessage ?? "")
            }
            .onAppear(perform: viewModel.fetchCards)
        }
        .environmentObject(viewModel)
    }

    // MARK: - サブビュー

    private var cardList: some View {
        let showIndex = !viewModel.isSearchActive &&
            (viewModel.sortKey == .name || viewModel.sortKey == .company)
        return ScrollViewReader { proxy in
            List {
                if viewModel.isSearchActive {
                    // 検索中はフラット表示
                    ForEach(viewModel.filteredCards) { card in
                        NavigationLink {
                            CardDetailView(card: card)
                        } label: {
                            CardRowView(card: card)
                        }
                        .swipeActions(edge: .leading) {
                            Button {
                                viewModel.toggleFavorite(card)
                            } label: {
                                Label(
                                    card.isFavorite ? "解除" : "お気に入り",
                                    systemImage: card.isFavorite ? "star.slash" : "star.fill"
                                )
                            }
                            .tint(.yellow)
                        }
                    }
                    .onDelete { offsets in
                        viewModel.deleteCards(offsets.map { viewModel.filteredCards[$0] })
                    }
                } else {
                    // ソート順に応じたセクション表示
                    ForEach(viewModel.groupedCards) { section in
                        Section {
                            ForEach(section.cards) { card in
                                NavigationLink {
                                    CardDetailView(card: card)
                                } label: {
                                    CardRowView(card: card)
                                }
                                .swipeActions(edge: .leading) {
                                    Button {
                                        viewModel.toggleFavorite(card)
                                    } label: {
                                        Label(
                                            card.isFavorite ? "解除" : "お気に入り",
                                            systemImage: card.isFavorite ? "star.slash" : "star.fill"
                                        )
                                    }
                                    .tint(.yellow)
                                }
                                .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
                                .alignmentGuide(.listRowSeparatorLeading) { d in
                                    d[.leading]
                                }
                                .alignmentGuide(.listRowSeparatorTrailing) { d in
                                    d[.trailing]
                                }
                            }
                            .onDelete { offsets in
                                viewModel.deleteCards(offsets.map { section.cards[$0] })
                            }
                        } header: {
                            Text(section.title)
                                .font(.subheadline)
                                .fontWeight(.bold)
                                .foregroundStyle(.primary)
                                .textCase(nil)
                        }
                        .id(section.id)
                    }
                }
            }
            .listStyle(.plain)
            .scrollIndicators(showIndex ? .hidden : .automatic)
            .scrollDismissesKeyboard(.immediately)
            .overlay(alignment: .trailing) {
                if showIndex {
                    SectionIndexView(
                        sections: viewModel.groupedCards,
                        proxy: proxy
                    )
                    .padding(.trailing, 0)
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "rectangle.portrait.on.rectangle.portrait.slash")
                .font(.system(size: 60))
                .foregroundColor(.secondary)
            Text("名刺がありません")
                .font(.title3)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

}

// MARK: - 一覧行

private struct CardRowView: View {

    let card: BusinessCard

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(Color.accentColor.opacity(0.12))
                    .frame(width: 44, height: 44)
                Text(card.initials)
                    .font(.subheadline.bold())
                    .foregroundStyle(Color.accentColor)
            }

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    Text(card.fullName.isEmpty ? "（名前なし）" : card.fullName)
                        .font(.headline)
                        .lineLimit(1)
                    if card.isFavorite {
                        Image(systemName: "star.fill")
                            .font(.caption2)
                            .foregroundStyle(.yellow)
                    }
                }
                if let company = card.company, !company.isEmpty {
                    Text(company)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                let dept = card.department ?? ""
                let ttl = card.title ?? ""
                let deptTitle = [dept, ttl].filter { !$0.isEmpty }.joined(separator: " ")
                if !deptTitle.isEmpty {
                    Text(deptTitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .padding(.vertical, 4)
    }

}

// MARK: - セクションインデックス

private struct SectionIndexView: View {

    let sections: [CardSection]
    let proxy: ScrollViewProxy

    @State private var feedbackGenerator = UISelectionFeedbackGenerator()
    @State private var lastChar: String?

    // あかさたなはまやらわ → A-Z → # （かなをアルファベットより上に配置）
    private static let allItems: [(char: String, sectionId: String)] = {
        var items: [(String, String)] = []
        for (c, s) in [("あ","あ行"),("か","か行"),("さ","さ行"),("た","た行"),("な","な行"),
                       ("は","は行"),("ま","ま行"),("や","や行"),("ら","ら行"),("わ","わ行")] {
            items.append((c, s))
        }
        for c in "ABCDEFGHIJKLMNOPQRSTUVWXYZ" { items.append((String(c), String(c))) }
        items.append(("#", "その他"))
        return items
    }()

    private var existingIds: Set<String> { Set(sections.map(\.id)) }

    /// 存在するセクションのみに絞ったアイテムリスト（純正と同様に空セクションは非表示）
    private var filteredItems: [(char: String, sectionId: String)] {
        Self.allItems.filter { existingIds.contains($0.sectionId) }
    }

    // 対象セクションが存在しない場合は前後で最近傍を探す
    private func nearestId(for sectionId: String) -> String? {
        if existingIds.contains(sectionId) { return sectionId }
        guard let idx = Self.allItems.firstIndex(where: { $0.sectionId == sectionId }) else { return nil }
        for offset in 1...Self.allItems.count {
            if idx - offset >= 0, existingIds.contains(Self.allItems[idx - offset].sectionId) {
                return Self.allItems[idx - offset].sectionId
            }
            if idx + offset < Self.allItems.count, existingIds.contains(Self.allItems[idx + offset].sectionId) {
                return Self.allItems[idx + offset].sectionId
            }
        }
        return nil
    }

    private static let itemHeight: CGFloat = 14

    /// 利用可能な高さに収まるよう等間隔に間引いた表示用アイテムを返す
    private static func thinned(_ items: [(char: String, sectionId: String)], for height: CGFloat) -> [(char: String, sectionId: String)] {
        let maxCount = max(2, Int(height / itemHeight))
        if items.count <= maxCount { return items }
        var result: [(String, String)] = [items.first!]
        let step = Double(items.count - 1) / Double(maxCount - 1)
        for i in 1..<(maxCount - 1) {
            let idx = Int((Double(i) * step).rounded())
            result.append(items[idx])
        }
        result.append(items.last!)
        return result
    }

    var body: some View {
        GeometryReader { geo in
            let availableHeight = geo.size.height - 16 // 上下パディング分を差し引く
            let visible = Self.thinned(filteredItems, for: availableHeight)
            let itemH = visible.isEmpty ? 0 : min(availableHeight / CGFloat(visible.count), 20)
            VStack(spacing: 0) {
                ForEach(visible, id: \.char) { item in
                    Text(item.char)
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(Color.primary.opacity(0.5))
                        .frame(width: 14, height: itemH)
                }
            }
            .frame(maxHeight: .infinity, alignment: .center)
            .padding(.leading, 4)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        feedbackGenerator.prepare()
                        let paddingTop = (geo.size.height - itemH * CGFloat(visible.count)) / 2
                        let adjustedY = value.location.y - paddingTop
                        let idx = max(0, min(Int(adjustedY / itemH), visible.count - 1))
                        let item = visible[idx]
                        if lastChar != item.char {
                            lastChar = item.char
                            feedbackGenerator.selectionChanged()
                            if let id = nearestId(for: item.sectionId) {
                                proxy.scrollTo(id, anchor: .top)
                            }
                        }
                    }
                    .onEnded { _ in
                        lastChar = nil
                    }
            )
        }
        .frame(width: 20)
        .padding(.vertical, 8)
    }
}

// MARK: - 共有シート

struct ShareSheet: UIViewControllerRepresentable {
    let activityItems: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

struct ExportItem: Identifiable {
    let id = UUID()
    let url: URL
}

extension UIImage: @retroactive Identifiable {
    public var id: ObjectIdentifier { ObjectIdentifier(self) }
}
