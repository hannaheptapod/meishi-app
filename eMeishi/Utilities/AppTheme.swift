import SwiftUI

enum AppTheme {
    static let brandOrange = Color(red: 1.0, green: 0.34, blue: 0.0)
    static let background = Color(uiColor: .systemGroupedBackground)
    static let contentSurface = Color(uiColor: .secondarySystemGroupedBackground)
    static let auxiliarySurface = Color(uiColor: .tertiarySystemGroupedBackground)

    static let imageCornerRadius: CGFloat = 12
    static let contentCornerRadius: CGFloat = 18

    enum Spacing {
        static let xSmall: CGFloat = 4
        static let small: CGFloat = 8
        static let medium: CGFloat = 12
        static let large: CGFloat = 16
        static let xLarge: CGFloat = 24
    }

    static let cardListMaximumWidth: CGFloat = 760
    static let contentMaximumWidth: CGFloat = 860
    static let monthlyBlue = Color.blue
    static let companyBlueGray = Color(red: 0.34, green: 0.45, blue: 0.58)
    static let categoryColors: [Color] = [.blue, .teal, .indigo, .purple]
}
