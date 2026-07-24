import SwiftUI

/// Settings window content for Session Pet.
///
/// Takes an injected `SettingsStore` (rather than owning `@StateObject var
/// settings = SettingsStore()` itself) so the app can create one shared
/// instance and hand it to both this view and anything else that needs to
/// read a preference (e.g. `SessionStore` gating notifications).
///
/// Matches the dropdown's card language (hairline-bordered sections, same
/// frosted-glass material) rather than the native grouped Form style, which
/// looked visually disconnected from the rest of the app.
struct SettingsView: View {
    @ObservedObject var settings: SettingsStore

    private var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: Theme.spacingS) {
                PetIcon(state: "idle", size: 28)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Session Pet").font(Theme.title(13))
                    Text("Version \(version)").font(Theme.body(10)).foregroundColor(.secondary)
                }
                Spacer()
            }
            .padding(Theme.spacingM)

            Divider()

            VStack(alignment: .leading, spacing: Theme.spacingL) {
                SettingsSection(title: "Notifications") {
                    Toggle(isOn: $settings.notificationsEnabled) {
                        Text("Notify when a session needs attention").font(Theme.body(12))
                    }
                    Toggle(isOn: $settings.notificationSoundEnabled) {
                        Text("Play sound with notifications").font(Theme.body(12))
                    }
                    .disabled(!settings.notificationsEnabled)
                }

                SettingsSection(title: "General") {
                    Toggle(isOn: $settings.launchAtLoginEnabled) {
                        Text("Open at Login").font(Theme.body(12))
                    }
                }
            }
            .padding(Theme.spacingM)
        }
        .tint(stateColor("working"))
        .background(.thickMaterial)
        .frame(width: 320, height: 270)
    }
}

/// A hairline-bordered card with an uppercase label above — the same
/// visual unit RowView's cards use, so Settings doesn't read like a
/// different, more generic app bolted on.
private struct SettingsSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.spacingS) {
            Theme.sectionLabel(title)
            VStack(alignment: .leading, spacing: Theme.spacingM) {
                content
            }
            .padding(Theme.spacingM)
            .background(
                RoundedRectangle(cornerRadius: Theme.radiusM)
                    .fill(Color.primary.opacity(0.03))
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.radiusM)
                    .strokeBorder(Theme.hairline, lineWidth: 0.5)
            )
        }
    }
}
