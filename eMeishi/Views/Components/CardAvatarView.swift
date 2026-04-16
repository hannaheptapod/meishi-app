import CoreData
import SwiftUI

// MARK: - 名刺のアバター（一覧・詳細で共通）
//
// 表示ルール:
//   文字: lastName → company → SF Symbol person.fill
//   色相: company → lastName → デフォルト accentColor
// 「色は組織、文字は個人」という構成。同じ会社の人は背景色で一目で分かり、
// その中の個人は中央の漢字 1 文字で識別する。
//
// 彩度・明度は Light / Dark Mode 別に固定値を持ち、両モードで文字
// （foregroundStyle .primary）とのコントラスト比を確保する。色相だけが
// company（または lastName）の安定ハッシュで決まる。

struct CardAvatarView: View {

    @ObservedObject var card: BusinessCard
    var size: CGFloat

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            Circle()
                .fill(backgroundColor)
                .frame(width: size, height: size)
            content
        }
    }

    @ViewBuilder
    private var content: some View {
        if let ch = primaryCharacter {
            Text(ch)
                .font(.system(size: size * 0.42, weight: .semibold))
                .foregroundStyle(textColor)
        } else {
            Image(systemName: "person.fill")
                .font(.system(size: size * 0.45))
                .foregroundStyle(.secondary)
        }
    }

    private var primaryCharacter: String? {
        if let last = card.lastName?.trimmingCharacters(in: .whitespaces), !last.isEmpty {
            return String(last.prefix(1))
        }
        if let comp = card.company?.trimmingCharacters(in: .whitespaces), !comp.isEmpty {
            return String(comp.prefix(1)).uppercased()
        }
        return nil
    }

    /// 色相のキーは「会社優先」。同じ会社の人を同色にまとめる。
    private var colorKey: String? {
        if let comp = card.company?.trimmingCharacters(in: .whitespaces), !comp.isEmpty {
            return comp
        }
        if let last = card.lastName?.trimmingCharacters(in: .whitespaces), !last.isEmpty {
            return last
        }
        return nil
    }

    private var backgroundColor: Color {
        guard let key = colorKey else {
            return Color.accentColor.opacity(colorScheme == .dark ? 0.22 : 0.12)
        }
        let hue = Self.hue(for: key)
        // ライトはパステル明色（黒文字）、ダークは深い色（白文字）
        if colorScheme == .dark {
            return Color(hue: hue, saturation: 0.55, brightness: 0.42)
        } else {
            return Color(hue: hue, saturation: 0.32, brightness: 0.92)
        }
    }

    private var textColor: Color {
        // 上の背景輝度に対して常に高コントラスト側を選ぶ
        colorScheme == .dark ? .white : .black
    }

    /// 文字列の安定ハッシュ（DJB2）から 0..<1 の色相を返す。
    private static func hue(for key: String) -> Double {
        var hash: UInt64 = 5381
        for scalar in key.unicodeScalars {
            hash = ((hash << 5) &+ hash) &+ UInt64(scalar.value)
        }
        return Double(hash % 360) / 360.0
    }
}

#if DEBUG
#Preview("CardAvatarView パターン") { @MainActor in
    let context = PersistenceController.preview.container.viewContext

    func makeCard(last: String?, first: String?, company: String?) -> BusinessCard {
        let c = BusinessCard(context: context)
        c.id = UUID()
        c.lastName = last
        c.firstName = first
        c.company = company
        return c
    }

    let cards: [BusinessCard] = [
        makeCard(last: "田中", first: "太郎", company: "株式会社サンプル"),
        makeCard(last: "鈴木", first: nil,    company: nil),
        makeCard(last: nil,    first: nil,    company: "Apple Inc."),
        makeCard(last: nil,    first: nil,    company: nil),
        makeCard(last: "田中", first: "次郎", company: nil),
        makeCard(last: "田中", first: "三郎", company: nil),
        makeCard(last: "佐藤", first: "花子", company: nil),
        makeCard(last: "高橋", first: "一郎", company: nil),
    ]

    return ScrollView {
        VStack(spacing: 16) {
            HStack(spacing: 12) {
                ForEach(cards, id: \.id) { card in
                    VStack(spacing: 4) {
                        CardAvatarView(card: card, size: 40)
                        Text(card.lastName ?? card.company ?? "(空)")
                            .font(.caption2)
                    }
                }
            }
            HStack(spacing: 12) {
                ForEach(cards, id: \.id) { card in
                    CardAvatarView(card: card, size: 58)
                }
            }
        }
        .padding()
    }
}
#endif
