import SwiftUI
import AppKit

// Native port of the robot-face icon from mockup.html — rounded-rect head +
// circle LED eyes + antenna, plain primitives on purpose (see DESIGN.md: two
// earlier organic/angled shapes both read as "ugly"/"random blob"; simple
// geometric primitives don't have that failure mode). Motion is tied to
// what's actually happening, not a blanket rule (also from DESIGN.md):
// Idle = occasional blink only. Working = continuous pulse (a real process
// is running). Waiting = pupil dart + glow. Error = occasional glitch.
//
// PetIcon itself is a pure function of (state, phase) — no internal
// animation state. Two callers drive it differently: AnimatedPetIcon (below)
// keeps live @State + .task loops for use inside the dropdown window, where
// live SwiftUI views render fine. IconAnimator (separate file) instead
// renders frames to a static NSImage for the MenuBarExtra label — a live
// SwiftUI view painted nothing visible there in practice; every real
// precedent app (claude-status-bar etc.) animates status-item icons by
// swapping pre-rendered bitmap frames, not a live embedded view.

// Light-mode values picked by rough WCAG luminance math against a white
// background (L = 0.2126R + 0.7152G + 0.0722B, contrast = 1.05/(L+0.05)),
// targeting ≥3:1 — the UI-component/large-text bar, the relevant one here
// (small badges/icons, not paragraph text). First-pick values for
// green/amber both landed under 2:1 — those hues have inherently high
// luminance even when "dark," so needed real darkening, not a light tint.
//
// Single source of truth for the actual RGB values — both the dynamic
// (live-view) and explicit (offscreen-render) paths below read from here,
// so there's only one place to tune a color, not two copies that can drift.
func stateColorValues(_ state: String, dark: Bool) -> Color {
    switch state {
    // Verified against Apple's own system colors: systemGreen is #34C759
    // light vs #30D158 dark, systemOrange is #FF9500 in BOTH modes,
    // systemRed is #FF3B30 light vs #FF453A dark — barely any darkening
    // between modes at all. Darkening hard for AA text-contrast math (the
    // original approach here) was the wrong model for a big status-color
    // shape like this icon; real practice keeps it vivid in both modes and
    // relies on shape/icon/text to carry meaning, not a dimmed fill.
    case "working":
        return dark ? Color(red: 0.42, green: 0.76, blue: 0.20) : Color(red: 0.20, green: 0.78, blue: 0.35)
    case "waiting":
        return dark ? Color(red: 1.0, green: 0.73, blue: 0.10) : Color(red: 1.0, green: 0.58, blue: 0.0)
    case "error":
        return dark ? Color(red: 0.85, green: 0.42, blue: 0.30) : Color(red: 0.90, green: 0.38, blue: 0.28)
    default: // idle — light mode: matches the "steel" ear/antenna color, so
        // the whole robot reads as one cohesive muted-metal look when
        // resting, not a stray near-black blob. The original dark-charcoal
        // pick was tuned only for chip-text contrast math and looked
        // scary/wrong filling the robot's entire body — verified live.
        return dark ? Color(red: 0.90, green: 0.91, blue: 0.93) : Color(red: 0.54, green: 0.57, blue: 0.61)
    }
}

/// Appearance-adaptive via an NSColor dynamic provider — works correctly
/// for live SwiftUI views (RowView, SettingsView, MenuContentView), which
/// are hosted in real windows that track system appearance properly.
/// NOT used by IconAnimator's offscreen render (see PetIcon's `forceDark`)
/// — verified live that ImageRenderer's rendering pipeline doesn't resolve
/// dynamic NSColor correctly even wrapped in
/// `NSAppearance.performAsCurrentDrawingAppearance`, so idle rendered dark
/// in the menu bar regardless of the real system appearance.
func stateColor(_ state: String) -> Color {
    Color(NSColor(name: nil, dynamicProvider: { appearance in
        let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        return NSColor(stateColorValues(state, dark: isDark))
    }))
}

// A vivid body-fill color and a legible chip-text color are different
// jobs — verified live: using stateColor for BOTH meant chip/badge text
// was the exact same vivid hue as its own 12-18%-opacity tinted
// background, which is low-contrast (vivid-on-pale-of-itself). This is
// the deliberately darker variant, for text/labels only, never for
// filling a big shape like the robot body or Pac-Man.
func stateTextColorValues(_ state: String, dark: Bool) -> Color {
    switch state {
    case "working":
        return dark ? Color(red: 0.42, green: 0.76, blue: 0.20) : Color(red: 0.15, green: 0.45, blue: 0.08)
    case "waiting":
        return dark ? Color(red: 1.0, green: 0.73, blue: 0.10) : Color(red: 0.55, green: 0.35, blue: 0.0)
    case "error":
        return dark ? Color(red: 0.85, green: 0.42, blue: 0.30) : Color(red: 0.65, green: 0.20, blue: 0.12)
    default:
        return dark ? Color(red: 0.90, green: 0.91, blue: 0.93) : Color(red: 0.35, green: 0.37, blue: 0.40)
    }
}

