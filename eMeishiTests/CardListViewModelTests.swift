import Testing
import CoreData
@testable import eMeishi

// Swift Testing の Tag と CoreData の Tag エンティティが衝突するため別名を用意
private typealias CardTag = eMeishi.Tag

private enum IntentionalSaveError: Error {
    case failed
}

/// CoreDataモデルとストアは実物を使い、保存処理だけを失敗させるテストダブル。
private nonisolated final class FailingSaveContext: NSManagedObjectContext, @unchecked Sendable {
    override func save() throws {
        throw IntentionalSaveError.failed
    }
}

// MARK: - テスト用ヘルパー（CardListViewModelTests 専用）
// makeTestContext() は TestHelpers.swift の共有版を使用。
// makeCard はお気に入り・登録日時など CardListViewModel 固有のパラメータを持つため個別定義。

/// テスト用 BusinessCard を生成する
@MainActor
private func makeCard(
    context: NSManagedObjectContext,
    lastName: String? = nil,
    lastNameReading: String? = nil,
    firstName: String? = nil,
    company: String? = nil,
    title: String? = nil,
    email: String? = nil,
    phone: String? = nil,
    address: String? = nil,
    isFavorite: Bool = false,
    createdAt: Date = Date()
) -> BusinessCard {
    let card = BusinessCard(context: context)
    card.id               = UUID()
    card.lastName         = lastName
    card.lastNameReading  = lastNameReading
    card.firstName        = firstName
    card.company          = company
    card.title            = title
    card.email            = email
    card.phone            = phone
    card.address          = address
    card.isFavorite       = isFavorite
    card.createdAt        = createdAt
    card.updatedAt        = createdAt
    return card
}

/// テスト用 Tag を生成する
@MainActor
private func makeTag(context: NSManagedObjectContext, name: String, colorHex: String = "#FF0000") -> CardTag {
    let tag = CardTag(context: context)
    tag.id = UUID()
    tag.name = name
    tag.colorHex = colorHex
    tag.createdAt = Date()
    return tag
}

// MARK: - 検索フィルタ

@MainActor
struct CardListViewModelSearchTests {
    @Test func submittedQueryBecomesRecentSearchWithoutStartingSemanticSearch() throws {
        let context = makeTestContext()
        _ = makeCard(context: context, lastName: "検索対象", company: "サンプル会社")
        try context.save()

        let vm = CardListViewModel(context: context)
        vm.clearRecentSearches()
        defer { vm.clearRecentSearches() }
        vm.searchText = "サンプル会社"

        vm.submitUnifiedSearch()

        #expect(vm.recentSearches.first == "サンプル会社")
        #expect(vm.isSemanticSearchInProgress == false)
    }

    @Test func applyingSearchSuggestionUsesUnifiedSearchField() {
        let vm = CardListViewModel(context: makeTestContext())

        vm.applySearchSuggestion("今月追加した名刺")

        #expect(vm.searchText == "今月追加した名刺")
    }


    @Test func searchByFullName() async throws {
        let context = makeTestContext()
        _ = makeCard(context: context, lastName: "山田", firstName: "太郎")
        _ = makeCard(context: context, lastName: "佐藤", firstName: "花子")
        try context.save()

        let vm = CardListViewModel(context: context)
        vm.searchText = "山田"
        await vm.waitForPendingListUpdate()
        #expect(vm.filteredCardItems.count == 1)
        #expect(vm.filteredCardItems.first?.row.displayName == "山田")
    }

    @Test func searchByCompany() async throws {
        let context = makeTestContext()
        _ = makeCard(context: context, lastName: "山田", company: "アルファテック")
        _ = makeCard(context: context, lastName: "佐藤", company: "ベータシステムズ")
        try context.save()

        let vm = CardListViewModel(context: context)
        vm.searchText = "ベータ"
        await vm.waitForPendingListUpdate()
        #expect(vm.filteredCardItems.count == 1)
        #expect(vm.filteredCardItems.first?.row.company == "ベータシステムズ")
    }

    @Test func searchByEmail() async throws {
        let context = makeTestContext()
        _ = makeCard(context: context, lastName: "山田", email: "taro@example.com")
        _ = makeCard(context: context, lastName: "佐藤", email: "hanako@test.jp")
        try context.save()

        let vm = CardListViewModel(context: context)
        vm.searchText = "example.com"
        await vm.waitForPendingListUpdate()
        #expect(vm.filteredCardItems.count == 1)
    }

    @Test func searchIsCaseAndDiacriticInsensitive() async throws {
        let context = makeTestContext()
        _ = makeCard(context: context, lastName: "YAMADA", company: "Café Company")
        try context.save()

        let vm = CardListViewModel(context: context)
        vm.searchText = "cafe"
        await vm.waitForPendingListUpdate()
        #expect(vm.filteredCardItems.count == 1)
    }

