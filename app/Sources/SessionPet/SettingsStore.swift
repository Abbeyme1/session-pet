import Foundation
import Combine

/// Persisted user preferences for Session Pet, backed by `UserDefaults`.
///
/// A plain `ObservableObject` rather than declaring `@AppStorage` directly in
/// `SettingsView` — that property wrapper only reads/writes `UserDefaults`
/// for the view it's declared on, it can't be created once and shared. This
/// gives the app one instance to inject into both `SettingsView` and
/// wherever else a preference needs to be read (e.g. `SessionStore` gating
/// its `postNotification` calls on `notificationsEnabled`).
final class SettingsStore: ObservableObject {
    private enum Keys {
        static let notificationsEnabled = "settings.notificationsEnabled"
        static let notificationSoundEnabled = "settings.notificationSoundEnabled"
        static let launchAtLoginEnabled = "settings.launchAtLoginEnabled"
    }

    private let defaults: UserDefaults

    /// Whether Session Pet should fire a native notification when a session
    /// newly enters "waiting". Actual posting stays in `SessionStore` — this
    /// is just the on/off preference for that behavior.
    @Published var notificationsEnabled: Bool {
        didSet { defaults.set(notificationsEnabled, forKey: Keys.notificationsEnabled) }
    }

    /// Whether notifications (when enabled) should play a sound
    /// (`osascript display notification ... sound name "Glass"`) vs. silent.
    @Published var notificationSoundEnabled: Bool {
        didSet { defaults.set(notificationSoundEnabled, forKey: Keys.notificationSoundEnabled) }
    }

    /// Just the stored preference for whether Session Pet should launch at
    /// login. Actually registering/unregistering with the system (e.g. via
    /// `SMAppService`) is a separate `LoginItem` helper's responsibility —
    /// this store only tracks what the user asked for.
    @Published var launchAtLoginEnabled: Bool {
        didSet { defaults.set(launchAtLoginEnabled, forKey: Keys.launchAtLoginEnabled) }
    }

    /// `defaults` is injectable (rather than always `.standard`) so this can
    /// be unit-tested or previewed against an isolated suite without
    /// touching the user's real preferences.
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            Keys.notificationsEnabled: true,
            Keys.notificationSoundEnabled: true,
            Keys.launchAtLoginEnabled: false,
        ])
        self.notificationsEnabled = defaults.bool(forKey: Keys.notificationsEnabled)
        self.notificationSoundEnabled = defaults.bool(forKey: Keys.notificationSoundEnabled)
        self.launchAtLoginEnabled = defaults.bool(forKey: Keys.launchAtLoginEnabled)
    }
}
