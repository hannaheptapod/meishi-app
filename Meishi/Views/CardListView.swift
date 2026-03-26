import SwiftUI
import UIKit

// 名刺一覧画面
struct CardListView: View {

    @StateObject private var viewModel = CardListViewModel()
    @FocusState private var isSearchFocused: Bool
    @State private var isShowingForm = false
    @State private var isShowingCamera = false
    @State private var capturedImage: UIImage? = nil
    @State private var isShowingSettings = false
    @State private var isShowingImportConfirm = false

    var body: some View {
        NavigationStack {
            Group {

                if viewModel.cards.isEmpty {
                    emptyState
                } else {
                    cardList
                }
            }
            .navigationBarHidden(true)
            .safeAreaInset(edge: .bottom) {
                bottomBar
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

    // MARK: - 下部バー

    @ViewBuilder
    private var bottomBar: some View {
        if #available(iOS 26.0, *) {
            // Liquid Glass
            GlassEffectContainer(spacing: 8) {
                HStack(spacing: 8) {
                    ellipsisMenu
                        .glassEffect(in: .capsule)

                    searchField
                        .glassEffect(in: .capsule)

                    addMenu
                        .glassEffect(in: .capsule)
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
        } else {
            HStack(spacing: 8) {
                ellipsisMenu
                searchField
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(.quaternary, in: Capsule())
                addMenu
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(.bar)
        }
    }

    private var ellipsisMenu: some View {
        Menu {
            Menu {
                ForEach(CardSortKey.allCases) { key in
                    Button { viewModel.toggleSort(key: key) } label: {
                        let isSelected = viewModel.sortKey == key
                        if isSelected {
                            let direction = key.directionLabel(ascending: viewModel.sortAscending)
                            Label("\(key.rawValue)（\(direction)）", systemImage: "checkmark")
                        } else {
                            Label(key.rawValue, systemImage: key.systemImage)
                        }
                    }
                    .menuActionDismissBehavior(.disabled)
                }
            } label: {
                Label("並び替え", systemImage: "arrow.up.arrow.down")
            }
            Divider()
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
            Image(systemName: viewModel.duplicatePairs.isEmpty ? "ellipsis" : "ellipsis")
                .symbolRenderingMode(viewModel.duplicatePairs.isEmpty ? .monochrome : .palette)
                .foregroundStyle(viewModel.duplicatePairs.isEmpty ? Color.primary : Color.red)
                .font(.system(size: 20, weight: .medium))
        .frame(width: 44, height: 44)
        }
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(.secondary)
            TextField("検索", text: $viewModel.searchText)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .focused($isSearchFocused)
            if !viewModel.searchText.isEmpty {
                Button { viewModel.searchText = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 44)
    }

    @ViewBuilder
    private var addMenu: some View {
        if !viewModel.searchText.isEmpty || isSearchFocused {
            // 検索中は × ボタンで検索を閉じる（テキストクリア＋キーボード閉じる）
            Button {
                viewModel.searchText = ""
                isSearchFocused = false
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 20, weight: .medium))
                    .frame(width: 44, height: 44)
            }
        } else {
            Button { isShowingCamera = true } label: {
                Image(systemName: "plus")
                    .font(.system(size: 20, weight: .medium))
                    .frame(width: 44, height: 44)
            }
        }
    }

    // MARK: - サブビュー

    private var cardList: some View {
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
                }
            }
        }
        .listStyle(.plain)
        .scrollDismissesKeyboard(.immediately)
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "rectangle.portrait.on.rectangle.portrait.slash")
                .font(.system(size: 60))
                .foregroundColor(.secondary)
            Text("名刺がありません")
                .font(.title3)
                .foregroundColor(.secondary)
            HStack(spacing: 12) {
                Button { isShowingCamera = true } label: {
                    Label("カメラで撮影", systemImage: "camera")
                }
                .buttonStyle(.borderedProminent)
                Button { isShowingForm = true } label: {
                    Label("手動で追加", systemImage: "plus")
                }
                .buttonStyle(.bordered)
            }
        }
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