    @Test func emptySearchReturnsAllCards() async throws {
        let context = makeTestContext()
        _ = makeCard(context: context, lastName: "山田")
        _ = makeCard(context: context, lastName: "佐藤")
        try context.save()

        let vm = CardListViewModel(context: context)
        vm.searchText = ""
        await vm.waitForPendingListUpdate()
        #expect(vm.filteredCardItems.count == 2)
    }

    @Test func whitespaceOnlySearchReturnsAllCards() async throws {
        let context = makeTestContext()
        _ = makeCard(context: context, lastName: "山田")
        _ = makeCard(context: context, lastName: "佐藤")
        try context.save()

        let vm = CardListViewModel(context: context)
        vm.searchText = "   "
        await vm.waitForPendingListUpdate()
        #expect(vm.filteredCardItems.count == 2)
        #expect(vm.isSearchActive == false)
    }

    @Test func isSearchActiveReflectsTrimmedText() throws {
        let context = makeTestContext()
        let vm = CardListViewModel(context: context)
        vm.searchText = "山田"
        #expect(vm.isSearchActive == true)
        vm.searchText = ""
        #expect(vm.isSearchActive == false)
    }

    @Test func semanticResultsJoinLexicalResultsInTheSameList() async throws {
        let context = makeTestContext()
        let lexical = makeCard(context: context, lastName: "IT関係", company: "通常一致")
        let semantic = makeCard(context: context, lastName: "佐藤", company: "テックラボ")
        _ = makeCard(context: context, lastName: "鈴木", company: "食品")
        try context.save()

        let vm = CardListViewModel(context: context)
        vm.searchText = "IT関係"
        vm.applySemanticSearchResults([semantic.id!], for: "IT関係")
        await vm.waitForPendingListUpdate()

        #expect(Set(vm.filteredCardItems.map(\.id)) == Set([
            lexical.objectID.uriRepresentation(),
            semantic.objectID.uriRepresentation(),
        ]))
    }

    @Test func staleSemanticResultsAreIgnoredAfterQueryChanges() async throws {
        let context = makeTestContext()
        let semantic = makeCard(context: context, lastName: "佐藤", company: "テックラボ")
        try context.save()

        let vm = CardListViewModel(context: context)
        vm.searchText = "IT関係"
        vm.searchText = "食品関係"
        vm.applySemanticSearchResults([semantic.id!], for: "IT関係")
        await vm.waitForPendingListUpdate()

        #expect(vm.filteredCardItems.isEmpty)
    }

    @Test func semanticResultsStillRespectFavoriteFilter() async throws {
        let context = makeTestContext()
        let favorite = makeCard(context: context, lastName: "山田", company: "テック", isFavorite: true)
        let regular = makeCard(context: context, lastName: "佐藤", company: "テック", isFavorite: false)
        try context.save()

        let vm = CardListViewModel(context: context)
        vm.searchText = "IT関係"
        vm.setFavoritesFilter(true)
        vm.applySemanticSearchResults([favorite.id!, regular.id!], for: "IT関係")
        await vm.waitForPendingListUpdate()

        #expect(vm.filteredCardItems.map(\.id) == [favorite.objectID.uriRepresentation()])
    }

    @Test func rapidTypingPublishesOnlyTheLatestGeneration() async throws {
        let context = makeTestContext()
        _ = makeCard(context: context, lastName: "Alpha")
        _ = makeCard(context: context, lastName: "Beta")
        try context.save()

        let vm = CardListViewModel(
            context: context,
            searchDebounceDuration: .milliseconds(20)
        )
        vm.searchText = "Alpha"
        vm.searchText = "Beta"
        await vm.waitForPendingListUpdate()

        #expect(vm.filteredCardItems.map(\.row.displayName) == ["Beta"])
    }

    @Test func searchCriteriaAndResultsPublishAsOneSnapshot() async throws {
        let context = makeTestContext()
        _ = makeCard(context: context, lastName: "Fixture-Alpha")
        _ = makeCard(context: context, lastName: "Fixture-Beta")
        try context.save()

        let vm = CardListViewModel(
            context: context,
            searchDebounceDuration: .milliseconds(30)
        )
        await vm.waitForPendingListUpdate()
        #expect(vm.isDisplayedSearchActive == false)
        #expect(vm.filteredCardItems.count == 2)

        vm.searchText = "Fixture-Alpha"
        // debounce中は条件だけを先行表示せず、直前の整合した一覧を維持する。
        #expect(vm.isDisplayedSearchActive == false)
        #expect(vm.filteredCardItems.count == 2)
        await vm.waitForPendingListUpdate()
        #expect(vm.isDisplayedSearchActive)
        #expect(vm.filteredCardItems.map(\.row.displayName) == ["Fixture-Alpha"])

        vm.searchText = ""
        // 解除直後も、結果と表示方式が同時に切り替わるまで検索表示を維持する。
        #expect(vm.isDisplayedSearchActive)
        #expect(vm.filteredCardItems.map(\.row.displayName) == ["Fixture-Alpha"])
        await vm.waitForPendingListUpdate()
        #expect(vm.isDisplayedSearchActive == false)
        #expect(vm.filteredCardItems.count == 2)
    }
}

