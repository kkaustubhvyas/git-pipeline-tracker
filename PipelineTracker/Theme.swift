import SwiftUI

/// Centralized design tokens. "Developer console" aesthetic:
/// rounded display type, monospaced data, a single electric accent, status-driven color.
enum Theme {

    // MARK: - Color

    /// Signature accent — electric indigo/violet. Used sparingly for primary actions & focus.
    static let accent = Color(red: 0.45, green: 0.42, blue: 0.98)

    /// Surfaces
    static let surface       = Color(nsColor: .windowBackgroundColor)
    static let surfaceRaised  = Color.primary.opacity(0.04)
    static let surfaceHover    = Color.primary.opacity(0.06)
    static let hairline       = Color.primary.opacity(0.08)

    // MARK: - Spacing (4pt rhythm)

    static let xs: CGFloat = 4
    static let sm: CGFloat = 8
    static let md: CGFloat = 12
    static let lg: CGFloat = 16
    static let xl: CGFloat = 24

    // MARK: - Radius

    static let radiusSm: CGFloat = 5
    static let radiusMd: CGFloat = 8
    static let radiusLg: CGFloat = 12

    // MARK: - Type

    static func display(_ size: CGFloat, _ weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight, design: .rounded)
    }

    static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }

    // MARK: - Layout

    static let panelWidth: CGFloat = 420
    static let rowHeight: CGFloat = 48
}

// MARK: - Reusable view helpers

extension View {
    /// Soft raised card used throughout the redesign.
    func cardSurface(_ radius: CGFloat = Theme.radiusMd) -> some View {
        background(Theme.surfaceRaised)
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
    }
}

/// A small uppercase section eyebrow label.
struct Eyebrow: View {
    let text: String
    var color: Color = .secondary
    var body: some View {
        Text(text.uppercased())
            .font(Theme.display(9.5, .bold))
            .tracking(0.8)
            .foregroundStyle(color)
    }
}
