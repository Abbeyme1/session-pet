import SwiftUI
import AppKit

/// Renders PetIcon to a real NSImage on a timer, for use as the
/// MenuBarExtra label. A live SwiftUI view painted nothing visible there in
/// practice (tried Canvas, then plain shapes — both invisible); rendering
/// to a bitmap and swapping frames is the same technique every real
/// precedent app uses for animated menu bar icons.
@MainActor
final class IconAnimator: ObservableObject {
    @Published private(set) var image: NSImage
    private var timer: Timer?
    private let startTime = Date()
    // The popup's exact size — proven correct via direct screenshot (ears
    // fully legible, proportions matching the design). PetIcon's geometry
    // is always computed at THIS size, never at `displaySize` directly —
    // recomputing thin shapes (the ear nubs) at a smaller logical point
    // size makes them antialias away, verified live. Instead we render once
    // at the known-good size and bitmap-downscale the finished image, which
    // preserves proportions since it's a uniform resize of already-correct
    // artwork, not a re-render of thinner geometry.
    private static let referenceSize: CGFloat = 26
    // Final on-screen size in the menu bar — independent of referenceSize.
    private let displaySize: CGFloat = 20
    private weak var store: SessionStore?
    // Most of every animation cycle is a no-op (e.g. the 4.5s blink cycle is
    // only actually moving for ~0.11s of it) — re-rendering identical frames
    // 12.5x/sec anyway was pure waste. Caught live: a full ImageRenderer pass
    // every 80ms, forever, regardless of visibility, was the dominant
    // sustained CPU cost (~35-40%), enough to make the whole system feel
    // stuck when competing with something else CPU/GPU-heavy (e.g. fullscreen
    // video). Skipping the render when nothing actually moved is a pure
    // no-op fix — it changes zero visible frames, only the redundant ones.
    private var lastRenderedState: String = ""
    private var lastRenderedPhase: IconPhase = .resting

    init(store: SessionStore) {
        self.store = store
        self.image = Self.render(state: store.aggregateState, phase: .resting, displaySize: displaySize)
        lastRenderedState = store.aggregateState
        timer = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    private func tick() {
        guard let store else { return }
        let elapsed = Date().timeIntervalSince(startTime)
        let state = store.aggregateState
        let idleSeconds = store.aggregateIdleSinceDate.map { Date().timeIntervalSince($0) } ?? 0
        let phase = computePhase(state: state, elapsed: elapsed, idleSeconds: idleSeconds)
        guard state != lastRenderedState || phase != lastRenderedPhase else { return }
        lastRenderedState = state
        lastRenderedPhase = phase
        image = Self.render(state: state, phase: phase, displaySize: displaySize)
    }

    private static func render(state: String, phase: IconPhase, displaySize: CGFloat) -> NSImage {
        // ImageRenderer draws offscreen, not attached to any real window —
        // verified live that its rendering pipeline doesn't resolve dynamic
        // NSColor correctly even wrapped in
        // NSAppearance.performAsCurrentDrawingAppearance (idle rendered
        // dark regardless of actual system appearance). PetIcon's
        // `forceDark` sidesteps dynamic-color resolution entirely here —
        // an explicit, deterministic value instead of relying on OS
        // appearance-context propagation that doesn't reach this renderer.
        let isDark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let view = PetIcon(state: state, size: referenceSize, phase: phase, forceDark: isDark, zzzLayout: .sideCorner)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 4 // supersample — clean source detail for the downscale below
        renderer.isOpaque = false
        guard let sourceImage = renderer.nsImage else {
            return NSImage(size: NSSize(width: displaySize, height: displaySize))
        }

        let target = NSImage(size: NSSize(width: displaySize, height: displaySize))
        target.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        sourceImage.draw(
            in: NSRect(x: 0, y: 0, width: displaySize, height: displaySize),
            from: NSRect(origin: .zero, size: sourceImage.size),
            operation: .sourceOver, fraction: 1.0
        )
        target.unlockFocus()
        target.isTemplate = false
        return target
    }
}
