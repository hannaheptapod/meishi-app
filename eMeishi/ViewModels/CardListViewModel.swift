import Foundation
import CoreData
import Combine
import SwiftUI
import os

// ソートキー（4種）
nonisolated enum CardSortKey: String, CaseIterable, Identifiable, Sendable {
    case name      = "名前"
    case company   = "会社名"
    case createdAt = "登録日時"
    case updatedAt = "更新日時"

    var id: String { rawValue }
}

// セクション（グループ）単位
struct CardSection: Identifiable {
    let id: String
    let title: String
    let cards: [BusinessCard]
}

/// 一覧描画・選択・ナビゲーションで使用する完全な値型。
/// Core Dataオブジェクトは保存操作を実行する瞬間だけURIから解決する。
nonisolated struct CardListItemSnapshot: Identifiable, Equatable, Sendable {
    let id: URL
    let row: CardRowDisplaySnapshot
    let detail: CardDetailDisplaySnapshot
    let imageIdentifier: String

    func settingFavorite(_ isFavorite: Bool) -> CardListItemSnapshot {
        CardListItemSnapshot(
            id: id,
            row: CardRowDisplaySnapshot(
                displayName: row.displayName,
                company: row.company,
                affiliation: row.affiliation,
                isFavorite: isFavorite,
                firstTag: row.firstTag,
                additionalTagCount: row.additionalTagCount,
                accessibilityLabel: row.accessibilityLabel
            ),
            detail: detail.settingFavorite(isFavorite),
            imageIdentifier: imageIdentifier
        )
    }
}

nonisolated struct CardListItemSection: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let items: [CardListItemSnapshot]
}

private struct CardListDisplaySnapshot {
    let isReady: Bool
    let sourceCount: Int
    let sourceObjectURIs: Set<URL>
    let normalizedQuery: String
    let isFilterActive: Bool
    let externalFilter: CardListExternalFilter?
    let sortKey: CardSortKey
    let isSemanticSearchInProgress: Bool
    let semanticSearchMessage: String?
    let filteredItems: [CardListItemSnapshot]
    let groupedItemSections: [CardListItemSection]

    static let loading = CardListDisplaySnapshot(
        isReady: false,
        sourceCount: 0,
        sourceObjectURIs: [],
        normalizedQuery: "",
        isFilterActive: false,
        externalFilter: nil,
        sortKey: .createdAt,
        isSemanticSearchInProgress: false,
        semanticSearchMessage: nil,
        filteredItems: [],
        groupedItemSections: []
    )
}

/// CoreData 管理オブジェクトを並行処理へ渡さないための一覧検索用スナップショット。
nonisolated struct CardListQuerySnapshot: Equatable, Sendable {
    let index: Int
    let id: UUID?
    let row: CardRowDisplaySnapshot
    let detail: CardDetailDisplaySnapshot
    let searchValues: [String]
    let tagIDs: Set<UUID>
    let aiSearch: AISearchCardSnapshot?
    let bulkAutoTag: BulkAutoTagCardSnapshot
    let insights: InsightsCardSnapshot
    let nameSectionValue: String
    let companySectionValue: String
    let nameSortValue: String
    let companySortValue: String
    let createdAt: Date?
    let updatedAt: Date?
}

nonisolated struct CardRowTagSnapshot: Equatable, Sendable {
    let name: String
    let colorHex: String
}

nonisolated struct CardRowDisplaySnapshot: Equatable, Sendable {
    let displayName: String
    let company: String
    let affiliation: String
    let isFavorite: Bool
    let firstTag: CardRowTagSnapshot?
    let additionalTagCount: Int
    let accessibilityLabel: String

    static let unavailable = CardRowDisplaySnapshot(
        displayName: "（名前なし）",
        company: "",
        affiliation: "",
        isFavorite: false,
        firstTag: nil,
        additionalTagCount: 0,
        accessibilityLabel: "名前なし"
    )
}

nonisolated struct CardListCardRevision: Hashable, Sendable {
    let objectURI: URL
    let updatedAt: Date?
}

nonisolated struct CardListQuerySnapshotLoadResult: Equatable, Sendable {
    let orderedObjectURIs: [URL]
    let snapshots: [CardListQuerySnapshot]
    let duplicateSnapshots: [DuplicateCardSnapshot]
    let revisions: Set<CardListCardRevision>
}

nonisolated struct CardListQueryRequest: Sendable {
    let snapshotGeneration: UUID
    let snapshots: [CardListQuerySnapshot]
    let normalizedQuery: String
    let selectedTagIDs: Set<UUID>
    let showFavoritesOnly: Bool
    let externalFilter: CardListExternalFilter?
    let semanticQuery: String?
    let semanticMatchedCardIDs: Set<UUID>
    let isSemanticSearchInProgress: Bool
    let semanticSearchMessage: String?
    let sortKey: CardSortKey
    let sortAscending: Bool
    let now: Date
}

nonisolated struct CardListQuerySectionResult: Equatable, Sendable {
    let id: String
    let title: String
    let indices: [Int]
}

nonisolated struct CardListQueryResult: Equatable, Sendable {
    let snapshotCount: Int
    let filteredIndices: [Int]
    let sections: [CardListQuerySectionResult]
}

/// タグ管理画面へ渡す描画専用の値スナップショット。
/// View が Core Data の to-many relationship を評価するたびに展開しないよう、
/// タグ取得時に使用件数まで確定する。
nonisolated struct TagDisplaySnapshot: Identifiable, Equatable, Sendable {
    let tagID: UUID?
    let objectURI: String
    let name: String
    let colorHex: String
    let usageCount: Int

    var id: String { objectURI }
}

nonisolated struct TagDisplaySnapshotLoadResult: Equatable, Sendable {
    let orderedObjectURIs: [URL]
    let snapshots: [TagDisplaySnapshot]
}

/// タグ管理に必要な使用件数をprivate queueで確定し、値型だけをMainActorへ返す。
/// `Tag.cards`のprefetchと件数集計を一覧画面の描画Actorから分離する。
actor TagDisplaySnapshotLoader {
    func load(
        orderedObjectURIs: [URL],
        coordinatorReference: PersistentStoreCoordinatorReference
    ) async throws -> TagDisplaySnapshotLoadResult {
        try Task.checkCancellation()
        guard !orderedObjectURIs.isEmpty else {
            return TagDisplaySnapshotLoadResult(
                orderedObjectURIs: [],
                snapshots: []
            )
        }

        let context = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
        context.persistentStoreCoordinator = coordinatorReference.coordinator
        context.name = "TagDisplaySnapshotLoader"
        context.undoManager = nil

        return try await context.perform {
            try Task.checkCancellation()
            let objectIDs = orderedObjectURIs.compactMap {
                coordinatorReference.coordinator.managedObjectID(forURIRepresentation: $0)
            }
            guard objectIDs.count == orderedObjectURIs.count else {
                return TagDisplaySnapshotLoadResult(
                    orderedObjectURIs: [],
                    snapshots: []
                )
            }

            let request = NSFetchRequest<NSManagedObject>(entityName: "Tag")
            request.predicate = NSPredicate(format: "SELF IN %@", objectIDs)
            request.relationshipKeyPathsForPrefetching = ["cards"]
            request.returnsObjectsAsFaults = false
            let fetched = try context.fetch(request)
            try Task.checkCancellation()

            let tagsByURI = Dictionary(uniqueKeysWithValues: fetched.map {
                ($0.objectID.uriRepresentation(), $0)
            })
            let snapshots = orderedObjectURIs.compactMap { objectURI -> TagDisplaySnapshot? in
                guard let tag = tagsByURI[objectURI] else { return nil }
                return TagDisplaySnapshot(
                    tagID: tag.value(forKey: "id") as? UUID,
                    objectURI: objectURI.absoluteString,
                    name: tag.value(forKey: "name") as? String ?? "",
                    colorHex: tag.value(forKey: "colorHex") as? String ?? "#007AFF",
                    usageCount: (tag.value(forKey: "cards") as? NSSet)?.count ?? 0
                )
            }
            return TagDisplaySnapshotLoadResult(
                orderedObjectURIs: orderedObjectURIs,
                snapshots: snapshots
            )
        }
    }
}

/// 検索・外部フィルター・セクション集計を MainActor 外で直列実行する。
actor CardListQueryWorker {
    private struct PreparedSnapshot: Sendable {
        let source: CardListQuerySnapshot
        let normalizedSearchValues: [String]
    }

    private var preparedGeneration: UUID?
    private var preparedSnapshots: [PreparedSnapshot] = []

    func evaluate(_ request: CardListQueryRequest) -> CardListQueryResult? {
        let prepared = prepareSnapshots(for: request)
        guard !Task.isCancelled else { return nil }
        let ordered = sort(
            prepared,
            key: request.sortKey,
            ascending: request.sortAscending
        )
        var filtered: [PreparedSnapshot] = []
        filtered.reserveCapacity(request.snapshots.count)

        for snapshot in ordered {
            guard !Task.isCancelled else { return nil }
            let source = snapshot.source
            guard !request.showFavoritesOnly || source.insights.isFavorite else { continue }
            guard request.selectedTagIDs.isSubset(of: source.tagIDs) else { continue }
            if let filter = request.externalFilter,
               !InsightsAggregationRules.matches(
                   source.insights,
                   filter: filter,
                   now: request.now
               ) {
                continue
            }

            if !request.normalizedQuery.isEmpty {
                let lexicalMatch = snapshot.normalizedSearchValues.contains {
                    $0.contains(request.normalizedQuery)
                }
                let semanticMatch = request.semanticQuery == request.normalizedQuery
                    && source.id.map(request.semanticMatchedCardIDs.contains) == true
                guard lexicalMatch || semanticMatch else { continue }
            }
            filtered.append(snapshot)
        }

        let sections = request.normalizedQuery.isEmpty
            ? group(filtered, sortKey: request.sortKey, ascending: request.sortAscending, now: request.now)
            : []
        return CardListQueryResult(
            snapshotCount: request.snapshots.count,
            filteredIndices: filtered.map(\.source.index),
            sections: sections
        )
    }

    private func prepareSnapshots(for request: CardListQueryRequest) -> [PreparedSnapshot] {
        if preparedGeneration == request.snapshotGeneration,
           preparedSnapshots.count == request.snapshots.count {
            return preparedSnapshots
        }
        let prepared = request.snapshots.map { snapshot in
            PreparedSnapshot(
                source: snapshot,
                normalizedSearchValues: snapshot.searchValues
                    .map(Self.normalize)
                    .filter { !$0.isEmpty }
            )
        }
        preparedGeneration = request.snapshotGeneration
        preparedSnapshots = prepared
        return prepared
    }

    private func sort(
        _ snapshots: [PreparedSnapshot],
        key: CardSortKey,
        ascending: Bool
    ) -> [PreparedSnapshot] {
        snapshots.sorted { lhs, rhs in
            let comparison: ComparisonResult
            switch key {
            case .name:
                comparison = lhs.source.nameSortValue.localizedStandardCompare(rhs.source.nameSortValue)
            case .company:
                comparison = lhs.source.companySortValue.localizedStandardCompare(rhs.source.companySortValue)
            case .createdAt:
                comparison = Self.compare(lhs.source.createdAt, rhs.source.createdAt)
            case .updatedAt:
                comparison = Self.compare(lhs.source.updatedAt, rhs.source.updatedAt)
            }
            if comparison == .orderedSame {
                return lhs.source.index < rhs.source.index
            }
            return ascending ? comparison == .orderedAscending : comparison == .orderedDescending
        }
    }

    private static func compare(_ lhs: Date?, _ rhs: Date?) -> ComparisonResult {
        let lhs = lhs ?? .distantPast
        let rhs = rhs ?? .distantPast
        if lhs == rhs { return .orderedSame }
        return lhs < rhs ? .orderedAscending : .orderedDescending
    }

    private static func normalize(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }

    private func group(
        _ snapshots: [PreparedSnapshot],
        sortKey: CardSortKey,
        ascending: Bool,
        now: Date
    ) -> [CardListQuerySectionResult] {
        switch sortKey {
        case .name:
            return groupBySection(snapshots, ascending: ascending) { $0.source.nameSectionValue }
        case .company:
            return groupBySection(
                snapshots,
                ascending: ascending,
                value: { $0.source.companySectionValue },
                trailingKey: "（会社名なし）"
            )
        case .createdAt:
            return groupByDate(snapshots, ascending: ascending, now: now) { $0.source.createdAt }
        case .updatedAt:
            return groupByDate(snapshots, ascending: ascending, now: now) { $0.source.updatedAt }
        }
    }

    private func groupBySection(
        _ snapshots: [PreparedSnapshot],
        ascending: Bool,
        value: (PreparedSnapshot) -> String,
        trailingKey: String? = nil
    ) -> [CardListQuerySectionResult] {
        var buckets: [String: [Int]] = [:]
        for snapshot in snapshots {
            let rawValue = value(snapshot)
            let key = rawValue.isEmpty
                ? (trailingKey ?? "その他")
                : CardGroupingService.sectionKey(for: rawValue)
            buckets[key, default: []].append(snapshot.source.index)
        }

        let orderedKeys: [String] = ascending
            ? CardGroupingService.sectionOrder
            : Array(CardGroupingService.sectionOrder.reversed())
        var result = orderedKeys.compactMap { key -> CardListQuerySectionResult? in
            guard let indices = buckets[key] else { return nil }
            return CardListQuerySectionResult(id: key, title: key, indices: indices)
        }
        if let trailingKey, let indices = buckets[trailingKey] {
            result.append(CardListQuerySectionResult(
                id: trailingKey,
                title: trailingKey,
                indices: indices
            ))
        }
        return result
    }

    private func groupByDate(
        _ snapshots: [PreparedSnapshot],
        ascending: Bool,
        now: Date,
        date: (PreparedSnapshot) -> Date?
    ) -> [CardListQuerySectionResult] {
        let calendar = Calendar.current
        let startOfToday = calendar.startOfDay(for: now)
        let startOfWeek = calendar.dateInterval(of: .weekOfYear, for: now)?.start ?? startOfToday
        let startOfMonth = calendar.dateInterval(of: .month, for: now)?.start ?? startOfToday
        let threeMonthsAgo = calendar.date(
            byAdding: .month,
            value: -3,
            to: startOfMonth
        ) ?? startOfToday
        let orderedKeys = ["今日", "今週", "今月", "3ヶ月以内", "それ以前"]
        var buckets: [String: [Int]] = [:]

        for snapshot in snapshots {
            let value = date(snapshot) ?? .distantPast
            let key: String
            if value >= startOfToday {
                key = "今日"
            } else if value >= startOfWeek {
                key = "今週"
            } else if value >= startOfMonth {
                key = "今月"
            } else if value >= threeMonthsAgo {
                key = "3ヶ月以内"
            } else {
                key = "それ以前"
            }
            buckets[key, default: []].append(snapshot.source.index)
        }

        let keys = ascending ? Array(orderedKeys.reversed()) : orderedKeys
        return keys.compactMap { key in
            guard let indices = buckets[key] else { return nil }
            return CardListQuerySectionResult(id: key, title: key, indices: indices)
        }
    }
}

