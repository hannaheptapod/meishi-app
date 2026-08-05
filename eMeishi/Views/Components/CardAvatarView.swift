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

    let initials: String
    let company: String
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
        let trimmedInitials = initials.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedInitials.isEmpty {
            return String(trimmedInitials.prefix(1))
        }
        let comp = company.trimmingCharacters(in: .whitespacesAndNewlines)
        if !comp.isEmpty {
            return String(comp.prefix(1)).uppercased()
        }
        return nil
    }

    /// 色相のキーは「会社優先」。同じ会社の人を同色にまとめる。
    private var colorKey: String? {
        let comp = company.trimmingCharacters(in: .whitespacesAndNewlines)
        if !comp.isEmpty {
            return comp
        }
        let trimmedInitials = initials.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedInitials.isEmpty {
            return trimmedInitials
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
#Preview("CardAvatarView パターン") {
    let samples = [
        ("山", "サンプル商事"),
        ("川", ""),
        ("", "Example Inc."),
        ("", ""),
    ]

    return ScrollView {
        VStack(spacing: 16) {
            HStack(spacing: 12) {
                ForEach(Array(samples.enumerated()), id: \.offset) { _, sample in
                    VStack(spacing: 4) {
                        CardAvatarView(initials: sample.0, company: sample.1, size: 40)
                        Text(sample.0.isEmpty ? sample.1 : sample.0)
                            .font(.caption2)
                    }
                }
            }
            HStack(spacing: 12) {
                ForEach(Array(samples.enumerated()), id: \.offset) { _, sample in
                    CardAvatarView(initials: sample.0, company: sample.1, size: 58)
                }
            }
        }
        .padding()
    }
}
#endif
