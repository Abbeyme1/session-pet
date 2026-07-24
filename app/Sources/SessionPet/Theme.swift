import SwiftUI

/// Central design tokens — one source of truth instead of magic numbers
/// scattered per-view. State colors are unchanged from earlier direct
/// decisions (idle white, working green, waiting amber, error coral) —
/// this pass is about consistent spacing/typography/chrome, not re-picking
/// hues that were already deliberately tuned.
enum Theme {
    // MARK: Spacing — 8pt grid per Apple's macOS HIG convention
    static let spacingXS: CGFloat = 4
    static let spacingS: CGFloat = 8
    static let spacingM: CGFloat = 12
    static let spacingL: CGFloat = 16
    static let spacingXL: CGFloat = 24 // HIG "section gap"

    // MARK: Radii
    static let radiusS: CGFloat = 6
    static let radiusM: CGFloat = 10

    /// Hairline edge definition without a heavy visible border — the
    /// "0 0 0 0.5px" signature real macOS card UI uses instead of thick
    /// borders or drop shadows to separate cards from their background.
    static let hairline = Color.primary.opacity(0.09)

    /// Matches Apple's typical UI timing tiers (fast interaction feedback,
    /// not a generic 0.2s guess).
    static let animationFast = Animation.timingCurve(0.25, 0.46, 0.45, 0.94, duration: 0.15)
    static let animationNormal = Animation.timingCurve(0.25, 0.46, 0.45, 0.94, duration: 0.25)

    // MARK: Typography
    static func title(_ size: CGFloat = 12) -> Font { .system(size: size, weight: .semibold) }
    static func label(_ size: CGFloat = 9) -> Font { .system(size: size, weight: .bold) }
    static func body(_ size: CGFloat = 11) -> Font { .system(size: size) }
    static func mono(_ size: CGFloat = 10) -> Font { .system(size: size, design: .monospaced) }

    /// Uppercase section header used in the dropdown detail views and
    /// Settings — one consistent look for "a label above a group of stuff."
    static func sectionLabel(_ text: String) -> some View {
        Text(text.uppercased())
            .font(label(9))
            .foregroundColor(.secondary)
    }
}