/// 一覧検索に必要なCore Data値をprivate queueで読み出す。
/// MainActorには管理オブジェクトを渡さず、URI順を維持した値型だけを返す。
actor CardListQuerySnapshotLoader {
    private nonisolated struct TagValue: Sendable {
        let id: UUID?
        let objectURI: String
        let name: String
        let colorHex: String
    }

    private nonisolated enum LoaderError: Error {
        case missingObjectID
    }

    func loadAll(
        sortKey: CardSortKey,
        ascending: Bool,
        coordinatorReference: PersistentStoreCoordinatorReference
    ) async throws -> CardListQuerySnapshotLoadResult {
        try Task.checkCancellation()
        let context = makeContext(coordinatorReference: coordinatorReference)
        return try await context.perform {
            try Task.checkCancellation()
            let request = NSFetchRequest<NSDictionary>(entityName: "BusinessCard")
            request.sortDescriptors = Self.sortDescriptors(key: sortKey, ascending: ascending)
            Self.configure(request)
            let fetched = try context.fetch(request)
            try Task.checkCancellation()
            let orderedObjectIDs = try fetched.map { values -> NSManagedObjectID in
                guard let objectID = values[Self.objectIDKey] as? NSManagedObjectID else {
                    throw LoaderError.missingObjectID
                }
                return objectID
            }
            let tagsByCardURI = try Self.loadTags(
                for: orderedObjectIDs,
                context: context
            )
            return try Self.makeLoadResult(
                fetched: fetched,
                orderedObjectURIs: orderedObjectIDs.map { $0.uriRepresentation() },
                tagsByCardURI: tagsByCardURI
            )
        }
    }

    func load(
        orderedObjectURIs: [URL],
        coordinatorReference: PersistentStoreCoordinatorReference
    ) async throws -> CardListQuerySnapshotLoadResult {
        try Task.checkCancellation()
        guard !orderedObjectURIs.isEmpty else {
            return CardListQuerySnapshotLoadResult(
                orderedObjectURIs: [],
                snapshots: [],
                duplicateSnapshots: [],
                revisions: []
            )
        }

        let context = makeContext(coordinatorReference: coordinatorReference)

        return try await context.perform {
            try Task.checkCancellation()
            let objectIDs = orderedObjectURIs.compactMap {
                coordinatorReference.coordinator.managedObjectID(forURIRepresentation: $0)
            }
            guard objectIDs.count == orderedObjectURIs.count else {
                return CardListQuerySnapshotLoadResult(
                    orderedObjectURIs: [],
                    snapshots: [],
                    duplicateSnapshots: [],
                    revisions: []
                )
            }

            let request = NSFetchRequest<NSDictionary>(entityName: "BusinessCard")
            request.predicate = NSPredicate(format: "SELF IN %@", objectIDs)
            Self.configure(request)
            let fetched = try context.fetch(request)
            try Task.checkCancellation()
            let tagsByCardURI = try Self.loadTags(for: objectIDs, context: context)
            return try Self.makeLoadResult(
                fetched: fetched,
                orderedObjectURIs: orderedObjectURIs,
                tagsByCardURI: tagsByCardURI
            )
        }
    }

    private nonisolated func makeContext(
        coordinatorReference: PersistentStoreCoordinatorReference
    ) -> NSManagedObjectContext {
        let context = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
        context.persistentStoreCoordinator = coordinatorReference.coordinator
        context.name = "CardListQuerySnapshotLoader"
        context.undoManager = nil
        return context
    }

    private nonisolated static let objectIDKey = "snapshotObjectID"

    /// 画像BLOBを含めず、一覧・検索・重複判定に必要な属性だけをSQL行から取得する。
    private nonisolated static func configure(_ request: NSFetchRequest<NSDictionary>) {
        let objectIDExpression = NSExpressionDescription()
        objectIDExpression.name = objectIDKey
        objectIDExpression.expression = NSExpression.expressionForEvaluatedObject()
        objectIDExpression.expressionResultType = .objectIDAttributeType
        request.resultType = .dictionaryResultType
        var propertiesToFetch = scalarPropertyKeys.map { $0 as Any }
        propertiesToFetch.append(objectIDExpression)
        request.propertiesToFetch = propertiesToFetch
    }

    private nonisolated static let scalarPropertyKeys = [
        "id",
        "lastName",
        "lastNameReading",
        "firstName",
        "firstNameReading",
        "company",
        "companyReading",
        "department",
        "title",
        "email",
        "phone",
        "address",
        "website",
        "notes",
        "createdAt",
        "updatedAt",
        "isFavorite",
    ]

    private nonisolated static func sortDescriptors(
        key: CardSortKey,
        ascending: Bool
    ) -> [NSSortDescriptor] {
        switch key {
        case .name:
            return [
                NSSortDescriptor(key: "lastName", ascending: ascending),
                NSSortDescriptor(key: "firstName", ascending: ascending),
            ]
        case .company:
            return [
                NSSortDescriptor(key: "company", ascending: ascending),
                NSSortDescriptor(key: "lastName", ascending: ascending),
            ]
        case .createdAt:
            return [NSSortDescriptor(key: "createdAt", ascending: ascending)]
        case .updatedAt:
            return [NSSortDescriptor(key: "updatedAt", ascending: ascending)]
        }
    }

    /// タグ側だけを管理オブジェクトとして取得する。関連カードはobjectIDだけを参照し、
    /// BusinessCardの属性（特にimageData）をフォールト発火させない。
    private nonisolated static func loadTags(
        for objectIDs: [NSManagedObjectID],
        context: NSManagedObjectContext
    ) throws -> [URL: [TagValue]] {
        guard !objectIDs.isEmpty else { return [:] }
        let selectedURIs = Set(objectIDs.map { $0.uriRepresentation() })
        let request = NSFetchRequest<NSManagedObject>(entityName: "Tag")
        request.predicate = NSPredicate(format: "ANY cards IN %@", objectIDs)
        request.fetchBatchSize = 100
        let tags = try context.fetch(request)
        var result: [URL: [TagValue]] = [:]

        for tag in tags {
            try Task.checkCancellation()
            let name = string(tag, key: "name")
            guard !name.isEmpty else { continue }
            let colorHex = string(tag, key: "colorHex")
            let value = TagValue(
                id: tag.value(forKey: "id") as? UUID,
                objectURI: tag.objectID.uriRepresentation().absoluteString,
                name: name,
                colorHex: colorHex.isEmpty ? "#007AFF" : colorHex
            )
            let relatedCards = (tag.value(forKey: "cards") as? NSSet)?.allObjects ?? []
            for case let card as NSManagedObject in relatedCards {
                let uri = card.objectID.uriRepresentation()
                guard selectedURIs.contains(uri) else { continue }
                result[uri, default: []].append(value)
            }
        }

        for uri in result.keys {
            result[uri]?.sort { $0.name < $1.name }
        }
        return result
    }

    private nonisolated static func makeLoadResult(
        fetched: [NSDictionary],
        orderedObjectURIs: [URL],
        tagsByCardURI: [URL: [TagValue]]
    ) throws -> CardListQuerySnapshotLoadResult {
        let cardsByURI = Dictionary(uniqueKeysWithValues: try fetched.map { values in
            guard let objectID = values[objectIDKey] as? NSManagedObjectID else {
                throw LoaderError.missingObjectID
            }
            return (objectID.uriRepresentation(), values)
        })
        var snapshots: [CardListQuerySnapshot] = []
        snapshots.reserveCapacity(orderedObjectURIs.count)
        var duplicateSnapshots: [DuplicateCardSnapshot] = []
        duplicateSnapshots.reserveCapacity(orderedObjectURIs.count)
        var revisions = Set<CardListCardRevision>()
        revisions.reserveCapacity(orderedObjectURIs.count)

        for (index, objectURI) in orderedObjectURIs.enumerated() {
            try Task.checkCancellation()
            guard let values = cardsByURI[objectURI] else { continue }
            let tags = tagsByCardURI[objectURI] ?? []
            snapshots.append(makeSnapshot(
                values: values,
                objectURI: objectURI,
                tags: tags,
                index: index
            ))
            duplicateSnapshots.append(makeDuplicateSnapshot(
                values: values,
                objectURI: objectURI
            ))
            revisions.insert(CardListCardRevision(
                objectURI: objectURI,
                updatedAt: values["updatedAt"] as? Date
            ))
        }
        return CardListQuerySnapshotLoadResult(
            orderedObjectURIs: orderedObjectURIs,
            snapshots: snapshots,
            duplicateSnapshots: duplicateSnapshots,
            revisions: revisions
        )
    }

    private nonisolated static func makeDuplicateSnapshot(
        values: NSDictionary,
        objectURI: URL
    ) -> DuplicateCardSnapshot {
        let lastName = string(values, key: "lastName").trimmingCharacters(in: .whitespaces)
        let firstName = string(values, key: "firstName").trimmingCharacters(in: .whitespaces)
        let company = string(values, key: "company")
        return DuplicateCardSnapshot(
            objectURI: objectURI.absoluteString,
            fullName: [lastName, firstName].filter { !$0.isEmpty }.joined(separator: " "),
            company: company,
            normalizedCompany: LegalEntityTerms.stripKanji(from: company),
            title: string(values, key: "title"),
            department: string(values, key: "department")
        )
    }

    private nonisolated static func makeSnapshot(
        values: NSDictionary,
        objectURI: URL,
        tags: [TagValue],
        index: Int
    ) -> CardListQuerySnapshot {
        let lastName = string(values, key: "lastName").trimmingCharacters(in: .whitespaces)
        let firstName = string(values, key: "firstName").trimmingCharacters(in: .whitespaces)
        let lastNameReading = string(values, key: "lastNameReading")
            .trimmingCharacters(in: .whitespaces)
        let firstNameReading = string(values, key: "firstNameReading")
            .trimmingCharacters(in: .whitespaces)
        let fullName = [lastName, firstName].filter { !$0.isEmpty }.joined(separator: " ")
        let fullNameReading = [lastNameReading, firstNameReading]
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        let company = string(values, key: "company")
        let companyReading = string(values, key: "companyReading")
            .trimmingCharacters(in: .whitespaces)
        let companySortKey = companyReading.isEmpty
            ? LegalEntityTerms.stripKanji(from: company)
            : companyReading
        let department = string(values, key: "department")
        let title = string(values, key: "title")
        let affiliation = [department, title].filter { !$0.isEmpty }.joined(separator: " ")
        let isFavorite = (values["isFavorite"] as? NSNumber)?.boolValue
            ?? (values["isFavorite"] as? Bool)
            ?? false
        let email = string(values, key: "email")
        let phone = string(values, key: "phone")
        let address = string(values, key: "address")
        let notes = string(values, key: "notes")
        let website = string(values, key: "website")
        let updatedAt = values["updatedAt"] as? Date
        let tagSnapshots = tags.map { tag in
            CardRowTagSnapshot(name: tag.name, colorHex: tag.colorHex)
        }
        let displayName = fullName.isEmpty ? "（名前なし）" : fullName
        var accessibilityParts = [fullName.isEmpty ? "名前なし" : fullName]
        if !company.isEmpty { accessibilityParts.append(company) }
        if isFavorite { accessibilityParts.append("お気に入り") }
        if !tagSnapshots.isEmpty {
            accessibilityParts.append("タグ: " + tagSnapshots.map(\.name).joined(separator: "、"))
        }
        let searchValues = [
            fullName,
            fullNameReading,
            company,
            companyReading,
            department,
            title,
            email,
            phone,
            address,
            website,
            notes,
        ]
        .filter { !$0.isEmpty }
        + tags.map(\.name)

        let nameSectionValue: String
        if !lastNameReading.isEmpty {
            nameSectionValue = lastNameReading
        } else if !lastName.isEmpty {
            nameSectionValue = lastName
        } else {
            nameSectionValue = firstName
        }
        let firstNameSortValue = firstNameReading.isEmpty ? firstName : firstNameReading

        return CardListQuerySnapshot(
            index: index,
            id: values["id"] as? UUID,
            row: CardRowDisplaySnapshot(
                displayName: displayName,
                company: company,
                affiliation: affiliation,
                isFavorite: isFavorite,
                firstTag: tagSnapshots.first,
                additionalTagCount: max(tagSnapshots.count - 1, 0),
                accessibilityLabel: accessibilityParts.joined(separator: "、")
            ),
            detail: CardDetailDisplaySnapshot(
                objectURI: objectURI,
                lastName: lastName,
                lastNameReading: lastNameReading,
                firstName: firstName,
                firstNameReading: firstNameReading,
                company: company,
                department: department,
                title: title,
                phone: phone,
                email: email,
                address: address,
                website: website,
                notes: notes,
                createdAt: values["createdAt"] as? Date,
                isFavorite: isFavorite,
                tags: tags.map {
                    CardDetailTagSnapshot(
                        id: $0.objectURI,
                        name: $0.name,
                        colorHex: $0.colorHex
                    )
                }
            ),
            searchValues: searchValues,
            tagIDs: Set(tags.compactMap(\.id)),
            aiSearch: (values["id"] as? UUID).map { id in
                AISearchCardSnapshot(
                    id: id,
                    fullName: fullName,
                    lastName: lastName,
                    firstName: firstName,
                    lastNameReading: lastNameReading,
                    firstNameReading: firstNameReading,
                    company: company,
                    department: department,
                    title: title,
                    address: address,
                    notes: notes,
                    tagNames: tagSnapshots.map(\.name),
                    hasPhone: !phone.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                    hasEmail: !email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                    createdAt: values["createdAt"] as? Date
                )
            },
            bulkAutoTag: BulkAutoTagCardSnapshot(
                objectURI: objectURI,
                updatedAt: updatedAt,
                cardInfo: AutoTagService.CardInfo(
                    company: company,
                    department: department,
                    title: title,
                    address: address,
                    email: email,
                    website: website
                )
            ),
            insights: InsightsCardSnapshot(
                company: company,
                department: department,
                title: title,
                address: address,
                createdAt: values["createdAt"] as? Date,
                hasEmail: !email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                hasPhone: !phone.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                hasTags: !tags.isEmpty,
                isFavorite: isFavorite
            ),
            nameSectionValue: nameSectionValue,
            companySectionValue: companySortKey,
            nameSortValue: nameSectionValue + firstNameSortValue,
            companySortValue: companySortKey + (lastNameReading.isEmpty ? lastName : lastNameReading),
            createdAt: values["createdAt"] as? Date,
            updatedAt: updatedAt
        )
    }

    private nonisolated static func string(_ object: NSManagedObject, key: String) -> String {
        object.value(forKey: key) as? String ?? ""
    }

    private nonisolated static func string(_ values: NSDictionary, key: String) -> String {
        values[key] as? String ?? ""
    }
}

