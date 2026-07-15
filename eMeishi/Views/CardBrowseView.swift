import SwiftUI
import UIKit

/// 名刺画像を主役にして、前後のカードを左右へめくる閲覧画面。
struct CardBrowseView: View {
    @EnvironmentObject private var viewModel: CardListViewModel
    @EnvironmentObject private var navigationState: AppNavigationState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var currentIndex = 0
    @State private var dragOffset: CGFloat = 0
    @State private var cardForDetail: BusinessCard?

    private var cards: [BusinessCard] { viewModel.filteredCards }

    var body: some View {
        Group {
            if cards.isEmpty {
                ContentUnavailableView(
                    "表示できる名刺がありません",
                    systemImage: "rectangle.stack",
                    description: Text(viewModel.isFilterActive || viewModel.isSearchActive
                        ? "検索または絞り込み条件を変更してください"
                        : "中央の追加ボタンから名刺を登録できます")
                )
            } else {
                GeometryReader { proxy in
                    VStack(spacing: AppTheme.Spacing.large) {
                        if let filter = viewModel.externalFilter {
                            activeFilterBar(filter)
                        }

                        cardStack(availableWidth: proxy.size.width)
                            .frame(maxHeight: .infinity)

                        cardSummary(cards[currentIndex])
                    }
                    .padding(.horizontal, AppTheme.Spacing.xLarge)
                    .padding(.top, AppTheme.Spacing.medium)
                    .padding(.bottom, AppTheme.Spacing.medium)
                    .frame(maxWidth: AppTheme.contentMaximumWidth)
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .background(AppTheme.background.ignoresSafeArea())
        .navigationTitle("めくる")
        .navigationBarTitleDisplayMode(.large)
        .searchable(
            text: $viewModel.searchText,
            placement: .navigationBarDrawer(displayMode: .always),
            prompt: "名前・会社・連絡先を検索"
        )
        .navigationDestination(item: $cardForDetail) { card in
            CardDetailView(card: card)
        }
        .onAppear {
            viewModel.fetchCards()
            clampCurrentIndex()
        }
        .onChange(of: cards.count) { _, _ in clampCurrentIndex() }
        .onChange(of: navigationState.externalFilter) { _, filter in
            viewModel.externalFilter = filter
            currentIndex = 0
        }
    }

    private func cardStack(availableWidth: CGFloat) -> some View {
        // GeometryReaderの初期レイアウトで幅0が通知されても負のframeを作らない。
        let width = min(max(availableWidth - 48, 1), 620)
        return ZStack {
            ForEach(Array(visibleCardIndices.reversed()), id: \.self) { index in
                let depth = index - currentIndex
                browseCard(cards[index])
                    .frame(width: width)
                    .scaleEffect(1 - CGFloat(depth) * 0.045)
                    .offset(y: CGFloat(depth) * 16)
                    .opacity(1 - CGFloat(depth) * 0.18)
                    .zIndex(Double(10 - depth))
                    .allowsHitTesting(depth == 0)
            }

            browseCard(cards[currentIndex])
                .frame(width: width)
                .offset(x: dragOffset)
                .rotationEffect(.degrees(reduceMotion ? 0 : Double(dragOffset / 35)))
                .gesture(cardDragGesture)
                .onTapGesture { cardForDetail = cards[currentIndex] }
                .zIndex(20)
        }
        .animation(reduceMotion ? nil : .snappy(duration: 0.28), value: currentIndex)
        .animation(reduceMotion ? nil : .interactiveSpring, value: dragOffset)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(currentIndex + 1)枚目、\(cards[currentIndex].fullName)")
        .accessibilityAction(named: "次の名刺") { move(by: 1) }
        .accessibilityAction(named: "前の名刺") { move(by: -1) }
    }

    private var visibleCardIndices: [Int] {
        guard !cards.isEmpty else { return [] }
        let firstBackgroundIndex = currentIndex + 1
        let lastBackgroundIndex = min(currentIndex + 2, cards.count - 1)
        guard firstBackgroundIndex <= lastBackgroundIndex else { return [] }
        return Array(firstBackgroundIndex...lastBackgroundIndex)
    }

    private func browseCard(_ card: BusinessCard) -> some View {
        Group {
            if let data = card.imageData, let image = UIImage(data: data) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .padding(AppTheme.Spacing.medium)
            } else {
                VStack(spacing: AppTheme.Spacing.small) {
                    Text(initials(for: card))
                        .font(.system(size: 64, weight: .semibold, design: .rounded))
                    Text(card.fullName.isEmpty ? "名前なし" : card.fullName)
                        .font(.headline)
                }
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(AppTheme.Spacing.xLarge)
            }
        }
        .aspectRatio(cardAspectRatio(card), contentMode: .fit)
        .frame(maxWidth: .infinity)
        .background(AppTheme.contentSurface.opacity(0.72))
        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 24, style: .continuous))
        .contentShape(.rect(cornerRadius: 24, style: .continuous))
    }