// MARK: - お気に入り・タグフィルタ

@MainActor
struct CardListViewModelFilterTests {

    @Test func favoritesOnlyFilter() async throws {
        let context = makeTestContext()
        _ = makeCard(context: context, lastName: "山田", isFavorite: true)
        _ = makeCard(context: context, lastName: "佐藤", isFavorite: false)
        _ = makeCard(context: context, lastName: "鈴木", isFavorite: true)
        try context.save()

        let vm = CardListViewModel(context: context)
        vm.toggleFavoritesFilter()
        await vm.waitForPendingListUpdate()
        #expect(vm.showFavoritesOnly == true)
        #expect(vm.filteredCardItems.count == 2)
        #expect(vm.filteredCardItems.allSatisfy { $0.row.isFavorite })
    }

    @Test func tagFilterRequiresAllSelectedTags() async throws {
        let context = makeTestContext()
        let tagA = makeTag(context: context, name: "重要")
        let tagB = makeTag(context: context, name: "営業")

        let card1 = makeCard(context: context, lastName: "山田")
        card1.addToTags(tagA)

        let card2 = makeCard(context: context, lastName: "佐藤")
        card2.addToTags(tagA)
        card2.addToTags(tagB)

        let card3 = makeCard(context: context, lastName: "鈴木")
        card3.addToTags(tagB)

        try context.save()

        let vm = CardListViewModel(context: context)
        vm.toggleTagFilter(tagA)
        vm.toggleTagFilter(tagB)
        await vm.waitForPendingListUpdate()
        // 両方のタグを持つカードのみ
        #expect(vm.filteredCardItems.count == 1)
        #expect(vm.filteredCardItems.first?.row.displayName == "佐藤")
    }

    @Test func toggleTagFilterRemovesOnSecondCall() throws {
        let context = makeTestContext()
        let tag = makeTag(context: context, name: "重要")
        try context.save()

        let vm = CardListViewModel(context: context)
        #expect(vm.selectedTagIDs.isEmpty)

        vm.toggleTagFilter(tag)
        #expect(vm.selectedTagIDs.contains(tag.id!))

        vm.toggleTagFilter(tag)
        #expect(vm.selectedTagIDs.isEmpty)
    }

    @Test func favoriteAndTagFiltersCombine() async throws {
        let context = makeTestContext()
        let tag = makeTag(context: context, name: "重要")

        let card1 = makeCard(context: context, lastName: "山田", isFavorite: true)
        card1.addToTags(tag)

        let card2 = makeCard(context: context, lastName: "佐藤", isFavorite: false)
        card2.addToTags(tag)

        _ = makeCard(context: context, lastName: "鈴木", isFavorite: true)
        // タグなし

        try context.save()

        let vm = CardListViewModel(context: context)
        vm.toggleFavoritesFilter()
        vm.toggleTagFilter(tag)
        await vm.waitForPendingListUpdate()
        // お気に入り AND タグ「重要」
        #expect(vm.filteredCardItems.count == 1)
        #expect(vm.filteredCardItems.first?.row.displayName == "山田")
    }

    @Test func isFilterActiveReflectsState() throws {
        let context = makeTestContext()
        let tag = makeTag(context: context, name: "T")
        try context.save()

        let vm = CardListViewModel(context: context)
        #expect(vm.isFilterActive == false)
        vm.toggleFavoritesFilter()
        #expect(vm.isFilterActive == true)
        vm.toggleFavoritesFilter()
        #expect(vm.isFilterActive == false)
        vm.toggleTagFilter(tag)
        #expect(vm.isFilterActive == true)
    }

    @Test func externalCompanyFilterCombinesWithFavorites() async throws {
        let context = makeTestContext()
        _ = makeCard(context: context, lastName: "山田", company: "アルファ", isFavorite: true)
        _ = makeCard(context: context, lastName: "佐藤", company: "アルファ", isFavorite: false)
        _ = makeCard(context: context, lastName: "鈴木", company: "ベータ", isFavorite: true)
        try context.save()

        let vm = CardListViewModel(context: context)
        vm.externalFilter = .company("アルファ")
        vm.toggleFavoritesFilter()
        await vm.waitForPendingListUpdate()

        #expect(vm.filteredCardItems.map(\.row.displayName) == ["山田"])
        #expect(vm.isFilterActive)

        vm.clearExternalFilter()
        await vm.waitForPendingListUpdate()
        #expect(vm.filteredCardItems.count == 2)
    }