// 名刺一覧画面のViewModel
@MainActor
class CardListViewModel: ObservableObject {

    enum TagMutationResult: Equatable {
        case success
        case failure(String)
    }

    /// 永続化操作用の管理オブジェクト。描画は`filteredCardItems`だけを購読する。
    private(set) var cards: [BusinessCard] = []
    /// 名刺の追加・更新・削除時だけ進む世代番号。並べ替えやViewの再評価では変化しない。
    @Published private(set) var cardsContentRevision = 0
    @Published var duplicatePairs: [DuplicatePair] = []
    @Published var exportItem: ExportItem? = nil
    @Published var errorMessage: String? = nil
    @Published var isImporting = false
    @Published var importResultMessage: String? = nil
    @Published var searchText: String = "" {
        didSet {
            invalidateSemanticSearchIfNeeded()
            // 検索解除ではViewが即座にセクション表示へ戻るため、空文字だけは待たせない。
            scheduleListUpdate(debounce: !normalizedSearchText.isEmpty)
        }
    }
    @Published private var listDisplaySnapshot = CardListDisplaySnapshot.loading
    var filteredCardItems: [CardListItemSnapshot] { listDisplaySnapshot.filteredItems }
    var isSemanticSearchInProgress: Bool { listDisplaySnapshot.isSemanticSearchInProgress }
    var semanticSearchMessage: String? { listDisplaySnapshot.semanticSearchMessage }
    @Published private(set) var recentSearches: [String] = []
    @Published private(set) var companySearchSuggestions: [String] = []
    @Published private(set) var tagSearchSuggestions: [String] = []
    var groupedCardItemSections: [CardListItemSection] {
        listDisplaySnapshot.groupedItemSections
    }
    /// 一覧の描画条件と結果は同じスナップショットから読む。
    /// 検索debounce中に新しい条件と古い結果を混在させないための表示専用状態。
    var isListDisplayReady: Bool { listDisplaySnapshot.isReady }
    var hasDisplayedCards: Bool { listDisplaySnapshot.sourceCount > 0 }
    var isDisplayedSearchActive: Bool { !listDisplaySnapshot.normalizedQuery.isEmpty }
    var isDisplayedFilterActive: Bool { listDisplaySnapshot.isFilterActive }
    var displayedExternalFilter: CardListExternalFilter? { listDisplaySnapshot.externalFilter }
    var displayedSortKey: CardSortKey { listDisplaySnapshot.sortKey }
    @Published var allTags: [Tag] = []
    @Published private(set) var tagDisplaySnapshots: [TagDisplaySnapshot] = []
    @Published var selectedTagIDs: Set<UUID> = []
    @Published var showFavoritesOnly: Bool = false
    @Published var externalFilter: CardListExternalFilter? {
        didSet {
            guard oldValue != externalFilter else { return }
            scheduleListUpdate(debounce: false)
        }
    }
    @Published var sortKey: CardSortKey {
        didSet { SettingsStore.shared.sortKey = sortKey.rawValue }
    }
    @Published var sortAscending: Bool {
        didSet { SettingsStore.shared.sortAscending = sortAscending }
    }

    // 検索中かどうか（セクション表示 vs フラット表示の切替に使用）
    var isSearchActive: Bool { !searchText.trimmingCharacters(in: .whitespaces).isEmpty }

    // フィルタが適用されているか
    var isFilterActive: Bool {
        showFavoritesOnly || !selectedTagIDs.isEmpty || externalFilter != nil
    }

    /// メニューからソートキーを選択する。
    /// キー変更時だけ、その種類に適した既定方向へ切り替える。
    func selectSortKey(_ key: CardSortKey) {
        guard sortKey != key else { return }
        sortKey = key
        sortAscending = (key == .name || key == .company)
        scheduleListUpdate(debounce: false)
    }

    /// メニュー上部の方向選択を反映する。
    func setSortAscending(_ ascending: Bool) {
        guard sortAscending != ascending else { return }
        sortAscending = ascending
        scheduleListUpdate(debounce: false)
    }

    // 既存呼び出しとの互換用：同じキーなら方向を反転する
    func toggleSort(key: CardSortKey) {
        if sortKey == key {
            setSortAscending(!sortAscending)
        } else {
            selectSortKey(key)
        }
    }

    private let context: NSManagedObjectContext
    private var cancellables = Set<AnyCancellable>()
    private var duplicateDetectionGeneration = UUID()
    private var duplicateDetectionTask: Task<Void, Never>?
    private var lastDuplicateDetectionRevisions: Set<CardRevision>?
    private var publishedCardRevisions: Set<CardRevision>?
    private var semanticSearchTask: Task<Void, Never>?
    private var semanticSearchQuery: String?
    private var semanticMatchedCardIDs: Set<UUID>?
    private var pendingSemanticSearchInProgress = false
    private var pendingSemanticSearchMessage: String?
    private let listQueryWorker = CardListQueryWorker()
    private let listQuerySnapshotLoader = CardListQuerySnapshotLoader()
    private let tagDisplaySnapshotLoader = TagDisplaySnapshotLoader()
    private let cardDataTransferWorker = CardDataTransferWorker()
    private let contactImportStoreWriter = ContactImportStoreWriter()
    private let bulkAutoTagWriter = BulkAutoTagWriter()
    private let searchDebounceDuration: Duration
    private var listQuerySnapshots: [CardListQuerySnapshot] = []
    private var listItems: [CardListItemSnapshot] = []
    private var listItemsByURI: [URL: CardListItemSnapshot] = [:]
    private var duplicateCardSnapshots: [DuplicateCardSnapshot] = []
    private var listQuerySnapshotGeneration = UUID()
    private var listQuerySnapshotLoadGeneration = UUID()
    private var listQuerySnapshotLoadTask: Task<Void, Never>?
    private var listQueryGeneration = UUID()
    private var listQueryTask: Task<Void, Never>?
    private var tagDisplaySnapshotLoadGeneration = UUID()
    private var tagDisplaySnapshotLoadTask: Task<Void, Never>?
    private var contextRefreshTask: Task<Void, Never>?
    private var contextRefreshDeferrals: Set<UUID> = []
    private var deferredCardsChanged = false
    private var deferredTagsChanged = false
    private var contactsExportTask: Task<Void, Never>?
    private var contactsExportGeneration = UUID()
    private var fileExportTask: Task<Void, Never>?
    private var fileExportGeneration = UUID()
    private var deleteAllCardsTask: Task<Void, Never>?
    private var deleteAllCardsGeneration = UUID()
    private var bulkAutoTagGeneration = UUID()
    private static let recentSearchesDefaultsKey = "cardSearchRecentQueries"

    private struct CardRevision: Hashable {
        let id: String
        let updatedAt: Date?
    }

    init(
        context: NSManagedObjectContext? = nil,
        searchDebounceDuration: Duration = .milliseconds(150)
    ) {
        self.searchDebounceDuration = searchDebounceDuration
        if let context = context {
            self.context = context
        } else if ProcessInfo.processInfo.arguments.contains("-UITestMode") {
            self.context = PersistenceController.preview.container.viewContext
        } else {
            self.context = PersistenceController.shared.container.viewContext
        }

        // SettingsStore から前回のソート設定を復元
        let settings = SettingsStore.shared
        self.sortKey = CardSortKey(rawValue: settings.sortKey) ?? .createdAt
        self.sortAscending = settings.sortAscending
        self.recentSearches = UserDefaults.standard.stringArray(
            forKey: Self.recentSearchesDefaultsKey
        ) ?? []

        fetchCards()
        fetchTags()
        assignInitialSortOrderIfNeeded()

        // 閾値が変わったら重複検出を再実行
        SettingsStore.shared.$duplicateThreshold
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.detectDuplicates() }
            .store(in: &cancellables)

