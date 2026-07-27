import SwiftUI
import AppKit
import Combine
import UserNotifications


/// Handles clicks on real (UNUserNotificationCenter) notifications — pops
/// the dropdown open on the exact session the notification was about.
/// Focusing the terminal directly (the previous behavior) skipped every
/// Approve/Deny/AskUserQuestion affordance built into the dropdown; this
/// makes the notification actually route through them. Only ever installed
/// when running from a proper .app bundle (see SessionStore.postNotification)
/// — the `swift run` dev path never touches this since UNUserNotificationCenter
/// itself crashes there without a bundle.
final class NotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    weak var appDelegate: AppDelegate?

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let sessionId = response.notification.request.content.userInfo["session_id"] as? String
        let target = appDelegate
        Task { @MainActor in target?.showPopover(expandingSessionId: sessionId) }
        completionHandler()
    }

    // Without this, a notification never shows at all while the app is
    // frontmost — which, for a background menu-bar app, is indistinguishable
    // from "notifications silently stopped working."
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
}

/// Owns the actual UI: a manual NSStatusItem + NSPopover instead of SwiftUI's
/// `MenuBarExtra` scene, specifically so a notification click can show the
/// dropdown programmatically (see NotificationDelegate) — `MenuBarExtra` has
/// no public API for that pre-macOS 14, and this package targets macOS 13.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    let settings = SettingsStore()
    private(set) var store: SessionStore!

    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var iconAnimator: IconAnimator!
    private var iconCancellable: AnyCancellable?
    private var launchAtLoginCancellable: AnyCancellable?
    private var notificationDelegate: NotificationDelegate?
    private var settingsWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if CommandLine.arguments.contains("--export-app-icon") {
            exportAppIconSet()
            exit(0)
        }
        if CommandLine.arguments.contains("--debug-menubar-icon") {
            exportMenuBarIconDebug()
            exit(0)
        }

        NSApp.setActivationPolicy(.accessory)

        let store = SessionStore(settings: settings)
        self.store = store
        let animator = IconAnimator(store: store)
        iconAnimator = animator

        if settings.launchAtLoginEnabled != LoginItem.isRegistered {
            if settings.launchAtLoginEnabled { LoginItem.register() } else { LoginItem.unregister() }
        }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = animator.image
        // .scaleProportionallyUpOrDown was the real bug behind "changing
        // IconAnimator's size does nothing" — it scales the image to FILL
        // the button's fixed squareLength frame regardless of the source
        // image's actual size, so shrinking the render just made it blurrier
        // (upscaled from fewer pixels), never smaller on screen. .scaleNone
        // displays at true native size so `size` actually controls the
        // visible footprint.
        statusItem.button?.imageScaling = .scaleNone
        statusItem.button?.target = self
        statusItem.button?.action = #selector(togglePopover)

        iconCancellable = animator.$image.sink { [weak self] image in
            self?.statusItem.button?.image = image
        }

        popover = NSPopover()
        popover.behavior = .transient
        popover.delegate = self
        // contentViewController is built lazily on first show (see
        // makeHostingControllerIfNeeded) and torn down again on close (see
        // popoverDidClose) rather than created once here and left wired up
        // for the app's whole lifetime. A SwiftUI hosting view keeps
        // reacting to @Published changes (re-diffing every row, including
        // PacmanLoader's animation and RowView's diff preview) as long as
        // it's loaded, whether or not the popover is actually visible —
        // caught live: CPU usage jumped and stayed elevated the moment the
        // dropdown was opened once, never dropping back down even after
        // closing it.

        // Not tied to any view's lifecycle — fires whether or not the
        // Settings window has ever been opened, unlike the old .onChange
        // that lived inside SettingsView itself.
        launchAtLoginCancellable = settings.$launchAtLoginEnabled.dropFirst().sink { enabled in
            if enabled { LoginItem.register() } else { LoginItem.unregister() }
        }

        if Bundle.main.bundleIdentifier != nil {
            let delegate = NotificationDelegate()
            delegate.appDelegate = self
            notificationDelegate = delegate
            UNUserNotificationCenter.current().delegate = delegate
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }
    }

    /// A real NSWindow instead of SwiftUI's `Settings` scene + the private
    /// `showSettingsWindow:` selector trick — that trick routes through the
    /// standard-app-menu responder chain, which an accessory (LSUIElement,
    /// no menu bar) app never has, so clicking "Settings…" silently did
    /// nothing. This works regardless of app menu structure.
    func openSettings() {
        if settingsWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 320, height: 270),
                styleMask: [.titled, .closable],
                backing: .buffered, defer: false
            )
            window.title = "Session Pet Settings"
            window.contentView = NSHostingView(rootView: SettingsView(settings: settings))
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    // Without this, macOS's window-state restoration reopens whatever
    // window was last visible (e.g. Settings, from a prior manual open)
    // any time the app reactivates with no window currently open — which
    // is exactly what a notification click does. Caught live: clicking a
    // notification opened Settings instead of popping the dropdown.
    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { false }

    @objc private func togglePopover() {
        if popover.isShown {
            popover.performClose(nil)
        } else {
            showPopover(expandingSessionId: nil)
        }
    }

    /// Rebuilds the hosting controller fresh each time the dropdown opens —
    /// see the note at `popover.delegate = self` above for why it isn't
    /// just created once and left alive.
    private func makeHostingControllerIfNeeded() {
        guard popover.contentViewController == nil else { return }
        let hosting = NSHostingController(rootView: MenuContentView(store: store, onOpenSettings: { [weak self] in self?.openSettings() }))
        // Without this, NSPopover sizes itself once at creation and never
        // tracks SwiftUI content changes afterward — a long Bash command or
        // an expanded diff just gets clipped at the original height instead
        // of the popover growing to fit. `.preferredContentSize` makes the
        // hosting controller keep `preferredContentSize` in sync with
        // SwiftUI's ideal size, which NSPopover observes and resizes to.
        hosting.sizingOptions = [.preferredContentSize]
        popover.contentViewController = hosting
    }

    /// Releases the SwiftUI content the instant the dropdown closes, so it
    /// stops observing `store` (and paying render cost) while hidden.
    func popoverDidClose(_ notification: Notification) {
        popover.contentViewController = nil
    }

    func showPopover(expandingSessionId sessionId: String?) {
        if let sessionId { store.expandedId = sessionId }
        makeHostingControllerIfNeeded()
        guard let button = statusItem.button else { return }
        NSApp.activate(ignoringOtherApps: true)
        // NSApp.activate is async, and a single run-loop-tick defer wasn't
        // enough — verified live it still mis-anchored (landed at the
        // screen edge instead of the status item) when triggered from a
        // background context like a notification click. A short explicit
        // delay gives the window server time to actually finish activating
        // before we ask for a relative-anchor calculation.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            self.popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            // For an accessory-policy (LSUIElement) app, NSPopover doesn't
            // reliably make its own window key on `show` — verified live
            // with an event monitor: the window was still isKeyWindow=false
            // over a full second after showing, right up until the user's
            // first real click, which the window then consumed just to
            // become key (no click ever reached the SwiftUI content). Since
            // the window isn't key yet regardless of how long you wait,
            // there's nothing to race — force it key immediately instead.
            self.popover.contentViewController?.view.window?.makeKey()
        }
    }
}

@main
struct SessionPetApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    // Settings is now a real NSWindow owned by AppDelegate (see
    // openSettings()) — the SwiftUI `Settings` scene's own trigger
    // mechanism (private `showSettingsWindow:` selector via the standard
    // app-menu responder chain) silently did nothing for an accessory
    // (LSUIElement, no menu bar) app. `App` still requires a Scene here;
    // this one is never shown.
    var body: some Scene {
        Settings { EmptyView() }
    }
}