    @Test func clearAllFiltersRestoresEveryCard() async throws {
        let context = makeTestContext()
        let tag = makeTag(context: context, name: "重要")
        let matching = makeCard(context: context, lastName: "山田", company: "アルファ", isFavorite: true)
        matching.addToTags(tag)
        _ = makeCard(context: context, lastName: "佐藤", company: "ベータ", isFavorite: false)
        try context.save()

        let vm = CardListViewModel(context: context)
        vm.setFavoritesFilter(true)
        vm.setTagFilter(tag, enabled: true)
        vm.externalFilter = .company("アルファ")
        await vm.waitForPendingListUpdate()
        #expect(vm.filteredCardItems.count == 1)

        vm.clearAllFilters()
        await vm.waitForPendingListUpdate()

        #expect(vm.showFavoritesOnly == false)
        #expect(vm.selectedTagIDs.isEmpty)
        #expect(vm.externalFilter == nil)
        #expect(vm.isFilterActive == false)
        #expect(vm.filteredCardItems.count == 2)
    }

    @Test func externalRoleAndAreaFiltersMatchInsightsDimensions() async throws {
        let context = makeTestContext()
        _ = makeCard(
            context: context,
            lastName: "山田",
            title: "エンジニア",
            address: "東京都渋谷区道玄坂1-1"
        )
        _ = makeCard(context: context, lastName: "佐藤", title: "営業", address: "大阪府大阪市北区1-1")
        try context.save()

        let vm = CardListViewModel(context: context)
        vm.externalFilter = .role("エンジニア・技術")
        await vm.waitForPendingListUpdate()
        #expect(vm.filteredCardItems.map(\.row.displayName) == ["山田"])

        vm.externalFilter = .area("東京都渋谷区")
        await vm.waitForPendingListUpdate()
        #expect(vm.filteredCardItems.map(\.row.displayName) == ["山田"])
    }

    @Test func organizationFiltersMatchActionDashboard() async throws {
        let context = makeTestContext()
        let tag = makeTag(context: context, name: "整理済み")
        let oldDate = try #require(Calendar.current.date(byAdding: .day, value: -60, to: Date()))

        let organized = makeCard(
            context: context,
            lastName: "整理済",
            email: "known@example.com",
            phone: "03-1234-5678",
            isFavorite: true,
            createdAt: oldDate
        )
        organized.addToTags(tag)
        _ = makeCard(context: context, lastName: "未整理", createdAt: Date())
        try context.save()

        let vm = CardListViewModel(context: context)

        vm.externalFilter = .untagged
        await vm.waitForPendingListUpdate()
        #expect(vm.filteredCardItems.map(\.row.displayName) == ["未整理"])

        vm.externalFilter = .missingContact
        await vm.waitForPendingListUpdate()
        #expect(vm.filteredCardItems.map(\.row.displayName) == ["未整理"])

        vm.externalFilter = .favorite
        await vm.waitForPendingListUpdate()
        #expect(vm.filteredCardItems.map(\.row.displayName) == ["整理済"])

        vm.externalFilter = .recent(days: 30)
        await vm.waitForPendingListUpdate()
        #expect(vm.filteredCardItems.map(\.row.displayName) == ["未整理"])
    }
}

// MARK: - ソート

@MainActor
struct CardListViewModelSortTests {

    @Test func toggleSortSameKeyReversesDirection() throws {
        let context = makeTestContext()
        _ = makeCard(context: context, lastName: "山田")
        try context.save()

        let vm = CardListViewModel(context: context)
        vm.sortKey = .createdAt
        vm.sortAscending = false

        vm.toggleSort(key: .createdAt)
        #expect(vm.sortAscending == true)

        vm.toggleSort(key: .createdAt)
        #expect(vm.sortAscending == false)
    }

    @Test func toggleSortNewKeyUsesSensibleDefault() throws {
        let context = makeTestContext()
        _ = makeCard(context: context, lastName: "山田")
        try context.save()

        let vm = CardListViewModel(context: context)
        // SettingsStore.shared(UserDefaults)は並列テスト間で共有されるため、
        // 初期sortKeyを.name以外に固定して「新しいキーへの切替」分岐を確実に通す
        vm.sortKey = .createdAt
        vm.sortAscending = false

        // 名前に切り替えたら昇順がデフォルト
        vm.toggleSort(key: .name)
        #expect(vm.sortKey == .name)
        #expect(vm.sortAscending == true)

        // 登録日時に切り替えたら降順（新しい順）がデフォルト
        vm.toggleSort(key: .createdAt)
        #expect(vm.sortKey == .createdAt)
        #expect(vm.sortAscending == false)
    }

    @Test func menuSortDirectionChangesWithoutChangingKey() throws {
        let context = makeTestContext()
        _ = makeCard(context: context, lastName: "山田")
        try context.save()

        let vm = CardListViewModel(context: context)
        vm.sortKey = .name
        vm.sortAscending = true

        vm.setSortAscending(false)

        #expect(vm.sortKey == .name)
        #expect(vm.sortAscending == false)
    }

