import SwiftUI
import AppKit

/// The dropdown's content — hosted inside AppDelegate's NSPopover rather
/// than a SwiftUI `MenuBarExtra` scene, since `MenuBarExtra` has no public
/// API (pre-macOS 14) to open its dropdown programmatically. We need that:
/// clicking a notification should pop this open on the exact session it's
/// about, not just focus the raw terminal and bypass everything built here.
struct MenuContentView: View {
    @ObservedObject var store: SessionStore
    let onOpenSettings: () -> Void
    @State private var draggingId: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if store.sessions.isEmpty {
                VStack(spacing: Theme.spacingS) {
                    PetIcon(state: "idle", size: 32)
                    Text("No sessions seen yet")
                        .font(Theme.body(11)).foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(Theme.spacingL)
            } else {
                // Capped + scrollable rather than growing unbounded — a big
                // diff or a many-option AskUserQuestion could otherwise push
                // the popover to cover the whole screen. A prior ScrollView
                // attempt broke rendering entirely, but that was under the
                // old MenuBarExtra scene; this is a plain NSHostingController
                // inside an NSPopover now, a much better-supported combo.
                ScrollView {
                    // Card-per-row with gaps, not a flat divided list — the
                    // actual visual signature separating premium menu-bar
                    // apps (Stats, iStat Menus, Bartender) from a plain
                    // table view. Each RowView is its own rounded card now.
                    VStack(alignment: .leading, spacing: Theme.spacingS) {
                        ForEach(store.sessions) { session in
                            RowView(store: store, session: session, draggingId: $draggingId)
                        }
                    }
                    .padding(.horizontal, Theme.spacingS)
                    .padding(.vertical, Theme.spacingS)
                }
                .frame(maxHeight: 520)
            }
            Divider()
            // Icon + text together — a real reference app (usage tracker
            // menu-bar popover) does exactly this cleanly, contradicting
            // the abstract "icon and text shouldn't combine" guidance from
            // earlier; the concrete example wins. Subtle background tint
            // still distinguishes this as its own toolbar/status region.
            HStack(spacing: Theme.spacingL) {
                FooterButton(icon: "gearshape", title: "Settings") { onOpenSettings() }
                Spacer()
                FooterButton(icon: "power", title: "Quit", tint: .red) { NSApplication.shared.terminate(nil) }
            }
            .padding(.horizontal, Theme.spacingM)
            .padding(.vertical, Theme.spacingS)
            .background(Color.primary.opacity(0.02))
        }
        .frame(width: 340)
        // Fully opaque read as flat/un-native; fully raw NSPopover vibrancy
        // washed out too much wallpaper through. .thickMaterial is the real
        // macOS frosted-glass blur — mostly solid, a hint of see-through,
        // the actual native aesthetic instead of either extreme.
        .background(.thickMaterial)
    }
}

/// Icon + label footer button, tinted together (not just the icon) so
/// Quit reads as a single red action, not a gray label with a red accent.
private struct FooterButton: View {
    let icon: String
    let title: String
    var tint: Color? = nil // e.g. Quit gets red — a destructive action, not neutral
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: icon).font(.system(size: 12))
                Text(title).font(Theme.body(12))
            }
            .foregroundColor(tint ?? (isHovering ? .primary : .secondary))
            .opacity(isHovering ? 1 : 0.85)
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}
