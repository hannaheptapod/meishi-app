import SwiftUI
import CoreData

/// 対話型 AI 検索画面
/// .searchable + List で標準UIに統一
struct AISearchChatView: View {

    @EnvironmentObject private var listViewModel: CardListViewModel
    var initialQuery: String = ""
    @State private var inputText = ""
    @State private var messages: [AISearchService.ChatMessage] = []
    @State private var isSearching = false
    @State private var didSendInitialQuery = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            messageList
                .navigationTitle("AI検索")
                .navigationBarTitleDisplayMode(.inline)
                .searchable(text: $inputText, placement: .toolbar, prompt: "質問を入力")
                .onSubmit(of: .search) {
                    sendMessage()
                }
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("閉じる") { dismiss() }
                    }
                    ToolbarItem(placement: .primaryAction) {
                        if !messages.isEmpty {
                            Button("クリア") { messages.removeAll() }
                        }
                    }
                }
                .onAppear {
                    // スクリーンショット撮影モード：モック会話を注入
                    if ScreenshotMode.isActive,
                       ScreenshotMode.startScreen == "AIChat",
                       messages.isEmpty {
                        messages = ScreenshotMockSupport.mockChatMessages(cards: listViewModel.cards)
                        return
                    }
                    if !initialQuery.isEmpty && !didSendInitialQuery {
                        didSendInitialQuery = true
                        inputText = initialQuery
                        sendMessage()
                    }
                }
        }
    }

    // MARK: - メッセージ一覧

    private var messageList: some View {
        ScrollViewReader { proxy in
            List {
                if messages.isEmpty {
                    welcomeSection
                } else {
                    ForEach(messages) { message in
                        Section {
                            switch message.role {
                            case .user:
                                userRow(message)
                            case .assistant:
                                assistantRows(message)
                            }
                        }
                        .id(message.id)
                    }

                    if isSearching {
                        Section {
                            HStack(spacing: 10) {
                                ProgressView()
                                Text("検索中...")
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .id("loading")
                    }
                }
            }
            .listStyle(.insetGrouped)
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: messages.count) { _, _ in
                withAnimation {
                    if let lastID = messages.last?.id {
                        proxy.scrollTo(lastID, anchor: .bottom)
                    }
                }
            }
        }
    }

    // MARK: - ウェルカム

    private var welcomeSection: some View {
        let suggestions = buildSuggestions()
        return Group {
            if !suggestions.isEmpty {
                Section {
                    ForEach(suggestions, id: \.self) { query in
                        Button {
                            inputText = query
                            sendMessage()
                        } label: {
                            Text(query)
                                .foregroundStyle(.primary)
                        }
                    }
                } header: {
                    Text("おすすめ")
                } footer: {
                    Text("自然言語で名刺を検索できます。キーワード・時間・場所などを自由に組み合わせてください。")
                }
            } else {
                Section {
                    Text("検索バーに質問を入力してください")
                        .foregroundStyle(.secondary)
                } footer: {
                    Text("自然言語で名刺を検索できます。キーワード・時間・場所などを自由に組み合わせてください。")
                }
            }
        }
    }

    /// インサイト結果から検索候補を動的生成（最大4件）
    private func buildSuggestions() -> [String] {
        let insights = InsightsService.shared.generateInsights()
        var suggestions: [String] = []

        // 上位の会社名から候補
        if let top = insights.companyGroups.first, top.count >= 2 {
            suggestions.append("\(top.label)の人")
        }

        // 上位のエリアから候補
        if let top = insights.areaGroups.first {
            suggestions.append("\(top.label)の人")
        }

        // 上位の職種カテゴリから候補（「未分類」「その他」は除く）
        if let top = insights.roleCategoryGroups.first(where: { $0.label != "未分類" && $0.label != "その他" }) {
            suggestions.append("\(top.label)関係の人")
        }

        // 最近追加があれば時間系候補
        if let latest = insights.monthlyTrend.first, latest.count >= 1 {
            suggestions.append("最近追加した名刺")
        }

        return Array(suggestions.prefix(4))
    }

    // MARK: - ユーザー行

    private func userRow(_ message: AISearchService.ChatMessage) -> some View {
        HStack {
            Spacer()
            Text(message.text)
                .font(.body)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - アシスタント行

    @ViewBuilder
    private func assistantRows(_ message: AISearchService.ChatMessage) -> some View {
        Text(message.text)
            .font(.body)

        if !message.matchedCardIDs.isEmpty {
            let matchedCards = listViewModel.cards.filter { card in
                guard let id = card.id else { return false }
                return message.matchedCardIDs.contains(id)
            }

            ForEach(matchedCards.prefix(10)) { card in
                NavigationLink {
                    CardDetailView(card: card)
                } label: {
                    CardRowView(card: card)
                }
            }

            if message.matchedCardIDs.count > 10 {
                Text("他 \(message.matchedCardIDs.count - 10) 件")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - メッセージ送信

    private func sendMessage() {
        let query = inputText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty, !isSearching else { return }

        let userMessage = AISearchService.ChatMessage(
            role: .user,
            text: query,
            matchedCardIDs: []
        )
        messages.append(userMessage)
        inputText = ""
        isSearching = true

        Task {
            let response = await AISearchService.shared.search(
                query: query,
                cards: listViewModel.cards,
                conversationHistory: messages
            )
            messages.append(response)
            isSearching = false
        }
    }
}