func stateTextColor(_ state: String) -> Color {
    Color(NSColor(name: nil, dynamicProvider: { appearance in
        let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        return NSColor(stateTextColorValues(state, dark: isDark))
    }))
}

private let steel = Color(red: 0.54, green: 0.57, blue: 0.61)
private let panelColor = Color(red: 0.14, green: 0.16, blue: 0.20)
private let ledColor = Color(red: 0.92, green: 0.96, blue: 0.98)

/// A closed, sleepy eye — a downward curve (⌣) instead of a circle.
struct SleepyEyeShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY), control: CGPoint(x: rect.midX, y: rect.maxY))
        return path
    }
}

struct IconPhase: Equatable {
    var blinkScale: CGFloat = 1 // 1 = open, ~0.1 = closed
    var pulseScale: CGFloat = 1
    var pupilOffset: CGFloat = 0 // -1...1
    var glitchOffset: CGFloat = 0
    var glitchOpacity: Double = 1
    var sleepAmount: CGFloat = 0 // 0 = awake, 1 = fully asleep (closed curved eyes)
    var antennaWiggle: CGFloat = 0 // -1...1
    var zzzOpacity: Double = 0 // floating "z" while asleep — fades in/out on a loop
    var zzzOffset: CGFloat = 0 // drifts upward over the same loop
    var zzz2Opacity: Double = 0
    var zzz2Offset: CGFloat = 0
    var zzz3Opacity: Double = 0
    var zzz3Offset: CGFloat = 0
    static let resting = IconPhase()
}

private let IDLE_SLEEP_AFTER: Double = 20 // seconds of idle before it falls asleep

/// Time-based phase computation shared by both live-view and rendered-frame
/// callers, so the two paths look identical. Idle personality (curious
/// glance / yawn / antenna wiggle) rotates deterministically by a "which
/// ~9s cycle are we in" index rather than true randomness — a live @State
/// random roll would make the row's live view and the menu bar's rendered
/// frames drift out of sync with each other.
///
/// `idleSeconds` is real time-actually-idle (tracked separately by
/// SessionStore), NOT `elapsed` — `elapsed` is time since this icon view
/// was created, which for a session that was working/waiting for a while
/// before going idle would already exceed the sleep threshold, making it
/// fall asleep immediately instead of after 20 real idle seconds.
func computePhase(state: String, elapsed: Double, idleSeconds: Double = 0) -> IconPhase {
    var p = IconPhase()
    switch state {
    case "idle":
        if idleSeconds >= IDLE_SLEEP_AFTER {
            p.sleepAmount = 1
            // Three z's cascading (classic "z Z Z"), each fading in/hold/out
            // on the same loop shape but phase-shifted, so one rises as the
            // previous fades — not three copies of a single "z".
            let base = idleSeconds - IDLE_SLEEP_AFTER
            func zPhase(shift: Double) -> (opacity: Double, offset: CGFloat) {
                let cycle = 2.4
                let zt = (base + shift).truncatingRemainder(dividingBy: cycle)
                let fadeIn = 0.4, hold = 1.2, fadeOut = 0.4
                let op: Double
                if zt < fadeIn { op = zt / fadeIn }
                else if zt < fadeIn + hold { op = 1 }
                else if zt < fadeIn + hold + fadeOut { op = 1 - (zt - fadeIn - hold) / fadeOut }
                else { op = 0 }
                return (op, -CGFloat(zt) * 3)
            }
            (p.zzzOpacity, p.zzzOffset) = zPhase(shift: 0)
            (p.zzz2Opacity, p.zzz2Offset) = zPhase(shift: 0.8)
            (p.zzz3Opacity, p.zzz3Offset) = zPhase(shift: 1.6)
        } else {
            let blinkCycle = 4.5
            let t = elapsed.truncatingRemainder(dividingBy: blinkCycle)
            p.blinkScale = t < 0.11 ? 0.1 : 1

            let bigCycle = 9.0
            let cycleIndex = Int(elapsed / bigCycle)
            let tt = elapsed.truncatingRemainder(dividingBy: bigCycle)
            switch cycleIndex % 3 {
            case 0: // curious glance
                if tt > 2.0 && tt < 3.2 {
                    p.pupilOffset = sin((tt - 2.0) * .pi / 1.2)
                }
            case 1: // yawn — a slower, wider blink arc than the regular quick blink
                if tt > 2.0 && tt < 3.2 {
                    let yt = (tt - 2.0) / 1.2
                    p.blinkScale = yt < 0.5 ? 1 + 0.3 * sin(yt * .pi * 2) : max(0.15, 1 - (yt - 0.5) * 2)
                }
            default: // antenna wiggle
                if tt > 2.0 && tt < 3.0 {
                    p.antennaWiggle = sin((tt - 2.0) * .pi * 3)
                }
            }
        }
    case "working":
        p.pulseScale = 1 + 0.35 * (0.5 + 0.5 * sin(elapsed * 2 * .pi / 1.1))
    case "waiting":
        p.pupilOffset = sin(elapsed * 2 * .pi / 1.8)
    case "error":
        let t = elapsed.truncatingRemainder(dividingBy: 3.2)
        if t < 0.24 {
            let flip = Int(t / 0.08) % 2 == 0
            p.glitchOffset = flip ? 2 : -2
            p.glitchOpacity = flip ? 0.4 : 1.0
        }
    default:
        break
    }
    return p
}