    @Test func createdAtSortRespectsAscendingFlag() async throws {
        let context = makeTestContext()
        let old = makeCard(context: context, lastName: "古い",
                           createdAt: Date(timeIntervalSinceReferenceDate: 0))
        let new = makeCard(context: context, lastName: "新しい",
                           createdAt: Date(timeIntervalSinceReferenceDate: 10_000_000))
        try context.save()

        let vm = CardListViewModel(context: context)
        vm.sortKey = .createdAt
        vm.sortAscending = false
        vm.fetchCards()
        await vm.waitForPendingListUpdate()
        #expect(vm.cards.first?.id == new.id)

        vm.sortAscending = true
        vm.fetchCards()
        await vm.waitForPendingListUpdate()
        #expect(vm.cards.first?.id == old.id)
    }

    @Test func nameSortUsesReadingWhenAvailable() async throws {
        let context = makeTestContext()
        // ふりがなで比較した場合: あ(aさとう) < い(いとう) < や(やまだ)
        // 漢字コードポイント順とは結果が異なることを確認
        _ = makeCard(context: context, lastName: "山田", lastNameReading: "やまだ")
        _ = makeCard(context: context, lastName: "伊藤", lastNameReading: "いとう")
        _ = makeCard(context: context, lastName: "佐藤", lastNameReading: "さとう")
        try context.save()

        let vm = CardListViewModel(context: context)
        vm.sortKey = .name
        vm.sortAscending = true
        vm.fetchCards()
        await vm.waitForPendingListUpdate()
        let names = vm.filteredCardItems.compactMap { $0.detail.fullNameReading }
        #expect(names == ["いとう", "さとう", "やまだ"])
    }
}

// MARK: - 一括操作・選択

@MainActor
struct CardListViewModelBulkOperationTests {

    @Test func listItemsReturnMatchingPersistentURIs() async throws {
        let context = makeTestContext()
        let a = makeCard(context: context, lastName: "山田")
        let b = makeCard(context: context, lastName: "佐藤")
        _ = makeCard(context: context, lastName: "鈴木")
        try context.save()

        let vm = CardListViewModel(context: context)
        await vm.waitForPendingListUpdate()
        let selectedURIs = Set([a, b].map { $0.objectID.uriRepresentation() })
        let selected = vm.filteredCardItems.filter { selectedURIs.contains($0.id) }
        #expect(selected.count == 2)
        #expect(selected.map(\.id).contains(a.objectID.uriRepresentation()))
        #expect(selected.map(\.id).contains(b.objectID.uriRepresentation()))
    }

    @Test func toggleBulkFavoriteTurnsAllOn() async throws {
        let context = makeTestContext()
        let a = makeCard(context: context, lastName: "山田", isFavorite: false)
        let b = makeCard(context: context, lastName: "佐藤", isFavorite: false)
        try context.save()

        let vm = CardListViewModel(context: context)
        await vm.waitForPendingListUpdate()
        vm.toggleBulkFavorite(
            objectURIs: Set([a, b].map { $0.objectID.uriRepresentation() })
        )
        #expect(a.isFavorite == true)
        #expect(b.isFavorite == true)
    }

    @Test func toggleBulkFavoriteTurnsAllOffWhenAllOn() async throws {
        let context = makeTestContext()
        let a = makeCard(context: context, lastName: "山田", isFavorite: true)
        let b = makeCard(context: context, lastName: "佐藤", isFavorite: true)
        try context.save()

        let vm = CardListViewModel(context: context)
        await vm.waitForPendingListUpdate()
        vm.toggleBulkFavorite(
            objectURIs: Set([a, b].map { $0.objectID.uriRepresentation() })
        )
        #expect(a.isFavorite == false)
        #expect(b.isFavorite == false)
    }

    @Test func addTagToCardsAppliesToAll() async throws {
        let context = makeTestContext()
        let tag = makeTag(context: context, name: "重要")
        let a = makeCard(context: context, lastName: "山田")
        let b = makeCard(context: context, lastName: "佐藤")
        try context.save()

        let vm = CardListViewModel(context: context)
        await vm.waitForPendingListUpdate()
        vm.addTagToCards(
            tag: tag,
            objectURIs: Set([a, b].map { $0.objectID.uriRepresentation() })
        )

        let aTags = (a.tags as? Set<CardTag>) ?? []
        let bTags = (b.tags as? Set<CardTag>) ?? []
        #expect(aTags.contains(tag))
        #expect(bTags.contains(tag))
    }

    @Test func removeTagFromCardsRemovesFromAll() async throws {
        let context = makeTestContext()
        let tag = makeTag(context: context, name: "重要")
        let a = makeCard(context: context, lastName: "山田")
        a.addToTags(tag)
        let b = makeCard(context: context, lastName: "佐藤")
        b.addToTags(tag)
        try context.save()

        let vm = CardListViewModel(context: context)
        await vm.waitForPendingListUpdate()
        vm.removeTagFromCards(
            tag: tag,
            objectURIs: Set([a, b].map { $0.objectID.uriRepresentation() })
        )

        let aTags = (a.tags as? Set<CardTag>) ?? []
        let bTags = (b.tags as? Set<CardTag>) ?? []
        #expect(!aTags.contains(tag))
        #expect(!bTags.contains(tag))
    }