    private func cardSummary(_ card: BusinessCard) -> some View {
        VStack(spacing: AppTheme.Spacing.medium) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: AppTheme.Spacing.xSmall) {
                    Text(card.fullName.isEmpty ? "（名前なし）" : card.fullName)
                        .font(.title2.weight(.bold))
                    if let company = card.company, !company.isEmpty {
                        Text(company)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer()
                Text("\(currentIndex + 1) / \(cards.count)")
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            HStack {
                Button { move(by: -1) } label: {
                    Label("前へ", systemImage: "chevron.left")
                }
                .disabled(currentIndex == 0)

                Spacer()

                Button { cardForDetail = card } label: {
                    Label("詳細を見る", systemImage: "person.text.rectangle")
                }

                Spacer()

                Button { move(by: 1) } label: {
                    Label("次へ", systemImage: "chevron.right")
                        .labelStyle(.titleAndIcon)
                }
                .disabled(currentIndex == cards.count - 1)
            }
            .font(.subheadline.weight(.semibold))
            // 閲覧補助は主要CTAではないため、ブランド色ではなく文字色へ統一する。
            .foregroundStyle(.primary)
        }
        .padding(AppTheme.Spacing.large)
        .glassEffect(.regular, in: .rect(cornerRadius: AppTheme.contentCornerRadius, style: .continuous))
    }

    private func activeFilterBar(_ filter: CardListExternalFilter) -> some View {
        HStack(spacing: AppTheme.Spacing.small) {
            Image(systemName: "line.3.horizontal.decrease.circle.fill")
                .foregroundStyle(AppTheme.brandOrange)
            Text("絞り込み中：\(filter.displayTitle)")
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
            Spacer()
            Button {
                navigationState.externalFilter = nil
                viewModel.clearExternalFilter()
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
            .accessibilityLabel("絞り込みを解除")
        }
        .padding(.horizontal, AppTheme.Spacing.medium)
        .frame(minHeight: 40)
        .glassEffect(.regular, in: .capsule)
    }

    private var cardDragGesture: some Gesture {
        DragGesture(minimumDistance: 12)
            .onChanged { value in dragOffset = value.translation.width }
            .onEnded { value in
                let predicted = value.predictedEndTranslation.width
                if predicted < -70 {
                    move(by: 1)
                } else if predicted > 70 {
                    move(by: -1)
                }
                dragOffset = 0
            }
    }

    private func move(by delta: Int) {
        let next = min(max(currentIndex + delta, 0), cards.count - 1)
        guard next != currentIndex else {
            dragOffset = 0
            return
        }
        if reduceMotion {
            currentIndex = next
        } else {
            withAnimation(.snappy(duration: 0.28)) { currentIndex = next }
        }
        UISelectionFeedbackGenerator().selectionChanged()
    }

    private func clampCurrentIndex() {
        currentIndex = min(max(currentIndex, 0), max(cards.count - 1, 0))
    }

    private func initials(for card: BusinessCard) -> String {
        let last = card.lastName?.first.map(String.init) ?? ""
        let first = card.firstName?.first.map(String.init) ?? ""
        return last + first
    }

    private func cardAspectRatio(_ card: BusinessCard) -> CGFloat {
        guard let data = card.imageData,
              let image = UIImage(data: data),
              image.size.height > 0 else {
            return 1.58
        }
        return min(max(image.size.width / image.size.height, 0.58), 1.8)
    }
}
