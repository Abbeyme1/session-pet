import Foundation
import ServiceManagement

/// Launch-at-login support using the modern `SMAppService` API (macOS 13+).
///
/// This only works correctly when running from a proper `.app` bundle
/// (see `package.sh`) — `SMAppService.mainApp` registers/unregisters the
/// bundle at `Bundle.main.bundlePath` as a login item for the current user,
/// no helper app or separate launch agent plist needed.
///
/// NOT wired up automatically — call `LoginItem.register()` /
/// `LoginItem.unregister()` from wherever the app wants to turn this on/off
/// (e.g. a menu toggle, or unconditionally on first launch).
enum LoginItem {

    /// Whether Session Pet is currently registered to launch at login.
    static var isRegistered: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// Register Session Pet to launch automatically at login.
    /// Safe to call if already registered (no-op / idempotent).
    @discardableResult
    static func register() -> Bool {
        do {
            try SMAppService.mainApp.register()
            return true
        } catch {
            print("LoginItem: failed to register for launch at login: \(error)")
            return false
        }
    }

    /// Unregister Session Pet from launching at login.
    /// Safe to call if not currently registered (no-op / idempotent).
    @discardableResult
    static func unregister() -> Bool {
        do {
            try SMAppService.mainApp.unregister()
            return true
        } catch {
            print("LoginItem: failed to unregister from launch at login: \(error)")
            return false
        }
    }

    /// Convenience toggle: flips current registration state, returns the new state.
    @discardableResult
    static func toggle() -> Bool {
        if isRegistered {
            unregister()
            return false
        } else {
            register()
            return true
        }
    }
}