    @Test func bulkTagAssignmentSummaryCountsSelectedRelationshipsOnce() async throws {
        let context = makeTestContext()
        let tag = makeTag(context: context, name: "合成タグ")
        let firstCard = makeCard(context: context, lastName: "甲")
        let secondCard = makeCard(context: context, lastName: "乙")
        firstCard.addToTags(tag)
        try context.save()

        let vm = CardListViewModel(context: context)
        await vm.waitForPendingListUpdate()
        let summary = vm.bulkTagAssignmentSummary(
            for: Set([firstCard, secondCard].map { $0.objectID.uriRepresentation() })
        )

        #expect(summary.selectedCardCount == 2)
        #expect(summary.assignment(for: tag.id) == .some)
    }

    @Test func deleteCardsRemovesFromContext() async throws {
        let context = makeTestContext()
        let a = makeCard(context: context, lastName: "山田")
        let b = makeCard(context: context, lastName: "佐藤")
        try context.save()

        let vm = CardListViewModel(context: context)
        await vm.waitForPendingListUpdate()
        vm.deleteCards([a])
        await vm.waitForPendingListUpdate()

        #expect(vm.cards.count == 1)
        #expect(vm.cards.first?.id == b.id)
    }

    @Test func deleteAllCardsEmptiesList() async throws {
        let context = makeTestContext()
        _ = makeCard(context: context, lastName: "山田")
        _ = makeCard(context: context, lastName: "佐藤")
        try context.save()

        let vm = CardListViewModel(context: context)
        await vm.waitForPendingListUpdate()
        vm.deleteAllCards()
        await vm.waitForPendingDataMutation()

        #expect(vm.cards.isEmpty)
    }
}

// MARK: - タグ管理

@MainActor
struct CardListViewModelTagTests {

    @Test func tagDisplaySnapshotContainsStableValuesAndUsageCount() async throws {
        let context = makeTestContext()
        let tag = makeTag(context: context, name: "合成タグ")
        tag.colorHex = "#34C759"
        let firstCard = makeCard(context: context, lastName: "甲")
        let secondCard = makeCard(context: context, lastName: "乙")
        firstCard.addToTags(tag)
        secondCard.addToTags(tag)
        try context.save()

        let vm = CardListViewModel(context: context)
        await vm.waitForPendingTagDisplaySnapshotRefresh()
        let snapshot = try #require(vm.tagDisplaySnapshots.first { $0.name == "合成タグ" })

        #expect(snapshot.tagID == tag.id)
        #expect(snapshot.objectURI == tag.objectID.uriRepresentation().absoluteString)
        #expect(snapshot.colorHex == "#34C759")
        #expect(snapshot.usageCount == 2)
    }

    @Test func contextRefreshDeferralFetchesOnlyWhenCallerConfirmsMutation() async throws {
        let context = makeTestContext()
        let vm = CardListViewModel(context: context)

        let cancelledToken = vm.beginContextRefreshDeferral()
        _ = makeCard(context: context, lastName: "未確定")
        vm.endContextRefreshDeferral(cancelledToken, refreshCards: false)
        #expect(vm.cards.isEmpty)
        context.rollback()

        let committedToken = vm.beginContextRefreshDeferral()
        let committedCard = makeCard(context: context, lastName: "確定")
        try context.save()
        vm.endContextRefreshDeferral(committedToken, refreshCards: true)
        await vm.waitForPendingListUpdate()
        #expect(vm.cards.map(\.objectID) == [committedCard.objectID])
    }

    @Test func createTagAppendsToList() async throws {
        let context = makeTestContext()
        let vm = CardListViewModel(context: context)
        let before = vm.allTags.count

        let result = vm.createTag(name: "新規タグ", colorHex: "#00FF00")
        await vm.waitForPendingTagDisplaySnapshotRefresh()
        #expect(result == .success)
        #expect(vm.allTags.count == before + 1)
        #expect(vm.allTags.contains { $0.name == "新規タグ" })
        #expect(vm.tagDisplaySnapshots.contains { $0.name == "新規タグ" })
    }