/// Where the sleeping z's cascade from — the popup (bigger, live-view icon)
/// has room above the antenna; the nav (small menu-bar icon) doesn't, so
/// its z's use the side/corner space next to the ear instead. Per direct
/// feedback: liked the aboveAntenna look better in the popup specifically,
/// so this isn't just "one better layout," genuinely different per context.
enum ZzzLayout {
    case aboveAntenna
    case sideCorner
}

struct PetIcon: View {
    let state: String
    var size: CGFloat = 18
    var phase: IconPhase = .resting
    // nil = dynamic stateColor() (live views); non-nil = explicit static
    // color (IconAnimator's offscreen render — see stateColor's doc comment).
    var forceDark: Bool? = nil
    var zzzLayout: ZzzLayout = .aboveAntenna

    var body: some View {
        let s = size
        let color = forceDark.map { stateColorValues(state, dark: $0) } ?? stateColor(state)
        // Same adaptive treatment as the body color — the z's were a fixed
        // near-white (ledColor), invisible against a light popover
        // background in light mode.
        let zzzColor = forceDark.map { stateColorValues("idle", dark: $0) } ?? stateColor("idle")

        ZStack {
            Capsule().fill(steel)
                .frame(width: 0.03 * s, height: 0.12 * s)
                .position(x: 0.5 * s, y: 0.12 * s)
                .rotationEffect(.degrees(Double(phase.antennaWiggle) * 12), anchor: .bottom)
            Circle().fill(color)
                .frame(width: 0.09 * s, height: 0.09 * s)
                .position(x: (0.5 + phase.antennaWiggle * 0.06) * s, y: 0.06 * s)
            RoundedRectangle(cornerRadius: 0.06 * s).fill(steel)
                .frame(width: 0.12 * s, height: 0.26 * s)
                .position(x: 0.10 * s, y: 0.53 * s)
            RoundedRectangle(cornerRadius: 0.06 * s).fill(steel)
                .frame(width: 0.12 * s, height: 0.26 * s)
                .position(x: 0.90 * s, y: 0.53 * s)
            // Head fills more of its own square now — per feedback, "a lot
            // of space under it" with the old 0.62-height/0.49-center values
            // (bottom margin was ~20% of the icon, unused).
            RoundedRectangle(cornerRadius: 0.18 * s).fill(color)
                .frame(width: 0.76 * s, height: 0.74 * s)
                .position(x: 0.5 * s, y: 0.53 * s)
            RoundedRectangle(cornerRadius: 0.10 * s).fill(panelColor)
                .frame(width: 0.50 * s, height: 0.34 * s)
                .position(x: 0.5 * s, y: 0.60 * s)

            eyes(s: s, zzzColor: zzzColor)
        }
        .frame(width: s, height: s)
    }

    private func zzzText(size: CGFloat, opacity: Double, x: CGFloat, y: CGFloat, color: Color) -> some View {
        Text("z")
            .font(.system(size: size, weight: .bold, design: .rounded))
            .foregroundColor(color.opacity(opacity))
            .position(x: x, y: y)
    }

