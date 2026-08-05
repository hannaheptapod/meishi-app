import SwiftUI
import UIKit

// MARK: - セクションインデックス

nonisolated enum SectionIndexSelection {
    static func adjustedIndex(current: Int, itemCount: Int, delta: Int) -> Int? {
        guard itemCount > 0 else { return nil }
        let clampedCurrent = min(max(current, 0), itemCount - 1)
        return min(max(clampedCurrent + delta, 0), itemCount - 1)
    }

    /// 指定セクションが空の場合に、表示順上で最も近い実在セクションを返す。
    /// ViewのDragGesture内でCore Data由来のsection配列を毎回走査しないよう、
    /// 呼び出し側で一度作ったSetだけを受け取る。
    static func nearestSectionID(
        to requestedID: String,
        orderedIDs: [String],
        existingIDs: Set<String>
    ) -> String? {
        if existingIDs.contains(requestedID) { return requestedID }
        guard !orderedIDs.isEmpty,
              let index = orderedIDs.firstIndex(of: requestedID) else { return nil }

        for offset in 1...orderedIDs.count {
            let previous = index - offset
            if previous >= 0, existingIDs.contains(orderedIDs[previous]) {
                return orderedIDs[previous]
            }
            let next = index + offset
            if next < orderedIDs.count, existingIDs.contains(orderedIDs[next]) {
                return orderedIDs[next]
            }
        }
        return nil
    }

    /// 一覧の上下端を必ず残しつつ、指定件数に収まるインデックスを返す。
    /// 空配列や極端に小さい表示領域でも、View側で先頭・末尾を強制参照しない。
    static func thinnedIndices(itemCount: Int, maximumCount: Int) -> [Int] {
        guard itemCount > 0, maximumCount > 0 else { return [] }
        guard itemCount > maximumCount else { return Array(0..<itemCount) }
        guard maximumCount > 1 else { return [0] }

        let step = Double(itemCount - 1) / Double(maximumCount - 1)
        return (0..<maximumCount).map { position in
            min(Int((Double(position) * step).rounded()), itemCount - 1)
        }
    }
}

struct SectionIndexView: View {

    let sectionIDs: [String]
    let proxy: ScrollViewProxy

    @State private var feedbackGenerator = UISelectionFeedbackGenerator()
    @State private var lastChar: String?
    @State private var accessibilityItemIndex = 0

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

    /// かな行 + # は常時表示、A-Z は存在するセクションのみ表示
    private static let alwaysVisibleIds: Set<String> = Set(
        ["あ行","か行","さ行","た行","な行","は行","ま行","や行","ら行","わ行","その他"]
    )
    private var filteredItems: [(char: String, sectionId: String)] {
        filteredItems(existingIDs: Set(sectionIDs))
    }

    private func filteredItems(
        existingIDs: Set<String>
    ) -> [(char: String, sectionId: String)] {
        Self.allItems.filter {
            Self.alwaysVisibleIds.contains($0.sectionId) || existingIDs.contains($0.sectionId)
        }
    }

    // 対象セクションが存在しない場合は前後で最近傍を探す
    private func nearestID(for sectionID: String, existingIDs: Set<String>) -> String? {
        SectionIndexSelection.nearestSectionID(
            to: sectionID,
            orderedIDs: Self.allItems.map(\.sectionId),
            existingIDs: existingIDs
        )
    }

    private static let itemHeight: CGFloat = 14

    /// 利用可能な高さに収まるよう等間隔に間引いた表示用アイテムを返す
    private static func thinned(_ items: [(char: String, sectionId: String)], for height: CGFloat) -> [(char: String, sectionId: String)] {
        let maxCount = max(2, Int(height / itemHeight))
        return SectionIndexSelection.thinnedIndices(
            itemCount: items.count,
            maximumCount: maxCount
        ).map { items[$0] }
    }

    var body: some View {
        let existingIDs = Set(sectionIDs)
        let indexedItems = filteredItems(existingIDs: existingIDs)

        GeometryReader { geo in
            let availableHeight = max(0, geo.size.height - 16)
            let visible = Self.thinned(indexedItems, for: availableHeight)
            let itemH = (visible.isEmpty || availableHeight < 1) ? 0 : min(availableHeight / CGFloat(visible.count), 20)
            if itemH > 0 {
                VStack(spacing: 0) {
                    ForEach(visible, id: \.char) { item in
                        Text(item.char)
                            .font(.system(size: 11, weight: .medium, design: .rounded))
                            .foregroundStyle(Color.primary.opacity(0.5))
                            .frame(width: 14, height: itemH)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
                .padding(.trailing, 3)
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
                                if let id = nearestID(
                                    for: item.sectionId,
                                    existingIDs: existingIDs
                                ) {
                                    proxy.scrollTo(id, anchor: .top)
                                }
                            }
                        }
                        .onEnded { _ in
                            lastChar = nil
                        }
                )
            }
        }
        // 文字は右端のまま、ジェスチャ領域だけ44pt確保する。
        .frame(width: 44)
        .padding(.vertical, 8)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("セクション索引")
        .accessibilityValue(accessibilityValue)
        .accessibilityHint("上下にスワイプしてセクションを移動します")
        .accessibilityAdjustableAction { direction in
            moveAccessibilitySelection(direction)
        }
    }

    private var accessibilityValue: String {
        guard filteredItems.indices.contains(accessibilityItemIndex) else { return "先頭" }
        return filteredItems[accessibilityItemIndex].char
    }

    private func moveAccessibilitySelection(_ direction: AccessibilityAdjustmentDirection) {
        let delta: Int
        switch direction {
        case .increment: delta = 1
        case .decrement: delta = -1
        @unknown default:
            return
        }
        guard let nextIndex = SectionIndexSelection.adjustedIndex(
            current: accessibilityItemIndex,
            itemCount: filteredItems.count,
            delta: delta
        ) else { return }
        accessibilityItemIndex = nextIndex

        let item = filteredItems[accessibilityItemIndex]
        if let id = nearestID(
            for: item.sectionId,
            existingIDs: Set(sectionIDs)
        ) {
            feedbackGenerator.selectionChanged()
            proxy.scrollTo(id, anchor: .top)
        }
    }
}