    @Test func updateTagPublishesKnownValuesBeforeUsageCountReloadCompletes() async throws {
        let context = makeTestContext()
        let tag = makeTag(context: context, name: "変更前")
        let card = makeCard(context: context, lastName: "甲")
        card.addToTags(tag)
        try context.save()

        let vm = CardListViewModel(context: context)
        await vm.waitForPendingTagDisplaySnapshotRefresh()
        let result = vm.updateTag(tag, name: "変更後", colorHex: "#AF52DE")
        let snapshot = try #require(vm.tagDisplaySnapshots.first {
            $0.objectURI == tag.objectID.uriRepresentation().absoluteString
        })

        #expect(result == .success)
        #expect(snapshot.name == "変更後")
        #expect(snapshot.colorHex == "#AF52DE")
        #expect(snapshot.usageCount == 1)
    }

    @Test func tagMutationsResolveSnapshotURIWithoutViewOwnedManagedObject() async throws {
        let context = makeTestContext()
        let tag = makeTag(context: context, name: "変更前")
        let card = makeCard(context: context, lastName: "甲")
        try context.save()

        let vm = CardListViewModel(context: context)
        await vm.waitForPendingTagDisplaySnapshotRefresh()
        let objectURI = tag.objectID.uriRepresentation().absoluteString
        let cardURI = card.objectID.uriRepresentation()

        let updateResult = vm.updateTag(
            objectURI: objectURI,
            name: "変更後",
            colorHex: "#34C759"
        )
        #expect(updateResult == .success)
        #expect(tag.name == "変更後")

        vm.addTagToCards(tagObjectURI: objectURI, cardObjectURIs: [cardURI])
        #expect(((card.tags as? Set<CardTag>) ?? []).contains(tag))

        vm.removeTagFromCards(tagObjectURI: objectURI, cardObjectURIs: [cardURI])
        #expect(!((card.tags as? Set<CardTag>) ?? []).contains(tag))

        vm.deleteTag(objectURI: objectURI)
        await vm.waitForPendingTagDisplaySnapshotRefresh()
        #expect(!vm.tagDisplaySnapshots.contains { $0.objectURI == objectURI })
    }

    @Test func createTagFailureReturnsLocalErrorAndRollsBack() {
        let backingContext = makeTestContext()
        let context = FailingSaveContext(concurrencyType: .mainQueueConcurrencyType)
        context.persistentStoreCoordinator = backingContext.persistentStoreCoordinator
        let vm = CardListViewModel(context: context)

        let result = vm.createTag(name: "保存失敗", colorHex: "#00FF00")

        guard case .failure(let message) = result else {
            Issue.record("保存失敗がfailureとして返りませんでした")
            return
        }
        #expect(message.contains("タグの作成に失敗"))
        #expect(vm.errorMessage == nil)
        #expect(!context.hasChanges)
    }

    @Test func deleteTagRemovesFromList() async throws {
        let context = makeTestContext()
        let vm = CardListViewModel(context: context)
        vm.createTag(name: "消すタグ", colorHex: "#FF0000")
        let tag = try #require(vm.allTags.first { $0.name == "消すタグ" })

        vm.deleteTag(tag)
        await vm.waitForPendingTagDisplaySnapshotRefresh()
        #expect(!vm.allTags.contains { $0.name == "消すタグ" })
        #expect(!vm.tagDisplaySnapshots.contains { $0.name == "消すタグ" })
    }

    @Test func toggleTagOnCardTogglesMembership() throws {
        let context = makeTestContext()
        let tag = makeTag(context: context, name: "重要")
        let card = makeCard(context: context, lastName: "山田")
        try context.save()

        let vm = CardListViewModel(context: context)
        vm.toggleTag(tag, on: card)
        #expect(((card.tags as? Set<CardTag>) ?? []).contains(tag))

        vm.toggleTag(tag, on: card)
        #expect(!((card.tags as? Set<CardTag>) ?? []).contains(tag))
    }
}

// MARK: - 表示更新世代

@MainActor
struct CardListViewModelContentRevisionTests {

    @Test func refetchDoesNotPublishUnfilteredIntermediateState() async throws {
        let context = makeTestContext()
        let visible = makeCard(
            context: context,
            lastName: "Fixture-Visible",
            isFavorite: true
        )
        _ = makeCard(
            context: context,
            lastName: "Fixture-Hidden",
            isFavorite: false
        )
        try context.save()

        let vm = CardListViewModel(context: context)
        vm.setFavoritesFilter(true)
        await vm.waitForPendingListUpdate()
        #expect(vm.filteredCardItems.map(\.id) == [visible.objectID.uriRepresentation()])

        _ = makeCard(
            context: context,
            lastName: "Fixture-New-Hidden",
            isFavorite: false
        )
        try context.save()
        vm.fetchCards()

        // workerの新世代が完成するまでは、直前の整合した表示を維持する。
        #expect(vm.filteredCardItems.map(\.id) == [visible.objectID.uriRepresentation()])
        await vm.waitForPendingListUpdate()
        #expect(vm.filteredCardItems.map(\.id) == [visible.objectID.uriRepresentation()])
    }

    @Test func managedObjectContextChangesRebuildSearchSnapshot() async throws {
        let context = makeTestContext()
        let card = makeCard(context: context, lastName: "Fixture-Before")
        try context.save()

        let vm = CardListViewModel(context: context)
        vm.searchText = "Fixture-After"
        await vm.waitForPendingListUpdate()
        #expect(vm.filteredCardItems.isEmpty)

        card.lastName = "Fixture-After"
        card.updatedAt = Date()
        try context.save()
        await vm.waitForPendingContextRefresh()

        #expect(vm.filteredCardItems.map(\.id) == [card.objectID.uriRepresentation()])
    }