    @ViewBuilder
    private func eyes(s: CGFloat, zzzColor: Color) -> some View {
        switch state {
        case "idle":
            if phase.sleepAmount > 0.5 {
                SleepyEyeShape()
                    .stroke(ledColor, style: StrokeStyle(lineWidth: 0.018 * s, lineCap: .round))
                    .frame(width: 0.10 * s, height: 0.05 * s)
                    .position(x: 0.36 * s, y: 0.60 * s)
                SleepyEyeShape()
                    .stroke(ledColor, style: StrokeStyle(lineWidth: 0.018 * s, lineCap: .round))
                    .frame(width: 0.10 * s, height: 0.05 * s)
                    .position(x: 0.64 * s, y: 0.60 * s)
                // Floor the font size — at small icon sizes a purely
                // proportional 0.09*s shrinks to ~2pt and basically
                // vanishes, even though the same ratio looks fine at the
                // bigger row/popup icon size.
                zzzText(size: max(0.09 * s, 5), opacity: phase.zzzOpacity,
                        x: (zzzLayout == .aboveAntenna ? 0.72 : 0.86) * s,
                        y: (zzzLayout == .aboveAntenna ? 0.24 : 0.36) * s + phase.zzzOffset, color: zzzColor)
                zzzText(size: max(0.115 * s, 6.5), opacity: phase.zzz2Opacity,
                        x: (zzzLayout == .aboveAntenna ? 0.82 : 0.94) * s,
                        y: (zzzLayout == .aboveAntenna ? 0.14 : 0.26) * s + phase.zzz2Offset, color: zzzColor)
                zzzText(size: max(0.14 * s, 8), opacity: phase.zzz3Opacity,
                        x: (zzzLayout == .aboveAntenna ? 0.92 : 0.99) * s,
                        y: (zzzLayout == .aboveAntenna ? 0.04 : 0.16) * s + phase.zzz3Offset, color: zzzColor)
            } else {
                Circle().fill(ledColor)
                    .frame(width: 0.08 * s, height: 0.08 * s * phase.blinkScale)
                    .position(x: (0.36 + phase.pupilOffset * 0.03) * s, y: 0.60 * s)
                Circle().fill(ledColor)
                    .frame(width: 0.08 * s, height: 0.08 * s * phase.blinkScale)
                    .position(x: (0.64 + phase.pupilOffset * 0.03) * s, y: 0.60 * s)
            }
        case "working":
            Circle().fill(ledColor)
                .frame(width: 0.08 * s * phase.pulseScale, height: 0.08 * s * phase.pulseScale)
                .position(x: 0.36 * s, y: 0.60 * s)
            Circle().fill(ledColor)
                .frame(width: 0.08 * s * phase.pulseScale, height: 0.08 * s * phase.pulseScale)
                .position(x: 0.64 * s, y: 0.60 * s)
        case "waiting":
            Circle().fill(ledColor)
                .frame(width: 0.13 * s, height: 0.13 * s)
                .position(x: (0.36 + phase.pupilOffset * 0.03) * s, y: 0.60 * s)
            Circle().fill(ledColor)
                .frame(width: 0.13 * s, height: 0.13 * s)
                .position(x: (0.64 + phase.pupilOffset * 0.03) * s, y: 0.60 * s)
        case "error":
            RoundedRectangle(cornerRadius: 0.015 * s).fill(ledColor)
                .frame(width: 0.12 * s, height: 0.03 * s)
                .position(x: 0.36 * s + phase.glitchOffset, y: 0.595 * s)
                .opacity(phase.glitchOpacity)
            RoundedRectangle(cornerRadius: 0.015 * s).fill(ledColor)
                .frame(width: 0.12 * s, height: 0.03 * s)
                .position(x: 0.64 * s + phase.glitchOffset, y: 0.595 * s)
                .opacity(phase.glitchOpacity)
        default:
            EmptyView()
        }
    }
}

/// Live-animated wrapper for use inside the dropdown window (not the menu
/// bar label — that uses IconAnimator's rendered frames instead).
struct AnimatedPetIcon: View {
    let state: String
    var size: CGFloat = 20
    var idleSince: Date? = nil

    @State private var phase = IconPhase.resting
    private let startTime = Date()

    var body: some View {
        PetIcon(state: state, size: size, phase: phase)
            .task { await tick() }
    }

    private func tick() async {
        while !Task.isCancelled {
            let elapsed = Date().timeIntervalSince(startTime)
            let idleSeconds = idleSince.map { Date().timeIntervalSince($0) } ?? 0
            withAnimation(.linear(duration: 0.08)) {
                phase = computePhase(state: state, elapsed: elapsed, idleSeconds: idleSeconds)
            }
            try? await Task.sleep(nanoseconds: 80_000_000)
        }
    }
}