        // CloudKitマージを含むMain Queue Context自身の変更だけを購読する。
        // Core Data通知は保存元contextのqueueで同期配信されるため、対象を限定した場合も
        // @MainActorのselfへ触れるsinkより前にMain RunLoopへ配送する。
        NotificationCenter.default.publisher(
            for: .NSManagedObjectContextObjectsDidChange,
            object: context
        )
            .receive(on: RunLoop.main)
            .sink { [weak self] notification in
                self?.scheduleContextRefresh(for: notification)
            }
            .store(in: &cancellables)
    }

    // MARK: - データ取得

    func fetchCards() {
        contextRefreshTask?.cancel()
        contextRefreshTask = nil
        performFetchCards()
    }

    /// sheet内の保存通知で予約された再取得を、dismiss完了まで保留する。
    /// 保存内容自体は管理Contextに反映済みで、再取得は一覧の並び・検索スナップショット更新用。
    func cancelPendingContextRefresh() {
        contextRefreshTask?.cancel()
        contextRefreshTask = nil
    }

    /// sheet 内の連続保存中は Core Data 通知による一覧再取得を保留する。
    /// 実 dismiss 完了時にトークンを閉じることで、遷移中の中間描画を避けて1回だけ更新する。
    func beginContextRefreshDeferral() -> UUID {
        let token = UUID()
        contextRefreshDeferrals.insert(token)
        cancelPendingContextRefresh()
        return token
    }

    /// - Parameter refreshCards: 呼び出し元で保存成功を確認できた場合に true。
    ///   通知がまだ届いていなくても最終状態を1回取得する。
    func endContextRefreshDeferral(_ token: UUID, refreshCards: Bool) {
        guard contextRefreshDeferrals.remove(token) != nil else { return }
        guard contextRefreshDeferrals.isEmpty else {
            deferredCardsChanged = deferredCardsChanged || refreshCards
            return
        }

        cancelPendingContextRefresh()
        let shouldFetchCards = refreshCards || deferredCardsChanged || deferredTagsChanged
        let shouldFetchTags = deferredTagsChanged
        deferredCardsChanged = false
        deferredTagsChanged = false

        if shouldFetchTags {
            fetchTags()
        }
        if shouldFetchCards {
            performFetchCards()
        }
    }

    private func performFetchCards() {
        listQuerySnapshotLoadTask?.cancel()
        listQueryTask?.cancel()
        listQueryGeneration = UUID()

        let generation = UUID()
        listQuerySnapshotLoadGeneration = generation
        guard let coordinator = context.persistentStoreCoordinator else {
            cards = []
            listQuerySnapshots = []
            listItems = []
            listItemsByURI = [:]
            companySearchSuggestions = []
            duplicateCardSnapshots = []
            listQuerySnapshotGeneration = generation
            listQuerySnapshotLoadTask = nil
            scheduleListUpdate(debounce: false)
            return
        }

        let coordinatorReference = PersistentStoreCoordinatorReference(coordinator: coordinator)
        let loader = listQuerySnapshotLoader
        let requestedSortKey = sortKey
        let requestedAscending = sortAscending
        listQuerySnapshotLoadTask = Task { [weak self] in
            do {
                let result = try await loader.loadAll(
                    sortKey: requestedSortKey,
                    ascending: requestedAscending,
                    coordinatorReference: coordinatorReference
                )
                guard !Task.isCancelled,
                      let self,
                      self.listQuerySnapshotLoadGeneration == generation else {
                    return
                }
                let fetchedCards = result.orderedObjectURIs.compactMap { objectURI -> BusinessCard? in
                    guard let objectID = coordinator.managedObjectID(forURIRepresentation: objectURI),
                          let card = self.context.object(with: objectID) as? BusinessCard,
                          !card.isDeleted else {
                        return nil
                    }
                    return card
                }
                guard fetchedCards.count == result.snapshots.count else { return }

                self.reconcileDisplaySnapshot(with: fetchedCards)
                self.publishListQuerySnapshot(
                    result,
                    cards: fetchedCards,
                    generation: generation,
                    replacingCards: true
                )
                self.listQuerySnapshotLoadTask = nil
            } catch is CancellationError {
                guard let self,
                      self.listQuerySnapshotLoadGeneration == generation else { return }
                self.listQuerySnapshotLoadTask = nil
                return
            } catch {
                guard let self,
                      self.listQuerySnapshotLoadGeneration == generation else { return }
                self.listQuerySnapshotLoadTask = nil
                AppLogger.persistence.error("名刺の取得に失敗しました: \(error)")
            }
        }
        // 検索・フィルター変更が同時に発生しても、このload完了後の最新条件だけを評価する。
        scheduleListUpdate(debounce: false)
    }

    // MARK: - お気に入り

    private func toggleFavorite(_ card: BusinessCard) {
        card.isFavorite.toggle()
        card.updatedAt = Date()
        save()
    }

    func toggleFavorite(objectURI: URL) {
        guard let card = card(for: objectURI) else { return }
        toggleFavorite(card)
    }

    /// 選択中のカードをすべてお気に入りに追加（すでに全てお気に入りなら全解除）
    func toggleBulkFavorite(objectURIs: Set<URL>) {
        let targets = cards.filter { objectURIs.contains($0.objectID.uriRepresentation()) }
        let allFavorited = targets.allSatisfy(\.isFavorite)
        for card in targets {
            card.isFavorite = !allFavorited
            card.updatedAt = Date()
        }
        save()
    }

    // MARK: - タグ管理

    func fetchTags() {
        let request = Tag.fetchRequest()
        request.sortDescriptors = [
            NSSortDescriptor(keyPath: \Tag.sortOrder, ascending: true),
            NSSortDescriptor(keyPath: \Tag.name, ascending: true),
        ]
        do {
            let fetchedTags = try context.fetch(request)
            allTags = fetchedTags
            tagSearchSuggestions = uniqueNonEmptyValues(
                fetchedTags.map(\.tagName),
                limit: 4
            )
            rebuildTagDisplaySnapshots(for: fetchedTags)
        } catch {
            AppLogger.persistence.error("タグの取得に失敗しました: \(error)")
        }
    }

    /// 進行中のタグ表示スナップショット生成をテスト・呼び出し元から待機する。
    func waitForPendingTagDisplaySnapshotRefresh() async {
        while let task = tagDisplaySnapshotLoadTask {
            let generation = tagDisplaySnapshotLoadGeneration
            await task.value

            // 待機中に新しい取得へ差し替わった場合は、その世代まで待つ。
            guard generation == tagDisplaySnapshotLoadGeneration,
                  tagDisplaySnapshotLoadTask == nil else {
                continue
            }
            return
        }
    }

    /// 明示的なタグ編集結果を、非同期の使用件数再集計を待たず即時反映する。
    /// 使用件数は既存値を維持し、新規タグだけは必ず0件から始まる。
    private func upsertImmediateTagDisplaySnapshot(
        for tag: Tag,
        name: String,
        colorHex: String,
        newTagUsageCount: Int? = nil
    ) {
        let objectURI = tag.objectID.uriRepresentation().absoluteString
        let existingIndex = tagDisplaySnapshots.firstIndex { $0.objectURI == objectURI }
        let usageCount = existingIndex.map { tagDisplaySnapshots[$0].usageCount }
            ?? newTagUsageCount
            ?? 0
        let snapshot = TagDisplaySnapshot(
            tagID: tag.id,
            objectURI: objectURI,
            name: name,
            colorHex: colorHex,
            usageCount: usageCount
        )

        if let existingIndex {
            tagDisplaySnapshots[existingIndex] = snapshot
        } else {
            tagDisplaySnapshots.append(snapshot)
        }
    }

    private func rebuildTagDisplaySnapshots(for fetchedTags: [Tag]) {
        tagDisplaySnapshotLoadTask?.cancel()
        let generation = UUID()
        tagDisplaySnapshotLoadGeneration = generation
        let orderedObjectURIs = fetchedTags.map { $0.objectID.uriRepresentation() }

        // 削除済みタグだけは即座に除外し、残りは新しい完全な値型配列が届くまで維持する。
        let existingByURI = Dictionary(uniqueKeysWithValues: tagDisplaySnapshots.map {
            ($0.objectURI, $0)
        })
        tagDisplaySnapshots = orderedObjectURIs.compactMap {
            existingByURI[$0.absoluteString]
        }

        guard let coordinator = context.persistentStoreCoordinator else {
            tagDisplaySnapshots = []
            tagDisplaySnapshotLoadTask = nil
            return
        }
        let coordinatorReference = PersistentStoreCoordinatorReference(coordinator: coordinator)
        let loader = tagDisplaySnapshotLoader

        tagDisplaySnapshotLoadTask = Task { [weak self] in
            do {
                let result = try await loader.load(
                    orderedObjectURIs: orderedObjectURIs,
                    coordinatorReference: coordinatorReference
                )
                try Task.checkCancellation()
                guard let self else { return }
                guard self.tagDisplaySnapshotLoadGeneration == generation else { return }
                guard result.orderedObjectURIs == orderedObjectURIs,
                      result.snapshots.count == orderedObjectURIs.count,
                      self.allTags.map({ $0.objectID.uriRepresentation() }) == orderedObjectURIs else {
                    self.tagDisplaySnapshotLoadTask = nil
                    return
                }
                self.tagDisplaySnapshots = result.snapshots
                self.tagDisplaySnapshotLoadTask = nil
            } catch is CancellationError {
                guard let self,
                      self.tagDisplaySnapshotLoadGeneration == generation else { return }
                self.tagDisplaySnapshotLoadTask = nil
                return
            } catch {
                guard let self,
                      self.tagDisplaySnapshotLoadGeneration == generation else { return }
                self.tagDisplaySnapshotLoadTask = nil
                AppLogger.persistence.error("タグ表示情報の取得に失敗しました: \(error)")
            }
        }
    }

    @discardableResult
    func createTag(name: String, colorHex: String) -> TagMutationResult {
        let tag = Tag(context: context)
        tag.id = UUID()
        tag.name = name
        tag.colorHex = colorHex
        tag.sortOrder = Int16(allTags.count)
        tag.createdAt = Date()
        do {
            try context.save()
            upsertImmediateTagDisplaySnapshot(
                for: tag,
                name: name,
                colorHex: colorHex,
                newTagUsageCount: 0
            )
            fetchTags()
            rebuildListQuerySnapshots()
            scheduleListUpdate(debounce: false)
            return .success
        } catch {
            context.rollback()
            fetchTags()
            return .failure("タグの作成に失敗しました: \(error.localizedDescription)")
        }
    }

    @discardableResult
    func updateTag(_ tag: Tag, name: String, colorHex: String) -> TagMutationResult {
        tag.name = name
        tag.colorHex = colorHex
        do {
            try context.save()
            upsertImmediateTagDisplaySnapshot(
                for: tag,
                name: name,
                colorHex: colorHex
            )
            fetchTags()
            rebuildListQuerySnapshots()
            scheduleListUpdate(debounce: false)
            return .success
        } catch {
            context.rollback()
            fetchTags()
            return .failure("タグの更新に失敗しました: \(error.localizedDescription)")
        }
    }

    /// ViewからNSManagedObjectを保持せず、表示スナップショットのURIだけでタグを更新する。
    @discardableResult
    func updateTag(
        objectURI: String,
        name: String,
        colorHex: String
    ) -> TagMutationResult {
        guard let tag = tag(forObjectURIString: objectURI) else {
            return .failure("対象のタグは削除されました。")
        }
        return updateTag(tag, name: name, colorHex: colorHex)
    }

    func deleteTag(_ tag: Tag) {
        let tagID = tag.id
        context.delete(tag)
        do {
            try context.save()
            if let tagID {
                selectedTagIDs.remove(tagID)
            }
            fetchTags()
            rebuildListQuerySnapshots()
            scheduleListUpdate(debounce: false)
        } catch {
            context.rollback()
            fetchTags()
            fetchCards()
            errorMessage = "タグの削除に失敗しました: \(error.localizedDescription)"
        }
    }

    /// ViewからNSManagedObjectを保持せず、表示スナップショットのURIだけでタグを削除する。
    func deleteTag(objectURI: String) {
        guard let tag = tag(forObjectURIString: objectURI) else {
            fetchTags()
            return
        }
        deleteTag(tag)
    }

    func moveTag(from source: IndexSet, to destination: Int) {
        var reordered = tagDisplaySnapshots
        reordered.move(fromOffsets: source, toOffset: destination)
        for (index, snapshot) in reordered.enumerated() {
            tag(forObjectURIString: snapshot.objectURI)?.sortOrder = Int16(index)
        }
        save()
        fetchTags()
    }

    /// マイグレーション後の初回起動時に既存タグへ sortOrder を採番
    func assignInitialSortOrderIfNeeded() {
        guard !allTags.isEmpty else { return }
        let allZero = allTags.allSatisfy { $0.sortOrder == 0 }
        guard allZero, allTags.count > 1 else { return }
        for (index, tag) in allTags.enumerated() {
            tag.sortOrder = Int16(index)
        }
        save()
        fetchTags()
    }

    func toggleTagFilter(_ tag: Tag) {
        guard let id = tag.id else { return }
        setTagFilter(tag, enabled: !selectedTagIDs.contains(id))
    }

    func setTagFilter(_ tag: Tag, enabled: Bool) {
        guard let id = tag.id else { return }
        setTagFilter(id: id, enabled: enabled)
    }

    /// フィルターUIがTagを直接保持しないための値型API。
    func setTagFilter(id: UUID, enabled: Bool) {
        if enabled {
            selectedTagIDs.insert(id)
        } else {
            selectedTagIDs.remove(id)
        }
        scheduleListUpdate(debounce: false)
    }

    private func tag(forObjectURIString objectURI: String) -> Tag? {
        guard let url = URL(string: objectURI),
              let objectID = context.persistentStoreCoordinator?
                .managedObjectID(forURIRepresentation: url),
              let object = try? context.existingObject(with: objectID),
              !object.isDeleted else {
            return nil
        }
        return object as? Tag
    }

    func toggleFavoritesFilter() {
        setFavoritesFilter(!showFavoritesOnly)
    }

    func setFavoritesFilter(_ enabled: Bool) {
        showFavoritesOnly = enabled
        scheduleListUpdate(debounce: false)
    }

    /// お気に入り・タグ・Insights由来の条件を一括解除する。
    func clearAllFilters() {
        showFavoritesOnly = false
        selectedTagIDs.removeAll()
        if externalFilter != nil {
            externalFilter = nil
        } else {
            scheduleListUpdate(debounce: false)
        }
    }

    // MARK: - 検索フィルタ

    /// 現在の検索語を通常検索と意味検索の共通入力として確定する。
    /// 単純語で通常検索がヒットしている場合は、不要なLLM推論を開始しない。
    func submitUnifiedSearch() {
        let query = normalizedSearchText
        guard !query.isEmpty else {
            cancelSemanticSearch()
            return
        }
        recordRecentSearch(query)
        semanticSearchTask?.cancel()
        semanticSearchQuery = nil
        semanticMatchedCardIDs = nil
        pendingSemanticSearchMessage = nil
        pendingSemanticSearchInProgress = false
        let lexicalSearchTask = scheduleListUpdate(debounce: false)

        semanticSearchTask = Task { [weak self] in
            guard let self else { return }
            // debounce 中の古い filteredCards ではなく、確定した通常検索結果で AI の要否を決める。
            await lexicalSearchTask.value
            guard !Task.isCancelled, self.normalizedSearchText == query else { return }
            guard self.shouldPerformSemanticSearch(for: query) else {
                self.pendingSemanticSearchMessage = nil
                return
            }

            // private contextで確定済みの値型だけを推論へ渡す。
            // 検索中に保存・削除が発生してもNSManagedObjectを跨いで保持しない。
            let candidateCards = self.listQuerySnapshots.compactMap(\.aiSearch)
            let candidateGeneration = self.listQuerySnapshotGeneration
            self.semanticSearchQuery = query
            self.semanticMatchedCardIDs = nil
            self.pendingSemanticSearchMessage = nil
            self.pendingSemanticSearchInProgress = true
            let progressTask = self.scheduleListUpdate(debounce: false)
            await progressTask.value
            guard !Task.isCancelled,
                  self.semanticSearchQuery == query,
                  self.normalizedSearchText == query else { return }
            let result = await AISearchService.shared.search(query: query, cards: candidateCards)
            guard !Task.isCancelled,
                  self.semanticSearchQuery == query,
                  self.normalizedSearchText == query,
                  self.listQuerySnapshotGeneration == candidateGeneration else { return }

            self.semanticMatchedCardIDs = Set(result.matchedCardIDs)
            self.pendingSemanticSearchMessage = result.text
            self.pendingSemanticSearchInProgress = false
            let resultTask = self.scheduleListUpdate(debounce: false)
            await resultTask.value
        }
    }

    /// 標準検索候補から選んだ語を通常検索と自然言語検索の共通入力へ反映する。
    func applySearchSuggestion(_ suggestion: String, submit: Bool = false) {
        searchText = suggestion
        if submit {
            submitUnifiedSearch()
        }
    }

    func clearRecentSearches() {
        recentSearches = []
        UserDefaults.standard.removeObject(forKey: Self.recentSearchesDefaultsKey)
    }

    func cancelSemanticSearch() {
        semanticSearchTask?.cancel()
        semanticSearchTask = nil
        semanticSearchQuery = nil
        semanticMatchedCardIDs = nil
        pendingSemanticSearchMessage = nil
        pendingSemanticSearchInProgress = false
        scheduleListUpdate(debounce: false)
    }

    /// 意味検索結果を現在の通常検索結果へ合流する。テストでも世代不一致を検証できるよう内部APIにする。
    func applySemanticSearchResults(_ ids: Set<UUID>, for query: String, message: String? = nil) {
        let normalizedQuery = normalize(query)
        guard normalizedQuery == normalizedSearchText else { return }
        semanticSearchTask?.cancel()
        semanticSearchTask = nil
        semanticSearchQuery = normalizedQuery
        semanticMatchedCardIDs = ids
        pendingSemanticSearchMessage = message
        pendingSemanticSearchInProgress = false
        scheduleListUpdate(debounce: false)
    }

    /// テストでは非同期検索結果の確定を待ち、UI と同じ世代破棄経路を検証する。
    func waitForPendingListUpdate() async {
        await listQuerySnapshotLoadTask?.value
        await listQueryTask?.value
    }

    func listItem(for objectURI: URL) -> CardListItemSnapshot? {
        listItemsByURI[objectURI]
    }

    @discardableResult
    private func scheduleListUpdate(debounce: Bool) -> Task<Void, Never> {
        listQueryTask?.cancel()
        let generation = UUID()
        listQueryGeneration = generation
        let worker = listQueryWorker
        let delay = searchDebounceDuration
        let snapshotLoadTask = listQuerySnapshotLoadTask

        let task = Task { [weak self] in
            if debounce {
                do {
                    try await Task.sleep(for: delay)
                } catch {
                    return
                }
            }
            await snapshotLoadTask?.value
            guard !Task.isCancelled,
                  let self,
                  self.listQueryGeneration == generation,
                  self.listQuerySnapshotLoadGeneration == self.listQuerySnapshotGeneration else {
                return
            }
            let request = self.makeListQueryRequest()
            guard !Task.isCancelled,
                  let result = await worker.evaluate(request),
                  !Task.isCancelled,
                  self.listQueryGeneration == generation,
                  self.listQuerySnapshotGeneration == request.snapshotGeneration,
                  self.cards.count == result.snapshotCount else {
                return
            }

            let filteredItems = result.filteredIndices.compactMap { index in
                self.listItems.indices.contains(index) ? self.listItems[index] : nil
            }
            let groupedItemSections = result.sections.map { section in
                CardListItemSection(
                    id: section.id,
                    title: section.title,
                    items: section.indices.compactMap { index in
                        self.listItems.indices.contains(index) ? self.listItems[index] : nil
                    }
                )
            }
            // 1つのPublished値として公開し、検索/グループ表示の中間状態を作らない。
            self.listDisplaySnapshot = CardListDisplaySnapshot(
                isReady: true,
                sourceCount: result.snapshotCount,
                sourceObjectURIs: Set(self.listItems.map(\.id)),
                normalizedQuery: request.normalizedQuery,
                isFilterActive: request.showFavoritesOnly
                    || !request.selectedTagIDs.isEmpty
                    || request.externalFilter != nil,
                externalFilter: request.externalFilter,
                sortKey: request.sortKey,
                isSemanticSearchInProgress: request.isSemanticSearchInProgress,
                semanticSearchMessage: request.semanticSearchMessage,
                filteredItems: filteredItems,
                groupedItemSections: groupedItemSections
            )
        }
        listQueryTask = task
        return task
    }

    private func makeListQueryRequest() -> CardListQueryRequest {
        CardListQueryRequest(
            snapshotGeneration: listQuerySnapshotGeneration,
            snapshots: listQuerySnapshots,
            normalizedQuery: normalizedSearchText,
            selectedTagIDs: selectedTagIDs,
            showFavoritesOnly: showFavoritesOnly,
            externalFilter: externalFilter,
            semanticQuery: semanticSearchQuery,
            semanticMatchedCardIDs: semanticMatchedCardIDs ?? [],
            isSemanticSearchInProgress: pendingSemanticSearchInProgress,
            semanticSearchMessage: pendingSemanticSearchMessage,
            sortKey: sortKey,
            sortAscending: sortAscending,
            now: Date()
        )
    }

    /// 管理オブジェクトの全属性・タグ走査はprivate queueへ委譲する。
    /// MainActorでは表示順のURIを確定し、完成した値型配列だけを一括反映する。
    private func rebuildListQuerySnapshots() {
        listQuerySnapshotLoadTask?.cancel()
        listQueryTask?.cancel()
        listQueryGeneration = UUID()

        let generation = UUID()
        listQuerySnapshotLoadGeneration = generation
        let orderedObjectURIs = cards.map { $0.objectID.uriRepresentation() }
        guard let coordinator = context.persistentStoreCoordinator else {
            listQuerySnapshots = []
            listItems = []
            listItemsByURI = [:]
            companySearchSuggestions = []
            duplicateCardSnapshots = []
            listQuerySnapshotGeneration = generation
            listQuerySnapshotLoadTask = nil
            scheduleListUpdate(debounce: false)
            return
        }
        let coordinatorReference = PersistentStoreCoordinatorReference(coordinator: coordinator)
        let loader = listQuerySnapshotLoader

        listQuerySnapshotLoadTask = Task { [weak self] in
            do {
                let result = try await loader.load(
                    orderedObjectURIs: orderedObjectURIs,
                    coordinatorReference: coordinatorReference
                )
                guard !Task.isCancelled,
                      let self,
                      self.listQuerySnapshotLoadGeneration == generation,
                      result.orderedObjectURIs == orderedObjectURIs,
                      result.snapshots.count == orderedObjectURIs.count,
                      self.cards.map({ $0.objectID.uriRepresentation() }) == orderedObjectURIs else {
                    return
                }

                self.publishListQuerySnapshot(
                    result,
                    cards: self.cards,
                    generation: generation
                )
                self.listQuerySnapshotLoadTask = nil
                self.scheduleListUpdate(debounce: false)
            } catch is CancellationError {
                return
            } catch {
                guard let self,
                      self.listQuerySnapshotLoadGeneration == generation else { return }
                self.listQuerySnapshotLoadTask = nil
                AppLogger.persistence.error("一覧検索データの取得に失敗しました: \(error)")
            }
        }
    }

    /// 同じ private-context 読み取りから作った検索値と行表示値を同時に公開する。
    /// `cards` と各 snapshot の index は同じ URI 順であることを呼び出し側が検証済み。
    private func publishListQuerySnapshot(
        _ result: CardListQuerySnapshotLoadResult,
        cards sourceCards: [BusinessCard],
        generation: UUID,
        replacingCards: Bool = false
    ) {
        listQuerySnapshots = result.snapshots
        duplicateCardSnapshots = result.duplicateSnapshots
        listItems = zip(sourceCards, result.snapshots).map { card, snapshot in
            CardListItemSnapshot(
                id: snapshot.detail.objectURI,
                row: snapshot.row,
                detail: snapshot.detail,
                imageIdentifier: CardImageCacheKey.businessCard(card)
            )
        }
        listItemsByURI = Dictionary(uniqueKeysWithValues: listItems.map { ($0.id, $0) })
        companySearchSuggestions = uniqueNonEmptyValues(
            result.snapshots.map(\.row.company),
            limit: 4
        )
        listQuerySnapshotGeneration = generation
        // 行表示値を先に揃えてから一覧をPublishし、CardRowの初回bodyで欠落値を見せない。
        if replacingCards {
            cards = sourceCards
        }
        let revisions = Set(result.revisions.map {
            CardRevision(id: $0.objectURI.absoluteString, updatedAt: $0.updatedAt)
        })
        publishCardsContentRevisionIfNeeded(revisions)
        detectDuplicatesIfCardsChanged(revisions, snapshots: result.duplicateSnapshots)
    }

    /// 非同期workerの完了待ち中に、削除・invalidate済みの管理オブジェクトを旧表示へ残さない。
    /// 新規挿入は次の完成スナップショットでまとめて表示する。
    private func reconcileDisplaySnapshot(with fetchedCards: [BusinessCard]) {
        guard listDisplaySnapshot.isReady else { return }
        let fetchedURIs = Set(fetchedCards.map { $0.objectID.uriRepresentation() })
        let remainingSourceURIs = listDisplaySnapshot.sourceObjectURIs.intersection(fetchedURIs)

        if remainingSourceURIs.isEmpty, !fetchedCards.isEmpty,
           !listDisplaySnapshot.sourceObjectURIs.isEmpty {
            listDisplaySnapshot = .loading
            return
        }

        let filteredItems = listDisplaySnapshot.filteredItems.filter {
            remainingSourceURIs.contains($0.id)
        }
        let groupedItemSections: [CardListItemSection] = listDisplaySnapshot.groupedItemSections.compactMap { section in
            let items = section.items.filter { remainingSourceURIs.contains($0.id) }
            guard !items.isEmpty else { return nil }
            return CardListItemSection(id: section.id, title: section.title, items: items)
        }
        listItemsByURI = listItemsByURI.filter { remainingSourceURIs.contains($0.key) }
        listDisplaySnapshot = CardListDisplaySnapshot(
            isReady: true,
            sourceCount: remainingSourceURIs.count,
            sourceObjectURIs: remainingSourceURIs,
            normalizedQuery: listDisplaySnapshot.normalizedQuery,
            isFilterActive: listDisplaySnapshot.isFilterActive,
            externalFilter: listDisplaySnapshot.externalFilter,
            sortKey: listDisplaySnapshot.sortKey,
            isSemanticSearchInProgress: listDisplaySnapshot.isSemanticSearchInProgress,
            semanticSearchMessage: listDisplaySnapshot.semanticSearchMessage,
            filteredItems: filteredItems,
            groupedItemSections: groupedItemSections
        )
    }

    /// Core Dataの変更通知を、一覧とタグの再取得へまとめる。
    /// Taskを1つだけ所有することで同じ同期変更から届く連続通知を集約する。
    private func scheduleContextRefresh(for notification: Notification) {
        guard let userInfo = notification.userInfo else { return }
        let changedObjects = [
            NSInsertedObjectsKey,
            NSUpdatedObjectsKey,
            NSDeletedObjectsKey,
            NSRefreshedObjectsKey,
            NSInvalidatedObjectsKey,
        ].reduce(into: Set<NSManagedObject>()) { result, key in
            result.formUnion(userInfo[key] as? Set<NSManagedObject> ?? [])
        }
        let invalidatedAll = (userInfo[NSInvalidatedAllObjectsKey] as? Bool) == true
        let cardsChanged = invalidatedAll || changedObjects.contains { $0 is BusinessCard }
        let tagsChanged = invalidatedAll || changedObjects.contains { $0 is Tag }
        guard cardsChanged || tagsChanged else { return }

        if !contextRefreshDeferrals.isEmpty {
            deferredCardsChanged = deferredCardsChanged || cardsChanged
            deferredTagsChanged = deferredTagsChanged || tagsChanged
            return
        }

        contextRefreshTask?.cancel()
        contextRefreshTask = Task { [weak self] in
            guard !Task.isCancelled, let self else { return }
            if tagsChanged {
                self.fetchTags()
            }
            if cardsChanged || tagsChanged {
                self.performFetchCards()
            }
            self.contextRefreshTask = nil
        }
    }

    /// テストから外部変更の反映完了を待つ。
    func waitForPendingContextRefresh() async {
        // receive(on:)でMain RunLoopへ予約済みのCore Data通知を先に処理する。
        // ここを待たずにcontextRefreshTaskだけを見ると、通知配送前のnilを完了と誤認する。
        await withCheckedContinuation { continuation in
            RunLoop.main.perform {
                continuation.resume()
            }
        }
        await contextRefreshTask?.value
        await waitForPendingListUpdate()
    }

    private var normalizedSearchText: String {
        normalize(searchText)
    }

    private func normalize(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }

    private func recordRecentSearch(_ query: String) {
        let displayQuery = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !displayQuery.isEmpty else { return }
        recentSearches.removeAll { normalize($0) == query }
        recentSearches.insert(displayQuery, at: 0)
        recentSearches = Array(recentSearches.prefix(6))
        UserDefaults.standard.set(recentSearches, forKey: Self.recentSearchesDefaultsKey)
    }

    private func uniqueNonEmptyValues(_ values: [String], limit: Int) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for value in values {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let key = normalize(trimmed)
            guard seen.insert(key).inserted else { continue }
            result.append(trimmed)
            if result.count == limit { break }
        }
        return result
    }

    private func invalidateSemanticSearchIfNeeded() {
        let query = normalizedSearchText
        guard semanticSearchQuery != nil, semanticSearchQuery != query else { return }
        semanticSearchTask?.cancel()
        semanticSearchTask = nil
        semanticSearchQuery = nil
        semanticMatchedCardIDs = nil
        pendingSemanticSearchMessage = nil
        pendingSemanticSearchInProgress = false
    }

    private func shouldPerformSemanticSearch(for query: String) -> Bool {
        if filteredCardItems.isEmpty { return true }
        let naturalLanguageCues = [
            "の人", "関係", "関連", "系", "担当", "会った", "もらった", "交換した",
            "先月", "今月", "去年", "未登録", "登録されていない", "がない", "お気に入り",
            "探して", "見つけて", "教えて"
        ]
        return naturalLanguageCues.contains { query.localizedCaseInsensitiveContains($0) }
            || query.split(whereSeparator: \.isWhitespace).count >= 2
    }

    func clearExternalFilter() {
        externalFilter = nil
    }

    // MARK: - 一括操作（選択モード）

    private func card(for objectURI: URL) -> BusinessCard? {
        guard let coordinator = context.persistentStoreCoordinator,
              let objectID = coordinator.managedObjectID(forURIRepresentation: objectURI),
              let object = try? context.existingObject(with: objectID),
              let card = object as? BusinessCard,
              !card.isDeleted else {
            return nil
        }
        return card
    }

    /// 編集フォームを開く瞬間だけ、URIからMainActor context上のオブジェクトを解決する。
    /// 一覧ViewはCore Dataの解決処理を持たず、表示中もオブジェクトを保持しない。
    func cardForEditing(objectURI: URL) -> BusinessCard? {
        card(for: objectURI)
    }

    private func cards(for objectURIs: Set<URL>) -> [BusinessCard] {
        objectURIs.compactMap(card(for:))
    }

    /// 一括タグ画面用に、private contextで作成済みのtag IDスナップショットから集計する。
    /// MainActorで選択カードのto-many relationshipを展開しない。
    func bulkTagAssignmentSummary(
        for objectURIs: Set<URL>
    ) -> BulkTagAssignmentSummary {
        let selected = listQuerySnapshots.filter {
            objectURIs.contains($0.detail.objectURI)
        }
        var countsByTagID: [UUID: Int] = [:]
        for snapshot in selected {
            for tagID in snapshot.tagIDs {
                countsByTagID[tagID, default: 0] += 1
            }
        }
        return BulkTagAssignmentSummary(
            selectedCardCount: selected.count,
            countsByTagID: countsByTagID
        )
    }

    func exportSelectedCSV(objectURIs: Set<URL>) {
        performExport(
            cards(for: objectURIs),
            label: "CSVエクスポート",
            format: .csv
        )
    }

    func exportSelectedVCard(objectURIs: Set<URL>) {
        performExport(
            cards(for: objectURIs),
            label: "vCardエクスポート",
            format: .vCard
        )
    }

    func addTagToCards(tag: Tag, objectURIs: Set<URL>) {
        for card in cards(for: objectURIs) {
            card.addToTags(tag)
            card.updatedAt = Date()
        }
        save()
    }

    /// 一括タグ画面がTagを保持しないための値型API。
    func addTagToCards(tagObjectURI: String, cardObjectURIs: Set<URL>) {
        guard let tag = tag(forObjectURIString: tagObjectURI) else {
            errorMessage = "対象のタグは削除されました。"
            fetchTags()
            return
        }
        addTagToCards(tag: tag, objectURIs: cardObjectURIs)
    }

    /// 一括タグ画面がTagを保持しないための値型API。
    func removeTagFromCards(tagObjectURI: String, cardObjectURIs: Set<URL>) {
        guard let tag = tag(forObjectURIString: tagObjectURI) else {
            errorMessage = "対象のタグは削除されました。"
            fetchTags()
            return
        }
        removeTagFromCards(tag: tag, objectURIs: cardObjectURIs)
    }

    func removeTagFromCards(tag: Tag, objectURIs: Set<URL>) {
        for card in cards(for: objectURIs) {
            card.removeFromTags(tag)
            card.updatedAt = Date()
        }
        save()
    }

    /// 選択カード全件に AI でタグを提案・付与する。Pro 限定。
    /// - Returns: (処理対象件数, 1 件以上タグが付与されたカード件数)
    func bulkAutoTag(objectURIs: Set<URL>) async -> (processed: Int, tagged: Int) {
        let selected = listQuerySnapshots
            .filter { objectURIs.contains($0.detail.objectURI) }
            .map(\.bulkAutoTag)
        return await bulkAutoTag(selected: selected)
    }

    private func bulkAutoTag(
        selected: [BulkAutoTagCardSnapshot]
    ) async -> (processed: Int, tagged: Int) {
        guard !selected.isEmpty, !tagDisplaySnapshots.isEmpty,
              let coordinator = context.persistentStoreCoordinator else { return (0, 0) }
        let tagInfos: [AutoTagService.TagInfo] = tagDisplaySnapshots.compactMap { tag in
            guard let id = tag.tagID else { return nil }
            return AutoTagService.TagInfo(id: id, name: tag.name)
        }
        guard !tagInfos.isEmpty else { return (0, 0) }

        let generation = UUID()
        bulkAutoTagGeneration = generation
        var suggestions: [BulkAutoTagSuggestion] = []
        suggestions.reserveCapacity(selected.count)

        for card in selected {
            guard !Task.isCancelled, bulkAutoTagGeneration == generation else {
                return (0, 0)
            }
            let suggested = await AutoTagService.shared.suggestTags(
                cardInfo: card.cardInfo,
                tags: tagInfos
            )
            guard !suggested.isEmpty else { continue }
            suggestions.append(BulkAutoTagSuggestion(
                objectURI: card.objectURI,
                expectedUpdatedAt: card.updatedAt,
                tagIDs: Set(suggested)
            ))
        }

        guard !Task.isCancelled, bulkAutoTagGeneration == generation else { return (0, 0) }
        do {
            let result = try await bulkAutoTagWriter.apply(
                suggestions: suggestions,
                coordinatorReference: PersistentStoreCoordinatorReference(coordinator: coordinator)
            )
            guard !Task.isCancelled, bulkAutoTagGeneration == generation else { return (0, 0) }

            // private writerで保存済みの対象だけを最新化し、完成状態を1回再取得する。
            for objectURI in result.updatedObjectURIs {
                guard let objectID = coordinator.managedObjectID(forURIRepresentation: objectURI),
                      let card = try? context.existingObject(with: objectID), !card.isDeleted else {
                    continue
                }
                context.refresh(card, mergeChanges: true)
            }
            performFetchCards()
            return (selected.count, result.updatedObjectURIs.count)
        } catch is CancellationError {
            return (0, 0)
        } catch {
            guard bulkAutoTagGeneration == generation else { return (0, 0) }
            errorMessage = "AIタグの一括反映に失敗しました: \(error.localizedDescription)"
            return (selected.count, 0)
        }
    }

    /// カード単体のタグトグル（コンテキストメニュー用）
    func toggleTag(_ tag: Tag, on card: BusinessCard) {
        let cardTags = card.tags as? Set<Tag> ?? []
        if cardTags.contains(tag) {
            card.removeFromTags(tag)
        } else {
            card.addToTags(tag)
        }
        card.updatedAt = Date()
        save()
    }

    // MARK: - 重複検出

    /// 重複検出。ルールベースは常に実行、AI 二次判定は Pro 限定。
    func detectDuplicates() {
        guard let revisions = publishedCardRevisions else { return }
        detectDuplicates(revisions: revisions, snapshots: duplicateCardSnapshots)
    }

    /// private contextで作成済みの値型だけを重複判定へ渡す。
    /// 全件のCore Data属性をMainActorで再走査しない。
    private func detectDuplicates(
        revisions: Set<CardRevision>,
        snapshots: [DuplicateCardSnapshot]
    ) {
        lastDuplicateDetectionRevisions = revisions
        let generation = UUID()
        duplicateDetectionGeneration = generation
        let checker = DuplicateChecker(threshold: SettingsStore.shared.duplicateThreshold)
        let shouldEnhanceWithAI = EntitlementStore.shared.hasAccess

        duplicateDetectionTask?.cancel()
        duplicateDetectionTask = Task { [weak self] in
            guard let scan = await checker.scanRuleBased(
                snapshots: snapshots,
                includeBorderline: shouldEnhanceWithAI
            ), !Task.isCancelled, let self,
                  generation == self.duplicateDetectionGeneration,
                  revisions == self.publishedCardRevisions else { return }

            // 全ペア比較の完了後だけ MainActor の表示状態へ反映する。
            self.duplicatePairs = scan.confirmed
            guard shouldEnhanceWithAI else { return }

            let enhanced = await checker.enhanceWithAI(scan)
            guard !Task.isCancelled,
                  generation == self.duplicateDetectionGeneration,
                  revisions == self.publishedCardRevisions else { return }
            self.duplicatePairs = enhanced
        }
    }

    /// 並べ替えだけでは重複判定を再実行せず、カード集合または更新日時が変わった時だけ更新する。
    private func detectDuplicatesIfCardsChanged(
        _ revisions: Set<CardRevision>,
        snapshots: [DuplicateCardSnapshot]
    ) {
        guard revisions != lastDuplicateDetectionRevisions else { return }
        detectDuplicates(revisions: revisions, snapshots: snapshots)
    }

    private func publishCardsContentRevisionIfNeeded(_ revisions: Set<CardRevision>) {
        guard revisions != publishedCardRevisions else { return }
        publishedCardRevisions = revisions
        cardsContentRevision &+= 1
    }

    // MARK: - エクスポート

    func exportCSV() {
        performExport(cards, label: "CSVエクスポート", format: .csv)
    }

    func exportVCard() {
        performExport(cards, label: "vCardエクスポート", format: .vCard)
    }

    private enum FileExportFormat {
        case csv
        case vCard
    }

    private func performExport(
        _ cards: [BusinessCard],
        label: String,
        format: FileExportFormat
    ) {
        guard !cards.isEmpty else { return }
        guard let coordinator = context.persistentStoreCoordinator else {
            errorMessage = "\(label)に失敗しました: \(CardDataTransferError.missingPersistentStore.localizedDescription)"
            return
        }
        let cardIDsByURI = Dictionary(uniqueKeysWithValues: listQuerySnapshots.compactMap { snapshot in
            snapshot.id.map { (snapshot.bulkAutoTag.objectURI, $0) }
        })
        let orderedCardIDs = cards.compactMap {
            cardIDsByURI[$0.objectID.uriRepresentation()]
        }
        guard orderedCardIDs.count == cards.count else {
            errorMessage = "\(label)に失敗しました: \(CardDataTransferError.objectNotFound.localizedDescription)"
            return
        }
        let coordinatorReference = PersistentStoreCoordinatorReference(coordinator: coordinator)
        let generation = UUID()
        fileExportGeneration = generation
        fileExportTask?.cancel()
        fileExportTask = Task { [weak self] in
            guard let self else { return }
            do {
                let dtos = try await cardDataTransferWorker.loadCards(
                    orderedCardIDs: orderedCardIDs,
                    coordinatorReference: coordinatorReference
                )
                try Task.checkCancellation()
                let url: URL
                switch format {
                case .csv:
                    url = try await ExportService.shared.exportCSVInBackground(from: dtos)
                case .vCard:
                    url = try await ExportService.shared.exportVCardInBackground(from: dtos)
                }
                guard !Task.isCancelled, fileExportGeneration == generation else { return }
                exportItem = ExportItem(url: url)
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled, fileExportGeneration == generation else { return }
                errorMessage = "\(label)に失敗しました: \(error.localizedDescription)"
            }
            guard fileExportGeneration == generation else { return }
            fileExportTask = nil
        }
    }

    // MARK: - コンテキストメニューアクション

    func shareVCard(card: BusinessCard) {
        performExport([card], label: "vCardの生成", format: .vCard)
    }

    func shareVCard(objectURI: URL) {
        guard let card = card(for: objectURI) else {
            errorMessage = CardDataTransferError.objectNotFound.localizedDescription
            return
        }
        performExport([card], label: "vCardの生成", format: .vCard)
    }

    func saveToContacts(card: BusinessCard) {
        guard let coordinator = context.persistentStoreCoordinator else {
            errorMessage = CardDataTransferError.missingPersistentStore.localizedDescription
            return
        }
        startContactsExport(
            request: ContactExportRequest(
                objectURI: card.objectID.uriRepresentation(),
                coordinatorReference: PersistentStoreCoordinatorReference(coordinator: coordinator)
            )
        )
    }

    private func startContactsExport(request: ContactExportRequest) {
        let generation = UUID()
        contactsExportGeneration = generation
        contactsExportTask?.cancel()
        contactsExportTask = Task { [weak self] in
            do {
                try await ContactsService.shared.export(request: request)
                guard !Task.isCancelled,
                      self?.contactsExportGeneration == generation else { return }
            } catch is CancellationError {
                guard self?.contactsExportGeneration == generation else { return }
                self?.contactsExportTask = nil
                return
            } catch {
                guard !Task.isCancelled,
                      self?.contactsExportGeneration == generation else { return }
                self?.errorMessage = error.localizedDescription
            }
            guard self?.contactsExportGeneration == generation else { return }
            self?.contactsExportTask = nil
        }
    }

    func saveToContacts(objectURI: URL) {
        guard let coordinator = context.persistentStoreCoordinator else {
            errorMessage = CardDataTransferError.missingPersistentStore.localizedDescription
            return
        }
        startContactsExport(
            request: ContactExportRequest(
                objectURI: objectURI,
                coordinatorReference: PersistentStoreCoordinatorReference(coordinator: coordinator)
            )
        )
    }

    // MARK: - 連絡先からインポート

    func importFromContacts() async {
        guard !isImporting else { return }
        isImporting = true
        defer { isImporting = false }
        do {
            let contacts = try await ContactsService.shared.importContacts()
            try Task.checkCancellation()
            guard let coordinator = context.persistentStoreCoordinator else {
                throw CardDataTransferError.missingPersistentStore
            }
            let count = try await contactImportStoreWriter.insert(
                contacts: contacts,
                coordinatorReference: PersistentStoreCoordinatorReference(coordinator: coordinator)
            )
            try Task.checkCancellation()
            fetchCards()
            importResultMessage = "\(count)件の連絡先をインポートしました"
        } catch is CancellationError {
            return
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - 削除

    func deleteCards(_ cardsToDelete: [BusinessCard]) {
        cardsToDelete.forEach { context.delete($0) }
        save()
    }

    /// View層は管理オブジェクトを保持せず、安定したobject URIだけを渡す。
    func deleteCards(objectURIs: Set<URL>) {
        let resolvedCards = cards(for: objectURIs)
        guard !resolvedCards.isEmpty else { return }
        deleteCards(resolvedCards)
    }

    // MARK: - 全削除

    func deleteAllCards() {
        guard let coordinator = context.persistentStoreCoordinator else {
            errorMessage = "削除に失敗しました: \(CardDataTransferError.missingPersistentStore.localizedDescription)"
            return
        }
        let coordinatorReference = PersistentStoreCoordinatorReference(coordinator: coordinator)
        let generation = UUID()
        deleteAllCardsGeneration = generation
        deleteAllCardsTask?.cancel()
        deleteAllCardsTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await contactImportStoreWriter.deleteAll(
                    coordinatorReference: coordinatorReference
                )
                guard !Task.isCancelled, deleteAllCardsGeneration == generation else { return }
                fetchCards()
            } catch is CancellationError {
                guard deleteAllCardsGeneration == generation else { return }
                deleteAllCardsTask = nil
                return
            } catch {
                guard !Task.isCancelled, deleteAllCardsGeneration == generation else { return }
                errorMessage = "削除に失敗しました: \(error.localizedDescription)"
            }
            guard deleteAllCardsGeneration == generation else { return }
            deleteAllCardsTask = nil
        }
    }

    /// テストからprivate writerと最終一覧更新の完了を待つ。
    func waitForPendingDataMutation() async {
        await deleteAllCardsTask?.value
        await waitForPendingListUpdate()
    }

    // MARK: - 保存

    private func save() {
        do {
            try context.save()
            fetchCards()
        } catch {
            context.rollback()
            fetchCards()
            fetchTags()
            errorMessage = "保存に失敗しました: \(error.localizedDescription)"
        }
    }

    // MARK: - デバッグ用