    @Test func duplicateDetectionPublishesBackgroundResult() async throws {
        let context = makeTestContext()
        _ = makeCard(
            context: context,
            lastName: "Fixture-Duplicate",
            firstName: "Alpha",
            company: "Example One株式会社"
        )
        _ = makeCard(
            context: context,
            lastName: "Fixture-Duplicate",
            firstName: "Alpha",
            company: "Example Two株式会社"
        )
        try context.save()

        let vm = CardListViewModel(context: context)
        for _ in 0 ..< 100 {
            guard vm.duplicatePairs.isEmpty else { break }
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(vm.duplicatePairs.count == 1)
        #expect(vm.duplicatePairs.first?.score == 1.0)
    }

    @Test func unchangedRefetchKeepsContentRevision() async throws {
        let context = makeTestContext()
        _ = makeCard(context: context, lastName: "Fixture-01")
        try context.save()

        let vm = CardListViewModel(context: context)
        await vm.waitForPendingListUpdate()
        let revision = vm.cardsContentRevision

        vm.fetchCards()
        await vm.waitForPendingListUpdate()

        #expect(vm.cardsContentRevision == revision)
    }

    @Test func persistedCardUpdateAdvancesContentRevision() async throws {
        let context = makeTestContext()
        let card = makeCard(context: context, lastName: "Fixture-01")
        try context.save()

        let vm = CardListViewModel(context: context)
        await vm.waitForPendingListUpdate()
        let revision = vm.cardsContentRevision
        card.company = "Example Company"
        card.updatedAt = (card.updatedAt ?? Date()).addingTimeInterval(1)
        try context.save()

        vm.fetchCards()
        await vm.waitForPendingListUpdate()

        #expect(vm.cardsContentRevision == revision + 1)
    }

    @Test func sortingDoesNotAdvanceContentRevision() async throws {
        let context = makeTestContext()
        _ = makeCard(context: context, lastName: "Fixture-01")
        _ = makeCard(context: context, lastName: "Fixture-02")
        try context.save()

        let vm = CardListViewModel(context: context)
        await vm.waitForPendingListUpdate()
        let revision = vm.cardsContentRevision

        vm.setSortAscending(!vm.sortAscending)

        #expect(vm.cardsContentRevision == revision)
    }

    @Test func snapshotLoaderPreservesRequestedObjectURIOrder() async throws {
        let context = makeTestContext()
        let first = makeCard(
            context: context,
            lastName: "Fixture-First",
            company: "Example Alpha"
        )
        let second = makeCard(
            context: context,
            lastName: "Fixture-Second",
            company: "Example Beta"
        )
        let tag = makeTag(context: context, name: "Fixture-Tag")
        second.addToTags(tag)
        try context.save()

        let coordinator = try #require(context.persistentStoreCoordinator)
        let requestedURIs = [
            second.objectID.uriRepresentation(),
            first.objectID.uriRepresentation(),
        ]
        let result = try await CardListQuerySnapshotLoader().load(
            orderedObjectURIs: requestedURIs,
            coordinatorReference: PersistentStoreCoordinatorReference(coordinator: coordinator)
        )

        #expect(result.orderedObjectURIs == requestedURIs)
        #expect(result.snapshots.map(\.id) == [second.id, first.id])
        #expect(result.snapshots.map(\.index) == [0, 1])
        #expect(result.snapshots[0].tagIDs == [tag.id!])
        #expect(result.snapshots[0].searchValues.contains("Fixture-Tag"))
        #expect(result.snapshots[0].row.displayName == "Fixture-Second")
        #expect(result.snapshots[0].row.company == "Example Beta")
        #expect(result.snapshots[0].row.firstTag?.name == "Fixture-Tag")
    }

    @Test func rapidRefetchPublishesOnlyLatestPersistedValues() async throws {
        let context = makeTestContext()
        let card = makeCard(context: context, lastName: "Fixture-Initial")
        try context.save()

        let vm = CardListViewModel(context: context)
        await vm.waitForPendingListUpdate()

        card.lastName = "Fixture-Intermediate"
        card.updatedAt = Date(timeIntervalSinceReferenceDate: 100)
        try context.save()
        vm.fetchCards()

        card.lastName = "Fixture-Latest"
        card.updatedAt = Date(timeIntervalSinceReferenceDate: 200)
        try context.save()
        vm.fetchCards()
        vm.searchText = "Fixture-Latest"
        await vm.waitForPendingListUpdate()

        #expect(vm.filteredCardItems.map(\.id) == [card.objectID.uriRepresentation()])
        #expect(vm.filteredCardItems.first?.row.displayName == "Fixture-Latest")
    }
}
