import SwiftUI
import UIKit

// MARK: - セクションインデックス

nonisolated enum SectionIndexSelection {
    static func adjustedIndex(current: Int, itemCount: Int, delta: Int) -> Int? {
        guard itemCount > 0 else { return nil }
        let clampedCurrent = min(max(current, 0), itemCount - 1)
        return min(max(clampedCurrent + delta, 0), itemCount - 1)
    }
}

struct SectionIndexView: View {

    let sections: [CardSection]
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

    private var existingIds: Set<String> { Set(sections.map(\.id)) }

    /// かな行 + # は常時表示、A-Z は存在するセクションのみ表示
    private static let alwaysVisibleIds: Set<String> = Set(
        ["あ行","か行","さ行","た行","な行","は行","ま行","や行","ら行","わ行","その他"]
    )
    private var filteredItems: [(char: String, sectionId: String)] {
        Self.allItems.filter { Self.alwaysVisibleIds.contains($0.sectionId) || existingIds.contains($0.sectionId) }
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
            let availableHeight = max(0, geo.size.height - 16)
            let visible = Self.thinned(filteredItems, for: availableHeight)
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
        if let id = nearestId(for: item.sectionId) {
            feedbackGenerator.selectionChanged()
            proxy.scrollTo(id, anchor: .top)
        }
    }
}
