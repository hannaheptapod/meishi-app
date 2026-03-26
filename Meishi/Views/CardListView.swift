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
    @State private var sectionIndexChar: String? = nil

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
                // 左上: 3点リーダーメニュー
                ToolbarItem(placement: .topBarLeading) {
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
                        Button { isShowingSettings = true } label: {
                            Label("設定", systemImage: "gearshape")
                        }
                    } label: {
                        Label("メニュー", systemImage: "ellipsis")
                    }
                }

                // 左: 並び替えボタン（将来フィルタも追加予定）
                ToolbarItem(placement: .bottomBar) {
                    Menu {
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
                    } label: {
                        Label("並び替え", systemImage: "arrow.up.arrow.down")
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
            .confirmationDialog(
                "連絡先からインポート",
                isPresented: $isShowingImportConfirm,
                titleVisibility: .visible
            ) {
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
                            }
                            .onDelete { offsets in
                                viewModel.deleteCards(offsets.map { section.cards[$0] })
                            }
                        } header: {
                            Text(section.title)
                                .font(.footnote)
                                .fontWeight(.semibold)
                                .foregroundStyle(.secondary)
                                .textCase(nil)
                        }
                        .id(section.id)
                    }
                }
            }
            .listStyle(.plain)
            .scrollDismissesKeyboard(.immediately)
            .overlay {
                if let char = sectionIndexChar {
                    Text(char)
                        .font(.system(size: 36, weight: .bold))
                        .frame(width: 60, height: 60)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
                        .allowsHitTesting(false)
                }
            }
            .overlay(alignment: .trailing) {
                if showIndex {
                    SectionIndexView(
                        sections: viewModel.groupedCards,
                        dragChar: $sectionIndexChar
                    ) { sectionId in
                        proxy.scrollTo(sectionId, anchor: .top)
                    }
                    .padding(.trailing, 4)
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
                Text(card.fullName.isEmpty ? "（名前なし）" : card.fullName)
                    .font(.headline)
                    .lineLimit(1)
                if let company = card.company, !company.isEmpty {
                    Text(company)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                let phones = card.phoneList
                let email  = card.email ?? ""
                if !phones.isEmpty || !email.isEmpty {
                    Text(phones.first ?? email)
                        .lineLimit(1)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 4)
    }

}

// MARK: - セクションインデックス

private struct SectionIndexView: View {

    let sections: [CardSection]
    @Binding var dragChar: String?
    let onSelect: (String) -> Void

    // A-Z → あかさたなはまやらわ → # （純正に合わせた順）
    private static let allItems: [(char: String, sectionId: String)] = {
        var items: [(String, String)] = []
        for c in "ABCDEFGHIJKLMNOPQRSTUVWXYZ" { items.append((String(c), String(c))) }
        for (c, s) in [("あ","あ行"),("か","か行"),("さ","さ行"),("た","た行"),("な","な行"),
                       ("は","は行"),("ま","ま行"),("や","や行"),("ら","ら行"),("わ","わ行")] {
            items.append((c, s))
        }
        items.append(("#", "その他"))
        return items
    }()

    private var existingIds: Set<String> { Set(sections.map(\.id)) }

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

    var body: some View {
        GeometryReader { geo in
            let items = Self.allItems
            let itemH = geo.size.height / CGFloat(items.count)
            VStack(spacing: 0) {
                ForEach(items, id: \.char) { item in
                    Text(item.char)
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(
                            existingIds.contains(item.sectionId)
                                ? Color.accentColor
                                : Color.secondary.opacity(0.3)
                        )
                        .frame(width: 16, height: itemH)
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let idx = max(0, min(Int(value.location.y / itemH), items.count - 1))
                        let item = items[idx]
                        if dragChar != item.char {
                            dragChar = item.char
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                            if let id = nearestId(for: item.sectionId) {
                                onSelect(id)
                            }
                        }
                    }
                    .onEnded { _ in
                        withAnimation(.easeOut(duration: 0.15)) { dragChar = nil }
                    }
            )
        }
        .frame(width: 16)
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
