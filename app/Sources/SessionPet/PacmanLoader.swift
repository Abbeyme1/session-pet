import SwiftUI
import AppKit

/// A real Pac-Man shape — full circle minus an animatable wedge for the
/// mouth, wedge centered on 0° (pointing right, the direction of travel).
/// Used as the "something's actually happening" loading indicator for the
/// Working state.
struct PacmanShape: Shape {
    var mouthOpen: CGFloat // 0 = closed (full circle), 1 = fully open

    var animatableData: CGFloat {
        get { mouthOpen }
        set { mouthOpen = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let radius = min(rect.width, rect.height) / 2
        let maxMouthAngle: Double = 42
        let mouthAngle = Double(mouthOpen) * maxMouthAngle
        var path = Path()
        path.move(to: center)
        path.addArc(
            center: center, radius: radius,
            startAngle: .degrees(mouthAngle),
            endAngle: .degrees(360 - mouthAngle),
            clockwise: false
        )
        path.closeSubpath()
        return path
    }
}

/// A row of dots that vanish as `progress` passes them — a genuine `Shape`
/// (not `.opacity()` toggled off a plain conditional) because SwiftUI only
/// interpolates animatable-modifier values frame-by-frame; a boolean
/// computed from @State just crossfades between the old/new body evaluation
/// over the whole animation, so every dot faded together instead of
/// vanishing one at a time as Pac-Man actually reached each one. Shape's
/// `path(in:)` gets called with the real interpolated `animatableData` on
/// every frame — the same mechanism that already makes the mouth animate
/// correctly above — so this reads the true instantaneous progress.
struct DotsRowShape: Shape {
    var progress: CGFloat // same 0...1 basis as Pac-Man's moveProgress
    let dotCount: Int
    let dotSize: CGFloat
    let travel: CGFloat
    let startX: CGFloat

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard dotCount > 0 else { return path }
        for i in 0..<dotCount {
            let frac = dotCount > 1 ? CGFloat(i) / CGFloat(dotCount - 1) : 0
            if progress >= frac { continue } // eaten
            let cx = startX + frac * travel
            let dotRect = CGRect(x: cx - dotSize / 2, y: rect.midY - dotSize / 2, width: dotSize, height: dotSize)
            path.addEllipse(in: dotRect)
        }
        return path
    }
}

struct PacmanLoader: View {
    var width: CGFloat = 40
    var height: CGFloat = 10
    var dotCount: Int = 5
    // Adaptive — bright arcade-yellow reads fine on a dark row card but is
    // notoriously low-contrast on a light one, same issue as everything
    // else that assumed a dark background throughout this app. Only ever
    // used in live views (never IconAnimator's offscreen render), so a
    // plain dynamic NSColor is safe here, no forceDark plumbing needed.
    var color: Color = Color(NSColor(name: nil, dynamicProvider: { appearance in
        let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        return NSColor(isDark ? Color(red: 1.0, green: 0.85, blue: 0.1) : Color(red: 0.90, green: 0.65, blue: 0.0))
    }))

    @State private var moveProgress: CGFloat = 0
    @State private var mouthOpen: CGFloat = 1

    private var travel: CGFloat { max(0, width - height) }
    private var dotSize: CGFloat { 3 }

    var body: some View {
        ZStack(alignment: .leading) {
            DotsRowShape(progress: moveProgress, dotCount: dotCount, dotSize: dotSize, travel: travel, startX: height / 2)
                .fill(Color.secondary.opacity(0.4))

            PacmanShape(mouthOpen: mouthOpen)
                .fill(color)
                .frame(width: height, height: height)
                .offset(x: moveProgress * travel)
        }
        .frame(width: width, height: height)
        .task { await animateMouth() }
        .task { await animateMove() }
    }

    private func animateMouth() async {
        while !Task.isCancelled {
            withAnimation(.easeInOut(duration: 0.12)) { mouthOpen = 0 }
            try? await Task.sleep(nanoseconds: 120_000_000)
            withAnimation(.easeInOut(duration: 0.12)) { mouthOpen = 1 }
            try? await Task.sleep(nanoseconds: 120_000_000)
        }
    }

    private func animateMove() async {
        while !Task.isCancelled {
            withAnimation(.linear(duration: 1.6)) { moveProgress = 1 }
            try? await Task.sleep(nanoseconds: 1_600_000_000)
            moveProgress = 0
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
    }
}