#if DEBUG
    func seedSampleData() {
        let cal = Calendar.current
        let now = Date()

        typealias Entry = (
            lastName: String, lastNameReading: String,
            firstName: String, firstNameReading: String,
            company: String, companyReading: String,
            department: String, title: String,
            email: String, phone: String, address: String, website: String,
            daysAgo: Int
        )

        let entries: [Entry] = [
            // ── 今日（5件）────────────────────────────
            ("山田", "やまだ",   "太郎",   "たろう",       "株式会社アルファテック",           "あるふぁてっく",
             "営業部",           "営業部長",                 "yamada@alphatech.co.jp",    "03-1234-5678", "東京都渋谷区道玄坂1-2-3",             "https://alphatech.co.jp",    0),
            ("佐藤", "さとう",   "花子",   "はなこ",       "ベータシステムズ株式会社",         "べーたしすてむず",
             "開発部",           "シニアエンジニア",         "sato@betasys.co.jp",        "06-2345-6789", "大阪府大阪市北区梅田2-3-4",           "https://betasys.co.jp",      0),
            ("鈴木", "すずき",   "一郎",   "いちろう",     "ガンマ商事株式会社",               "がんましょうじ",
             "経営企画室",       "代表取締役社長",           "suzuki@gamma-trading.jp",   "052-345-6789", "愛知県名古屋市中区栄3-4-5",           "https://gamma-trading.jp",   0),
            ("田中", "たなか",   "美咲",   "みさき",       "デルタデザイン合同会社",           "でるたでざいん",
             "クリエイティブ部", "UIデザイナー",             "tanaka@delta-design.com",   "011-456-7890", "北海道札幌市中央区大通西1-2",         "https://delta-design.com",   0),
            ("高橋", "たかはし", "健司",   "けんじ",       "イプシロン医療株式会社",           "いぷしろんいりょう",
             "医療情報部",       "システム課長",             "takahashi@epsilon-med.jp",  "092-567-8901", "福岡県福岡市博多区博多駅前1-1-1",     "https://epsilon-med.jp",     0),

            // ── 今週（10件）──────────────────────────
            ("伊藤", "いとう",   "真由",   "まゆ",         "ゼータファイナンス株式会社",       "ぜーたふぁいなんす",
             "財務部",           "主任",                     "ito@zeta-finance.co.jp",    "03-2345-6789", "東京都千代田区丸の内1-5-6",           "https://zeta-finance.co.jp", 2),
            ("渡辺", "わたなべ", "拓也",   "たくや",       "エータ教育株式会社",               "えーたきょういく",
             "コンテンツ部",     "コンテンツディレクター",   "watanabe@eta-edu.jp",       "045-678-9012", "神奈川県横浜市西区みなとみらい2-3",   "https://eta-edu.jp",         2),
            ("中村", "なかむら", "さくら", "さくら",       "シータ建設株式会社",               "しーたけんせつ",
             "設計部",           "一級建築士",               "nakamura@theta-const.co.jp","022-789-0123", "宮城県仙台市青葉区一番町4-5-6",       "https://theta-const.co.jp",  3),
            ("小林", "こばやし", "剛",     "つよし",       "イオタ物流株式会社",               "いおたぶつりゅう",
             "物流管理部",       "部長",                     "kobayashi@iota-logi.jp",    "082-890-1234", "広島県広島市中区紙屋町1-3-5",         "https://iota-logi.jp",       3),
            ("加藤", "かとう",   "奈々",   "なな",         "カッパ出版株式会社",               "かっぱしゅっぱん",
             "編集部",           "編集長",                   "kato@kappa-pub.co.jp",      "03-3456-7890", "東京都文京区本郷3-7-8",               "https://kappa-pub.co.jp",    4),
            ("松本", "まつもと", "浩二",   "こうじ",       "ラムダコンサルティング株式会社",   "らむだこんさるてぃんぐ",
             "戦略部",           "シニアコンサルタント",     "matsumoto@lambda-cons.jp",  "03-4567-8901", "東京都港区赤坂2-4-6",                 "https://lambda-cons.jp",     4),
            ("井上", "いのうえ", "千恵",   "ちえ",         "ミューインシュアランス株式会社",   "みゅーいんしゅあらんす",
             "損害保険部",       "営業課長",                 "inoue@mu-insurance.co.jp",  "06-3456-7890", "大阪府大阪市中央区本町3-5-7",         "https://mu-insurance.co.jp", 4),
            ("木村", "きむら",   "亮",     "りょう",       "ニューメディア株式会社",           "にゅーめでぃあ",
             "広告部",           "クリエイティブディレクター","kimura@nu-media.co.jp",    "03-5678-9012", "東京都新宿区西新宿6-7-8",             "https://nu-media.co.jp",     5),
            ("林",   "はやし",   "明美",   "あけみ",       "クシー食品株式会社",               "くしーしょくひん",
             "商品開発部",       "研究員",                   "hayashi@xi-foods.co.jp",    "054-901-2345", "静岡県静岡市葵区追手町1-2",           "https://xi-foods.co.jp",     5),
            ("清水", "しみず",   "大輔",   "だいすけ",     "オミクロンソフト株式会社",         "おみくろんそふと",
             "開発2部",          "テックリード",             "shimizu@omicron-soft.jp",   "03-6789-0123", "東京都品川区大崎1-8-9",               "https://omicron-soft.jp",    5),

            // ── 今月（15件）──────────────────────────
            ("山口", "やまぐち", "恵子",   "けいこ",       "パイコンサルタンツ株式会社",       "ぱいこんさるたんつ",
             "人事部",           "人事部長",                 "yamaguchi@pi-consult.co.jp","03-7890-1234", "東京都千代田区霞が関3-1-2",           "https://pi-consult.co.jp",   8),
            ("斎藤", "さいとう", "直樹",   "なおき",       "ローエナジー株式会社",             "ろーえなじー",
             "技術部",           "技術部長",                 "saito@rho-energy.jp",       "011-234-5678", "北海道札幌市豊平区月寒東1-1-1",       "https://rho-energy.jp",      9),
            ("松田", "まつだ",   "由美",   "ゆみ",         "シグマアパレル株式会社",           "しぐまあぱれる",
             "デザイン部",       "パタンナー",               "matsuda@sigma-apparel.jp",  "06-4567-8901", "大阪府大阪市浪速区難波中2-3-4",       "https://sigma-apparel.jp",   10),
            ("藤田", "ふじた",   "正人",   "まさと",       "タウリクス株式会社",               "たうりくす",
             "製品部",           "プロダクトマネージャー",   "fujita@taurix.co.jp",       "03-8901-2345", "東京都台東区上野7-8-9",               "https://taurix.co.jp",       11),
            ("岡田", "おかだ",   "麻衣",   "まい",         "ウプシロン保険有限会社",           "うぷしろんほけん",
             "総務部",           "総務課長",                 "okada@upsilon-ins.jp",      "052-678-9012", "愛知県名古屋市東区葵1-5-7",           "https://upsilon-ins.jp",     12),
            ("後藤", "ごとう",   "博",     "ひろし",       "ファイテック株式会社",             "ふぁいてっく",
             "品質管理部",       "QAエンジニア",             "goto@phitech.co.jp",        "075-345-6789", "京都府京都市下京区四条通1-2-3",       "https://phitech.co.jp",      12),
            ("村田", "むらた",   "友美",   "ともみ",       "カイアドバンス株式会社",           "かいあどばんす",
             "マーケティング部", "マーケティングマネージャー","murata@chi-advance.jp",    "03-9012-3456", "東京都墨田区押上1-1-2",               "https://chi-advance.jp",     13),
            ("坂本", "さかもと", "哲也",   "てつや",       "プサイテクノロジー株式会社",       "ぷさいてくのろじー",
             "AI研究部",         "主任研究員",               "sakamoto@psi-tech.co.jp",   "06-5678-9012", "大阪府吹田市江坂町1-2-3",             "https://psi-tech.co.jp",     14),
            ("橋本", "はしもと", "百合子", "ゆりこ",       "オメガリテール株式会社",           "おめがりてーる",
             "店舗開発部",       "エリアマネージャー",       "hashimoto@omega-retail.jp", "098-456-7890", "沖縄県那覇市久茂地1-3-5",             "https://omega-retail.jp",    15),
            ("石田", "いしだ",   "修",     "おさむ",       "アルゴリズム株式会社",             "あるごりずむ",
             "データ分析部",     "データサイエンティスト",   "ishida@algorithm.co.jp",    "03-0123-4567", "東京都中野区中野4-5-6",               "https://algorithm.co.jp",    16),
            ("藤井", "ふじい",   "香織",   "かおり",       "バイオサイエンス株式会社",         "ばいおさいえんす",
             "研究開発部",       "研究員",                   "fujii@bioscience.co.jp",    "078-567-8901", "兵庫県神戸市中央区三宮町2-4-6",       "https://bioscience.co.jp",   17),
            ("前田", "まえだ",   "慎一",   "しんいち",     "クラウドネット株式会社",           "くらうどねっと",
             "インフラ部",       "インフラエンジニア",       "maeda@cloudnet.jp",         "03-1357-2468", "東京都豊島区池袋2-3-4",               "https://cloudnet.jp",        18),
            ("小川", "おがわ",   "雅子",   "まさこ",       "デジタルウェーブ合同会社",         "でじたるうぇーぶ",
             "事業開発部",       "ビジネスデベロッパー",     "ogawa@digitalwave.co.jp",   "06-6789-0123", "大阪府堺市堺区市之町東1-2",           "https://digitalwave.co.jp",  19),
            ("池田", "いけだ",   "俊",     "しゅん",       "エコソリューションズ株式会社",     "えこそりゅーしょんず",
             "環境部",           "環境コンサルタント",       "ikeda@eco-solutions.jp",    "082-234-5678", "広島県広島市南区宇品海岸3-1-2",       "https://eco-solutions.jp",   20),
            ("西村", "にしむら", "綾",     "あや",         "グローバルリンク株式会社",         "ぐろーばるりんく",
             "国際事業部",       "海外営業マネージャー",     "nishimura@globallink.co.jp","03-2468-1357", "東京都江東区木場3-4-5",               "https://globallink.co.jp",   20),

            // ── 3ヶ月以内（10件）─────────────────────
            ("岡本", "おかもと", "裕之",   "ひろゆき",     "サイバーロジック株式会社",         "さいばーろじっく",
             "セキュリティ部",   "セキュリティエンジニア",   "okamoto@cyberlogic.co.jp",  "03-3579-2468", "東京都新宿区四谷1-2-3",               "https://cyberlogic.co.jp",   40),
            ("吉田", "よしだ",   "典子",   "のりこ",       "スマートホーム有限会社",           "すまーとほーむ",
             "製品部",           "IoTエンジニア",            "yoshida@smarthome.jp",      "052-890-1234", "愛知県名古屋市千種区今池3-5-7",       "https://smarthome.jp",       45),
            ("山本", "やまもと", "誠",     "まこと",       "フィンテックジャパン株式会社",     "ふぃんてっくじゃぱん",
             "決済サービス部",   "プロジェクトマネージャー", "yamamoto@fintechjp.co.jp",  "03-4680-1357", "東京都中央区日本橋室町1-5-6",         "https://fintechjp.co.jp",    50),
            ("中島", "なかじま", "瑠衣",   "るい",         "ヘルスケアテック株式会社",         "へるすけあてっく",
             "臨床開発部",       "臨床開発マネージャー",     "nakajima@healthtech.jp",    "06-7890-1234", "大阪府大阪市此花区桜島1-1-1",         "https://healthtech.jp",      55),
            ("野口", "のぐち",   "徹",     "とおる",       "モビリティソリューション株式会社", "もびりてぃそりゅーしょん",
             "EV開発部",         "シニアエンジニア",         "noguchi@mobility-sol.co.jp","045-901-2345", "神奈川県横浜市鶴見区鶴見中央2-3",     "https://mobility-sol.co.jp", 55),
            ("原田", "はらだ",   "美穂",   "みほ",         "エドテックラボ合同会社",           "えどてっくらぼ",
             "教育コンテンツ部", "カリキュラムデザイナー",   "harada@edtechlab.jp",       "03-5791-2468", "東京都世田谷区三軒茶屋2-4-6",         "https://edtechlab.jp",       60),
            ("川口", "かわぐち", "雄大",   "ゆうだい",     "スペースベンチャー株式会社",       "すぺーすべんちゃー",
             "宇宙開発部",       "宇宙機エンジニア",         "kawaguchi@spaceventure.jp", "029-234-5678", "茨城県つくば市研究学園5-6-7",         "https://spaceventure.jp",    60),
            ("村上", "むらかみ", "朋子",   "ともこ",       "アグリテック株式会社",             "あぐりてっく",
             "農業DX部",         "農業ICTコンサルタント",    "murakami@agritech.co.jp",   "011-567-8901", "北海道帯広市西2条南5-1",              "https://agritech.co.jp",     65),
            ("横山", "よこやま", "智也",   "ともや",       "ソーシャルインパクト株式会社",     "そーしゃるいんぱくと",
             "事業推進部",       "事業推進マネージャー",     "yokoyama@socialimpact.jp",  "06-8901-2345", "大阪府大阪市西区靱本町1-2-3",         "https://socialimpact.jp",    68),
            ("石川", "いしかわ", "えみ",   "えみ",         "クリエイティブスタジオ有限会社",   "くりえいてぃぶすたじお",
             "映像制作部",       "ビデオプロデューサー",     "ishikawa@cstudio.co.jp",    "03-6802-4689", "東京都杉並区阿佐ヶ谷北3-5-7",         "https://cstudio.co.jp",      70),

            // ── それ以前（10件）──────────────────────
            ("三浦", "みうら",   "伸介",   "しんすけ",     "レガシーシステムズ株式会社",       "れがしーしすてむず",
             "システム部",       "IT部長",                   "miura@legacysys.co.jp",     "03-7913-5791", "東京都大田区蒲田4-5-6",               "https://legacysys.co.jp",   100),
            ("西田", "にしだ",   "久美子", "くみこ",       "パシフィックトレード株式会社",     "ぱしふぃっくとれーど",
             "貿易部",           "貿易事務マネージャー",     "nishida@pacific-trade.jp",  "06-9012-3456", "大阪府大阪市港区弁天1-3-5",           "https://pacific-trade.jp",  110),
            ("菊池", "きくち",   "大樹",   "だいき",       "ノーザンソフト株式会社",           "のーざんそふと",
             "開発部",           "フルスタックエンジニア",   "kikuchi@northernsoft.co.jp","011-678-9012", "北海道函館市若松町2-4",               "https://northernsoft.co.jp", 120),
            ("長谷川","はせがわ", "遥",    "はるか",       "センチュリー不動産株式会社",       "せんちゅりーふどうさん",
             "賃貸管理部",       "管理課長",                 "hasegawa@century-re.jp",    "03-8024-6802", "東京都港区麻布十番1-2-3",             "https://century-re.jp",     130),
            ("福田", "ふくだ",   "義雄",   "よしお",       "ウエスタンフード株式会社",         "うえすたんふーど",
             "生産管理部",       "工場長",                   "fukuda@western-food.co.jp", "086-345-6789", "岡山県岡山市北区奉還町1-5-7",         "https://western-food.co.jp", 140),
            ("近藤", "こんどう", "恵",     "めぐみ",       "メトロポリスバンク株式会社",       "めとろぽりすばんく",
             "法人営業部",       "上席営業部長",             "kondo@metropolis-bk.co.jp", "03-9135-7913", "東京都千代田区大手町2-6-8",           "https://metropolis-bk.co.jp",150),
            ("土屋", "つちや",   "宗一郎", "そういちろう", "スターライトエンタメ株式会社",     "すたーらいとえんため",
             "コンテンツ制作部", "プロデューサー",           "tsuchiya@starlight-ent.jp", "03-0246-8024", "東京都渋谷区神南1-4-6",               "https://starlight-ent.jp",  160),
            ("浜田", "はまだ",   "貴子",   "たかこ",       "ノードネットワーク株式会社",       "のーどねっとわーく",
             "ネットワーク部",   "ネットワークアーキテクト", "hamada@nodenet.co.jp",      "06-0123-4567", "大阪府大阪市都島区都島本通1-2-3",     "https://nodenet.co.jp",     170),
            ("桑原", "くわはら", "亮太",   "りょうた",     "テラバイトストレージ株式会社",     "てらばいとすとれーじ",
             "ストレージ部",     "ストレージエンジニア",     "kuwahara@terabyte-st.co.jp","03-1358-2469", "東京都江戸川区西葛西6-7-8",           "https://terabyte-st.co.jp", 180),
            ("矢野", "やの",     "裕子",   "ゆうこ",       "グリーンビルディング合同会社",     "ぐりーんびるでぃんぐ",
             "環境設計部",       "環境建築家",               "yano@greenbuild.jp",        "03-2469-3580", "東京都目黒区自由が丘1-2-3",           "https://greenbuild.jp",     200),
        ]

        for entry in entries {
            let card = BusinessCard(context: context)
            card.id               = UUID()
            card.lastName         = entry.lastName
            card.lastNameReading  = entry.lastNameReading
            card.firstName        = entry.firstName
            card.firstNameReading = entry.firstNameReading
            card.company          = entry.company
            card.companyReading   = entry.companyReading
            card.department       = entry.department
            card.title            = entry.title
            card.email            = entry.email
            card.phone            = entry.phone
            card.address          = entry.address
            card.website          = entry.website
            let date = cal.date(byAdding: .day, value: -entry.daysAgo, to: now) ?? now
            card.createdAt        = date
            card.updatedAt        = date
        }
        save()
    }
#endif
}
