import Foundation
import UserNotifications

// Backend: tmux discovery, focus, approve/deny, waiting-resolution detection,
// pruning. All empirically verified against real sessions — see DESIGN.md.
// UI moved to SwiftUI (PetIcon.swift, RowView.swift, SessionPetApp.swift);
// this file owns data + system interaction only.

func resolveTmuxPath() -> String {
    let candidates = ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux", "/usr/bin/tmux"]
    for c in candidates where FileManager.default.fileExists(atPath: c) { return c }
    return "tmux"
}

// A wedged tmux server (dead socket, stale server, huge scrollback) used to
// hang this indefinitely — and since every call site ran synchronously on
// SessionStore's @MainActor 1s refresh timer, one hung subprocess froze the
// entire app, including the Quit button, with no way out but a force-quit.
// Bounding every call caps the damage to `timeoutSeconds` instead of forever.
private let SHELL_TIMEOUT_SECONDS = 3.0

@discardableResult
func runShell(_ path: String, _ args: [String], timeoutSeconds: Double = SHELL_TIMEOUT_SECONDS) -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: path)
    process.arguments = args
    let outPipe = Pipe()
    process.standardOutput = outPipe
    process.standardError = Pipe()

    // Read stdout concurrently on a background thread, not after the
    // process exits — reading only afterward deadlocks for good once
    // output exceeds the pipe's ~64KB kernel buffer: the child blocks
    // writing to a full, undrained pipe while we block waiting for it
    // to exit, and no timeout can break a true deadlock since neither
    // side is making progress. Caught live: `ps -axo pid=,ppid=,comm=`
    // on a busy machine wedged the whole app this way, indefinitely.
    let readGroup = DispatchGroup()
    nonisolated(unsafe) var output = Data() // safe: readGroup.wait() below happens-before every read of this
    readGroup.enter()
    DispatchQueue.global(qos: .utility).async {
        output = outPipe.fileHandleForReading.readDataToEndOfFile()
        readGroup.leave()
    }

    let sem = DispatchSemaphore(value: 0)
    process.terminationHandler = { _ in sem.signal() }
    do {
        try process.run()
    } catch {
        return ""
    }

    if sem.wait(timeout: .now() + timeoutSeconds) == .timedOut {
        process.terminate()
        if sem.wait(timeout: .now() + 0.5) == .timedOut, process.isRunning {
            kill(process.processIdentifier, SIGKILL)
        }
    }
    _ = readGroup.wait(timeout: .now() + 1.0) // pipe closes on exit, so this returns promptly
    return String(data: output, encoding: .utf8) ?? ""
}

/// Runs `runShell` on a background thread and suspends the caller instead of
/// blocking it — the actual fix for the freeze. SessionStore is `@MainActor`,
/// so every method on it normally executes on the main thread; without this,
/// `await`ing a plain synchronous call still runs inline on the main thread
/// and the UI (including Quit) is unresponsive for as long as it takes.
@discardableResult
func runShellAsync(_ path: String, _ args: [String], timeoutSeconds: Double = SHELL_TIMEOUT_SECONDS) async -> String {
    await Task.detached(priority: .utility) {
        runShell(path, args, timeoutSeconds: timeoutSeconds)
    }.value
}

struct SessionStatus: Codable, Identifiable {
    // session_id alone isn't unique once subagents are involved — they
    // share their parent's session_id, distinguished only by agent_id
    // (verified live: a real subagent's hook events carried the identical
    // session_id as the main session). Combine both so a parent row and
    // its subagent rows never collide as "the same" Identifiable item.
    var id: String { agent_id.map { "\(session_id)__\($0)" } ?? session_id }
    let session_id: String
    let cwd: String
    var state: String
    let last_event: String
    let tmux_pane: String?
    let agent_id: String?
    let agent_type: String?
    let tool: String?
    let tool_input: ToolInput?
    let updated_at: Int

    struct ToolInput: Codable {
        let command: String?
        let file_path: String?
        let description: String?
        // Edit's actual schema; Write's; NotebookEdit's — fixed public tool
        // API shapes, not runtime UI behavior, so no live-probe needed here
        // (unlike the terminal-rendering stuff elsewhere in this file).
        let old_string: String?
        let new_string: String?
        let content: String?
        let notebook_path: String?
        let new_source: String?
        // AskUserQuestion's real shape — the untruncated source of truth.
        // Live pane capture (see parseCurrentPrompt) is the only way to know
        // which screen/step is currently active, but Claude Code's own
        // terminal UI truncates long labels/descriptions to fit the pane's
        // column width before we ever see them there. This is what's real.
        let questions: [AskQuestion]?
    }

    struct AskQuestion: Codable {
        struct Option: Codable {
            let label: String
            let description: String?
        }
        let question: String
        let header: String?
        let options: [Option]
        let multiSelect: Bool?
    }

    var name: String { (cwd as NSString).lastPathComponent }

    /// Best-effort human-readable summary of what the tool is doing —
    /// real fields only, nothing fabricated.
    var toolDetail: String? {
        tool_input?.command ?? tool_input?.file_path ?? tool_input?.description ?? tool_input?.notebook_path
    }
}

struct ProcInfo {
    let ppid: Int32
    let comm: String
}

/// A tmux pane belongs to a session; a session may or may not currently
/// have an attached client. Closing a terminal window just detaches the
/// client — the pane/session keeps running on the tmux server regardless.
/// So "is this really still open" means: pane exists AND its session has
/// an attached client, not just "pane exists."
struct PaneInfo {
    let sessionName: String
    let pid: Int32
}

let priority: [String: Int] = ["waiting": 3, "error": 2, "working": 1, "idle": 0]

let NON_TMUX_STALE_SECONDS = 20 * 60 // no way to confirm a non-tmux session is still alive, so age it out

// We only hook the *ask* (PermissionRequest), not its *resolution* — once
// the user answers directly in the terminal (bypassing our Approve/Deny),
// nothing tells the status file it got resolved. Caught live: a session
// sat frozen at "waiting" for 7+ minutes after being answered.
//
// A fixed timeout can't fix this correctly either way: too long feels
// stuck (the 90s version), too short falsely clears mid-answer on a
// genuinely slow multi-step AskUserQuestion flow (the 15s version, caught
// live — user was still deciding, app already said idle). Real dialogs
// (Bash's "1. Yes/2../3.", AskUserQuestion's "1. Submit answers/2. Cancel",
// its per-question option screens) all render as a "❯ N. ..." numbered
// option line — verified directly against a live user session. So check
// the actual pane content for that pattern instead of guessing from a
// clock: still there → really still waiting, gone → really resolved,
// accurate the instant it clears either way.
let WAITING_WATCHDOG_STALE_SECONDS = 6 * 60 // fallback only if pane can't be read at all

// No hook event documents a clean "this subagent finished" signal (unlike
// the main session's Stop) — SubagentStart exists, nothing like
// SubagentStop. So a subagent's status just ages out after no new events
// for a while, same shape as NON_TMUX_STALE_SECONDS but much shorter,
// since a subagent that's actually done tends to go quiet within seconds,
// not idle-for-tens-of-minutes like a real terminal session might.
let SUBAGENT_STALE_SECONDS = 90

// Right when UserPromptSubmit/PreToolUse writes "working", claude's TUI
// hasn't drawn its spinner line yet — a few seconds of real UI lag, not a
// bug. Trusting paneShowsActiveSpinner's absence instantly showed "idle"
// for the first few seconds of every single turn, a regression caught live
// the moment this shipped. Only trust "no spinner" once the hook itself has
// gone quiet for a while — i.e. this is genuinely stuck, not just new.
let WORKING_SPINNER_GRACE_SECONDS = 6

// Only tools empirically verified to show a plain numbered "1. Yes / 2. Yes
// always / 3. No" dialog get remote Approve/Deny. AskUserQuestion (and any
// other tool showing custom multi-choice options) is NOT safe here — "1"/"3"
// would pick an arbitrary option, not what the user actually means. Verify
// a tool live (like Bash was) before adding it here. Edit and Write verified
// the same way — both show the identical "1. Yes / 2. Yes, allow all edits
// during this session / 3. No" dialog, resolution confirmed live. NotebookEdit
// verified identical to Edit/Write. WebFetch verified too — same 1/2/3
// structure and bare-digit-resolves mechanism, though its wording differs
// ("Do you want to allow Claude to fetch this content?" / "don't ask again
// for <domain>") — fine since we only ever send the digit, never match text.
// Read verified via a real user-pasted dialog — "1. Yes / 2. Yes, allow
// reading from <dir>/ during this session / 3. No", identical shape.
// WebSearch confirmed same 1/2/3 shape too — network-access tool like WebFetch.
let SAFE_APPROVE_TOOLS: Set<String> = ["Bash", "Edit", "Write", "NotebookEdit", "WebFetch", "Read", "WebSearch"]

// AskUserQuestion is a genuinely different interaction, not a whitelist
// entry: options are dynamic (not fixed 1/2/3) and it's multi-step (a
// per-question screen, then a review/submit screen). The hook only fires
// once with the full question set — it doesn't say which screen you're
// currently on as you progress. So instead of trusting stale hook data,
// read the live pane content each refresh (same ground-truth approach as
// waiting-detection) and parse whatever's actually on screen right now.
// Verified live: pressing the bare digit (no Enter) instantly selects that
// option, same as Bash/Edit/Write's "1"/"3", just with N options instead of
// always 3 — confirmed via a real "2" → "Banana. Noted." resolution.
struct ParsedPrompt {
    struct Option {
        let number: Int
        let label: String
        let description: String? // the indented line under the option, when present — real context, must not be dropped
    }
    let question: String
    let options: [Option]
}

// NotificationDelegate lives in SessionPetApp.swift now, alongside
// AppDelegate — a notification click needs to pop the dropdown open (which
// only AppDelegate's NSStatusItem/NSPopover can do), not just focus a pane.

@MainActor
final class SessionStore: ObservableObject {
    @Published var sessions: [SessionStatus] = []
    @Published var expandedId: String? = nil
    @Published var pinnedIds: Set<String> = []
    // Stable, user-controlled order instead of resorting by state priority
    // every tick — that jumped rows around mid-review and was, per direct
    // user feedback, "very annoying." New sessions append at the end; drag
    // reordering (see moveSession) and pin-to-top are the only things that
    // change position now.
    @Published var manualOrder: [String] = []
    @Published var parsedPrompts: [String: ParsedPrompt] = [:]
    @Published var textEntryFor: String? = nil // session_id currently in "Type something"/"Chat about this" mode
    @Published var subagentsBySession: [String: [SessionStatus]] = [:]
    @Published var expandedSubagentId: String? = nil // SessionStatus.id of the subagent whose detail is shown
    // Per-session only, not persisted — resets to the folder name once this
    // session ends (see pruning in refresh()), not something tied to the
    // project/cwd long-term.
    @Published var customNames: [String: String] = [:]

    let statusDir = ("~/.claude/session-pet/status" as NSString).expandingTildeInPath
    let tmuxPath = resolveTmuxPath()
    private var timer: Timer?
    private var reapTimer: Timer?
    private var workingSince: [String: Date] = [:] // session_id -> when it entered "working"
    private var idleSinceMap: [String: Date] = [:] // session_id -> when it entered "idle" (for the sleep-after-N-seconds icon animation)
    private var aggregateIdleSince: Date? = nil // same, for the menu bar's aggregate icon
    private var notifiedWaiting: Set<String> = [] // session_ids already notified for the current waiting spell
    private let settings: SettingsStore
    // Bundle.main.bundleIdentifier is nil for a bare `swift run` process (no
    // Info.plist) and set to "com.abhay.sessionpet" only in the real
    // packaged .app (see package.sh) — the same signal that distinguishes
    // "UNUserNotificationCenter works" from "UNUserNotificationCenter crashes
    // outright" (bundleProxyForCurrentProcess is nil without a bundle).
    // Delegate assignment + authorization request happen in AppDelegate
    // (SessionPetApp.swift), since that's also who owns the NSPopover a
    // notification click needs to open.
    private let hasRealBundle = Bundle.main.bundleIdentifier != nil

    init(settings: SettingsStore) {
        self.settings = settings
        Task { @MainActor in await self.refresh() }
        Task { @MainActor in await self.reapStaleTmuxSessions() }
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }
        // Reaping is a heavier, less time-critical sweep (tmux list-sessions +
        // ps + potential kill-session calls) — every 5 minutes is plenty, no
        // reason to pay that cost on the 1s refresh cadence.
        reapTimer = Timer.scheduledTimer(withTimeInterval: 300.0, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.reapStaleTmuxSessions() }
        }
    }

    /// Real .app bundle: UNUserNotificationCenter, so a click can carry the
    /// session id and pop the dropdown open to it (see NotificationDelegate
    /// in SessionPetApp.swift) — otherwise a notification click bypassed
    /// every Approve/Deny/AskUserQuestion affordance we built, jumping
    /// straight to the raw terminal instead. Bare `swift run` (dev path):
    /// UNUserNotificationCenter crashes outright (`bundleProxyForCurrentProcess
    /// is nil`) without a bundle, so fall back to `osascript display
    /// notification` — no click-action, but reliable.
    private func postNotification(title: String, body: String, sessionId: String, paneId: String?) async {
        guard settings.notificationsEnabled else { return }
        if hasRealBundle {
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            if settings.notificationSoundEnabled { content.sound = .default }
            var userInfo: [String: String] = ["session_id": sessionId]
            if let paneId { userInfo["pane_id"] = paneId }
            content.userInfo = userInfo
            let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
            try? await UNUserNotificationCenter.current().add(request)
        } else {
            let escapedTitle = title.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            let escapedBody = body.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            let soundClause = settings.notificationSoundEnabled ? " sound name \"Glass\"" : ""
            let script = "display notification \"\(escapedBody)\" with title \"\(escapedTitle)\"\(soundClause)"
            await runShellAsync("/usr/bin/osascript", ["-e", script])
        }
    }

    /// Fires once per new waiting spell — not every refresh tick while it
    /// persists, and fires again if a session resolves and then hits a new
    /// waiting state later (e.g. the next question in a multi-question flow).
    private func notifyIfNewlyWaiting() async {
        let waitingIds = Set(sessions.filter { $0.state == "waiting" }.map { $0.session_id })
        notifiedWaiting.formIntersection(waitingIds) // drop ids that resolved

        for session in sessions where session.state == "waiting" && !notifiedWaiting.contains(session.session_id) {
            notifiedWaiting.insert(session.session_id)

            let body: String
            if session.tool == "AskUserQuestion", let parsed = parsedPrompts[session.session_id] {
                body = parsed.question
            } else if let tool = session.tool {
                body = session.toolDetail.map { "\(tool): \($0)" } ?? "Wants to run \(tool)"
            } else {
                body = "Needs your attention"
            }
            await postNotification(title: session.name, body: body, sessionId: session.session_id, paneId: session.tmux_pane)
        }
    }

    /// A session's own hook-reported state, bumped up if any of its live
    /// subagents outrank it (e.g. main session idle between tool calls
    /// while a Task-spawned subagent is still working) — a subagent has no
    /// clean "done" signal back to its parent, so the parent's own state
    /// can't be trusted alone to say nothing's happening.
    func effectiveState(for session: SessionStatus) -> String {
        let subs = subagentsBySession[session.session_id] ?? []
        return ([session] + subs).max { (priority[$0.state] ?? 0) < (priority[$1.state] ?? 0) }?.state ?? session.state
    }

    var aggregateState: String {
        let pinned = sessions.filter { pinnedIds.contains($0.session_id) }
        if let winner = pinned.max(by: { (priority[effectiveState(for: $0)] ?? 0) < (priority[effectiveState(for: $1)] ?? 0) }) {
            return effectiveState(for: winner)
        }
        guard let winner = sessions.max(by: { (priority[effectiveState(for: $0)] ?? 0) < (priority[effectiveState(for: $1)] ?? 0) }) else { return "idle" }
        return effectiveState(for: winner)
    }

    func elapsed(for session: SessionStatus) -> String? {
        guard session.state == "working", let start = workingSince[session.session_id] else { return nil }
        let s = max(0, Int(Date().timeIntervalSince(start)))
        return "\(s / 60):\(String(format: "%02d", s % 60))"
    }

    /// When this session actually entered idle — not "how long the view's
    /// existed," which is what a plain elapsed-since-creation timer would
    /// give. Needed so the icon's "falls asleep after 20s idle" animation
    /// waits real idle time, not however long a session happened to be
    /// working/waiting before it went idle.
    func idleSince(for session: SessionStatus) -> Date? {
        guard effectiveState(for: session) == "idle" else { return nil }
        return idleSinceMap[session.session_id]
    }

    /// Same, for the menu bar's single aggregate icon.
    var aggregateIdleSinceDate: Date? {
        aggregateState == "idle" ? aggregateIdleSince : nil
    }

    func togglePin(_ id: String) {
        if pinnedIds.contains(id) { pinnedIds.remove(id) } else { pinnedIds.insert(id) }
        applyOrder()
    }

    func toggleExpanded(_ id: String) {
        expandedId = (expandedId == id) ? nil : id
    }

    /// Pinned ids first (in their relative manualOrder), then the rest —
    /// the one ordering rule everything else (refresh, moveSession, pin
    /// toggling) funnels through, so there's a single source of truth for
    /// "what order is the list in right now."
    private func applyOrder() {
        let byId = Dictionary(uniqueKeysWithValues: sessions.map { ($0.session_id, $0) })
        let orderedIds = manualOrder.filter { pinnedIds.contains($0) } + manualOrder.filter { !pinnedIds.contains($0) }
        sessions = orderedIds.compactMap { byId[$0] }
    }

    /// Live drag-reorder — a plain DragGesture on the handle (RowView) calls
    /// this continuously as the cursor crosses each row-height unit, not
    /// onDrag/onDrop's system drag machinery, which felt laggy (async
    /// NSItemProvider round trip instead of direct 1:1 tracking).
    func moveSessionBy(id: String, steps: Int) {
        guard steps != 0, let idx = manualOrder.firstIndex(of: id) else { return }
        let newIdx = max(0, min(manualOrder.count - 1, idx + steps))
        guard newIdx != idx else { return }
        manualOrder.remove(at: idx)
        manualOrder.insert(id, at: newIdx)
        applyOrder()
    }

    /// Empty name reverts to the folder-name default rather than storing a
    /// blank override.
    func rename(_ sessionId: String, to newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespaces)
        customNames[sessionId] = trimmed.isEmpty ? nil : trimmed
    }

    // MARK: - tmux

    func panes() async -> [String: PaneInfo] {
        let out = await runShellAsync(tmuxPath, ["list-panes", "-a", "-F", "#{pane_id} #{session_name} #{pane_pid}"])
        var map: [String: PaneInfo] = [:]
        for line in out.split(separator: "\n") {
            let parts = line.split(separator: " ")
            guard parts.count == 3, let pid = Int32(parts[2]) else { continue }
            map[String(parts[0])] = PaneInfo(sessionName: String(parts[1]), pid: pid)
        }
        return map
    }

    /// session_name -> the tmux client pid attached to it. A session with
    /// no entry here has no window actually showing it right now.
    func clientPidBySession() async -> [String: Int32] {
        let out = await runShellAsync(tmuxPath, ["list-clients", "-F", "#{client_session} #{client_pid}"])
        var map: [String: Int32] = [:]
        for line in out.split(separator: "\n") {
            let parts = line.split(separator: " ")
            guard parts.count == 2, let pid = Int32(parts[1]) else { continue }
            map[String(parts[0])] = pid
        }
        return map
    }

    /// session_name -> the tty of its attached client, e.g. "/dev/ttys004".
    /// Used to pick the exact Terminal.app tab showing this session, since
    /// Terminal.app exposes `tty` per tab via AppleScript — one of the few
    /// terminal apps that does.
    func clientTtyBySession() async -> [String: String] {
        let out = await runShellAsync(tmuxPath, ["list-clients", "-F", "#{client_session} #{client_tty}"])
        var map: [String: String] = [:]
        for line in out.split(separator: "\n") {
            let parts = line.split(separator: " ")
            guard parts.count == 2 else { continue }
            map[String(parts[0])] = String(parts[1])
        }
        return map
    }

    func processTable() async -> [Int32: ProcInfo] {
        let out = await runShellAsync("/bin/ps", ["-axo", "pid=,ppid=,comm="])
        var table: [Int32: ProcInfo] = [:]
        for line in out.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let parts = trimmed.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard parts.count == 3, let pid = Int32(parts[0]), let ppid = Int32(parts[1]) else { continue }
            table[pid] = ProcInfo(ppid: ppid, comm: String(parts[2]))
        }
        return table
    }

    /// Ground truth for "is this pane actually running claude right now."
    /// Pane/client attachment alone can't tell — a pane whose `claude`
    /// process got killed abruptly (kill -9, crash, force-quit a tab that
    /// tmux then reattaches to a bare shell) stays attached forever, so
    /// liveSessions()'s attachment check alone would leave the last
    /// hook-written state (e.g. "working") frozen with nothing left to ever
    /// correct it — no Stop event fires, no timeout covers tmux panes.
    /// Walk the pane shell's descendants for a live `claude` process instead
    /// of trusting the stale state.
    func hasLiveClaudeProcess(panePid: Int32, table: [Int32: ProcInfo]) -> Bool {
        var childrenByParent: [Int32: [Int32]] = [:]
        for (pid, info) in table { childrenByParent[info.ppid, default: []].append(pid) }
        var stack = [panePid]
        var visited: Set<Int32> = []
        while let pid = stack.popLast() {
            guard visited.insert(pid).inserted else { continue }
            if let info = table[pid], info.comm.contains("claude") { return true }
            stack.append(contentsOf: childrenByParent[pid] ?? [])
        }
        return false
    }

    /// Walks up the process tree from the tmux CLIENT (not the pane's shell
    /// — that just parents back to the detached tmux server) to find which
    /// app is actually displaying the terminal: Terminal.app, iTerm2, VS
    /// Code's integrated terminal, or IntelliJ's.
    func resolveHostApp(clientPid: Int32, table: [Int32: ProcInfo]) -> String? {
        var current = clientPid
        for _ in 0..<25 {
            guard let info = table[current] else { return nil }
            let comm = info.comm.lowercased()
            if comm.contains("visual studio code") || comm.contains("code helper") { return "Visual Studio Code" }
            if comm.contains("intellij idea") { return "IntelliJ IDEA" }
            if comm.contains("iterm") { return "iTerm2" }
            if comm.contains("/terminal") || comm == "terminal" { return "Terminal" }
            if info.ppid <= 1 { return nil }
            current = info.ppid
        }
        return nil
    }

    /// Terminal.app (unlike VS Code/IntelliJ) exposes `tty` per tab via
    /// AppleScript, so we can select the exact tab showing this session,
    /// not just bring the app forward. Real fix, not a degraded fallback.
    func focusTerminalTab(tty: String) async {
        let script = """
        tell application "Terminal"
          activate
          repeat with w in windows
            repeat with t in tabs of w
              if tty of t is "\(tty)" then
                set selected tab of w to t
                set index of w to 1
                return
              end if
            end repeat
          end repeat
        end tell
        """
        await runShellAsync("/usr/bin/osascript", ["-e", script])
    }

    func focusPane(_ paneId: String) async {
        await runShellAsync(tmuxPath, ["select-pane", "-t", paneId])
        await runShellAsync(tmuxPath, ["select-window", "-t", paneId])

        let paneMap = await panes()
        let clientPids = await clientPidBySession()
        guard let session = paneMap[paneId]?.sessionName, let clientPid = clientPids[session] else {
            // No attached client found — shouldn't happen for a pane we
            // chose to show (liveSessions already filters those out), but
            // degrade gracefully: pane is still repositioned in tmux either way.
            return
        }
        let table = await processTable()
        guard let app = resolveHostApp(clientPid: clientPid, table: table) else { return }

        if app == "Terminal", let tty = await clientTtyBySession()[session] {
            await focusTerminalTab(tty: tty)
        } else {
            // VS Code / IntelliJ / iTerm2: brings the app forward only —
            // can't select the exact internal tab without a dedicated
            // extension/plugin for each (see DESIGN.md).
            await runShellAsync("/usr/bin/osascript", ["-e", "tell application \"\(app)\" to activate"])
        }
    }

    // Empirically verified against a real permission dialog (not guessed):
    //   ❯ 1. Yes
    //     2. Yes, and always allow ...   <- NEVER send this for a plain approve
    //     3. No
    // "1"/"3" + Enter resolve the prompt correctly.
    func sendApprove(_ paneId: String) async {
        await runShellAsync(tmuxPath, ["send-keys", "-t", paneId, "1", "Enter"])
        expandedId = nil
    }
    func sendDeny(_ paneId: String) async {
        await runShellAsync(tmuxPath, ["send-keys", "-t", paneId, "3", "Enter"])
        expandedId = nil
    }

    // MARK: - Reaping stale tmux sessions

    // The ~/.zshrc wrapper names every session "claude-$$" (the invoking
    // shell's PID) and tmux runs with `destroy-unattached off` (needed so a
    // deliberate prefix-d detach survives). Closing the terminal just
    // detaches — it doesn't kill the session, and since the shell that
    // created it is gone with the window, that PID-named session can never
    // legitimately be reattached by anyone. Nothing else ever reaps it:
    // liveSessions() only deletes the now-orphaned *status file*, not the
    // tmux session or the claude process (and its MCP server children)
    // still running underneath it. Left alone, every closed terminal tab
    // leaks a claude process forever — caught live as 69 detached sessions
    // some 13 days old, ~250 stray MCP subprocess descendants, and a
    // machine pushed to ~36GB of swap.
    let DETACHED_REAP_SECONDS = 30 * 60

    struct TmuxSessionInfo {
        let name: String
        let attached: Bool
        let lastActivity: Int // tmux's own #{session_activity} clock
    }

    func allClaudeTmuxSessions() async -> [TmuxSessionInfo] {
        let out = await runShellAsync(tmuxPath, ["list-sessions", "-F", "#{session_name} #{session_attached} #{session_activity}"])
        var result: [TmuxSessionInfo] = []
        for line in out.split(separator: "\n") {
            let parts = line.split(separator: " ")
            guard parts.count == 3, parts[0].hasPrefix("claude-"), let activity = Int(parts[2]) else { continue }
            result.append(TmuxSessionInfo(name: String(parts[0]), attached: parts[1] != "0", lastActivity: activity))
        }
        return result
    }

    /// Kills every descendant of `rootPid`, not just the pane's direct
    /// process. MCP watchdog processes (e.g. chrome-devtools-mcp) double-fork
    /// to survive their parent dying, so `tmux kill-session`'s SIGHUP to the
    /// pane alone leaves them running — this walks the full tree itself.
    /// SIGTERM first, SIGKILL any survivor after a grace period, same
    /// escalation as runShell's own timeout handling above.
    private func killProcessTree(rootPid: Int32, table: [Int32: ProcInfo]) async {
        var childrenByParent: [Int32: [Int32]] = [:]
        for (pid, info) in table { childrenByParent[info.ppid, default: []].append(pid) }
        var pids: [Int32] = []
        var stack = [rootPid]
        var visited: Set<Int32> = []
        while let pid = stack.popLast() {
            guard visited.insert(pid).inserted else { continue }
            pids.append(pid)
            stack.append(contentsOf: childrenByParent[pid] ?? [])
        }
        for pid in pids { kill(pid, SIGTERM) }
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        for pid in pids where kill(pid, 0) == 0 { kill(pid, SIGKILL) }
    }

    /// Kills any "claude-*" tmux session that's unattached AND has had no
    /// pane activity for DETACHED_REAP_SECONDS, plus its full process tree
    /// and any status file(s) still pointing at it. Uses tmux's own
    /// #{session_activity} timestamp rather than tracking "since when did we
    /// notice this was detached" ourselves — so a session that was already
    /// stale for days before this code ever ran gets reaped the first time
    /// it's checked, not 30 minutes after the app happens to observe it.
    func reapStaleTmuxSessions() async {
        let sessions = await allClaudeTmuxSessions()
        let now = Int(Date().timeIntervalSince1970)
        let staleNames = Set(sessions.filter { !$0.attached && (now - $0.lastActivity) >= DETACHED_REAP_SECONDS }.map { $0.name })
        guard !staleNames.isEmpty else { return }

        let paneMap = await panes() // pane_id -> (sessionName, pid)
        let table = await processTable()

        for (_, info) in paneMap where staleNames.contains(info.sessionName) {
            await killProcessTree(rootPid: info.pid, table: table)
        }
        for name in staleNames {
            await runShellAsync(tmuxPath, ["kill-session", "-t", name])
        }

        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(atPath: statusDir) else { return }
        let decoder = JSONDecoder()
        for file in files where file.hasSuffix(".json") {
            guard let data = fm.contents(atPath: "\(statusDir)/\(file)"),
                  let status = try? decoder.decode(SessionStatus.self, from: data),
                  let pane = status.tmux_pane, let info = paneMap[pane],
                  staleNames.contains(info.sessionName) else { continue }
            try? fm.removeItem(atPath: "\(statusDir)/\(file)")
        }
    }

    // MARK: - Diff preview

    private static let DIFF_LINE_CAP = 800 // full LCS diff is O(n*m) — skip it past this and just show new content

    // RowView calls diffPreview(for:) straight from `body` — SwiftUI
    // re-evaluates that body on every hover/publish tick, not just when the
    // tool_input actually changes, so without a cache this O(n*m) LCS reran
    // every single render of an expanded "waiting" row. Keyed on the input
    // content itself, not just session_id, so a genuinely new diff (next
    // tool call on the same session) still recomputes.
    private var diffCache: [String: (key: String, diff: DiffPreview?)] = [:]

    /// Edit: diffs old_string/new_string directly. Write: diffs the file's
    /// current on-disk content (still pre-edit — this only ever renders
    /// during "waiting", before the tool runs) against the incoming content,
    /// so approving a Write is no longer a blind trust of a file_path.
    /// NotebookEdit: no old cell source accessible without parsing notebook
    /// JSON, so it's all-added. Anything else: no diff, caller falls back
    /// to plain toolDetail.
    func diffPreview(for session: SessionStatus) -> DiffPreview? {
        guard let input = session.tool_input else { return nil }
        let cacheKey = [
            session.tool ?? "", input.file_path ?? "", input.old_string ?? "",
            input.new_string ?? "", input.content ?? "", input.new_source ?? "",
        ].joined(separator: "\u{1}")
        if let cached = diffCache[session.session_id], cached.key == cacheKey {
            return cached.diff
        }
        let result = Self.computeDiffPreview(session: session, input: input)
        diffCache[session.session_id] = (cacheKey, result)
        return result
    }

    private static func computeDiffPreview(session: SessionStatus, input: SessionStatus.ToolInput) -> DiffPreview? {
        let old: String
        let new: String
        switch session.tool {
        case "Edit":
            guard let o = input.old_string, let n = input.new_string else { return nil }
            old = o; new = n
        case "Write":
            guard let path = input.file_path, let n = input.content else { return nil }
            old = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
            new = n
        case "NotebookEdit":
            guard let n = input.new_source else { return nil }
            old = ""; new = n
        default:
            return nil
        }

        let oldLines = old.components(separatedBy: "\n")
        let newLines = new.components(separatedBy: "\n")
        let raw: [DiffLine]
        if oldLines.count <= DIFF_LINE_CAP && newLines.count <= DIFF_LINE_CAP {
            raw = Self.lineDiff(old: oldLines, new: newLines)
        } else {
            raw = newLines.map { DiffLine(kind: .added, text: $0) }
        }
        return Self.condenseDiff(raw)
    }

    /// Classic LCS-backtrace line diff.
    private static func lineDiff(old: [String], new: [String]) -> [DiffLine] {
        let m = old.count, n = new.count
        guard m > 0 || n > 0 else { return [] }
        var dp = Array(repeating: Array(repeating: 0, count: n + 1), count: m + 1)
        if m > 0 && n > 0 {
            for i in stride(from: m - 1, through: 0, by: -1) {
                for j in stride(from: n - 1, through: 0, by: -1) {
                    dp[i][j] = old[i] == new[j] ? dp[i + 1][j + 1] + 1 : max(dp[i + 1][j], dp[i][j + 1])
                }
            }
        }
        var result: [DiffLine] = []
        var i = 0, j = 0
        while i < m && j < n {
            if old[i] == new[j] {
                result.append(DiffLine(kind: .same, text: old[i])); i += 1; j += 1
            } else if dp[i + 1][j] >= dp[i][j + 1] {
                result.append(DiffLine(kind: .removed, text: old[i])); i += 1
            } else {
                result.append(DiffLine(kind: .added, text: new[j])); j += 1
            }
        }
        while i < m { result.append(DiffLine(kind: .removed, text: old[i])); i += 1 }
        while j < n { result.append(DiffLine(kind: .added, text: new[j])); j += 1 }
        return result
    }

    /// Keeps only changed lines +/- 1 line of context, caps total length —
    /// deliberately not scrollable (see DiffView doc comment). Omitted count
    /// always surfaces when lines are cut, never a silent truncation.
    private static func condenseDiff(_ lines: [DiffLine], contextLines: Int = 1, maxLines: Int = 24) -> DiffPreview {
        var keep = Set<Int>()
        for (i, line) in lines.enumerated() where line.kind != .same {
            let lo = max(0, i - contextLines)
            let hi = min(lines.count - 1, i + contextLines)
            if lo <= hi { for k in lo...hi { keep.insert(k) } }
        }
        var condensed: [DiffLine] = []
        var lastIncluded = -2
        for i in lines.indices where keep.contains(i) {
            if i > lastIncluded + 1 { condensed.append(DiffLine(kind: .contextGap, text: "")) }
            condensed.append(lines[i])
            lastIncluded = i
        }
        if condensed.count > maxLines {
            return DiffPreview(lines: Array(condensed.prefix(maxLines)), omittedCount: condensed.count - maxLines)
        }
        return DiffPreview(lines: condensed, omittedCount: 0)
    }

    // MARK: - Sessions

    func readSessions() -> [(status: SessionStatus, file: String)] {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(atPath: statusDir) else { return [] }
        let decoder = JSONDecoder()
        return files.filter { $0.hasSuffix(".json") }.compactMap { file in
            guard let data = fm.contents(atPath: "\(statusDir)/\(file)") else { return nil }
            guard let status = try? decoder.decode(SessionStatus.self, from: data) else { return nil }
            return (status, file)
        }
    }

    /// Real dialogs (Bash's "1. Yes/2../3.", AskUserQuestion's option and
    /// review/submit screens) all render a "❯ N. ..." numbered-option line
    /// — verified directly against a live session. If that pattern is no
    /// longer in the pane, the dialog's been resolved, regardless of how
    /// much or little time has passed.
    func paneStillShowsPrompt(_ paneId: String) async -> Bool? {
        let out = await runShellAsync(tmuxPath, ["capture-pane", "-t", paneId, "-p"])
        guard !out.isEmpty else { return nil } // pane unreadable — don't guess
        for line in out.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("❯") else { continue }
            let rest = trimmed.dropFirst().trimmingCharacters(in: .whitespaces)
            if let first = rest.first, first.isNumber, rest.contains(".") {
                return true
            }
        }
        return false
    }

    /// Ground truth for "is claude ACTUALLY working right now," read live
    /// from the pane — same approach as paneStillShowsPrompt above. Needed
    /// because interrupting a running tool (Ctrl+C/Esc mid-command) drops
    /// straight back to claude's own idle prompt without firing ANY hook
    /// event — no PostToolUseFailure, no Stop exists for a user-initiated
    /// interrupt — so status-hook.sh never learns the tool stopped and the
    /// last hook-written "working" state freezes forever, even though the
    /// process itself is genuinely alive (see hasLiveClaudeProcess) and just
    /// sitting idle. Verified live against a real interrupted session: the
    /// input box's bare "❯" prompt renders IDENTICALLY whether idle or
    /// working, so that alone can't tell them apart — the actual tell is
    /// the spinner line just above it, e.g. "· Marinating… (1m 41s · ↓ 5.0k
    /// tokens)", present only while a turn is genuinely in flight and absent
    /// the instant it's interrupted or finished. The leading glyph itself
    /// animates frame to frame (caught live: "·" one capture, "✶" the next,
    /// same session, same turn) — anchoring on it caused a false idle
    /// reading mid-turn. Match the stable part instead: the "…" before the
    /// elapsed/token readout in "(...)" that only that status line has.
    func paneShowsActiveSpinner(_ paneId: String) async -> Bool? {
        let out = await runShellAsync(tmuxPath, ["capture-pane", "-t", paneId, "-p"])
        guard !out.isEmpty else { return nil } // pane unreadable — don't guess
        for line in out.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.contains("…"), trimmed.contains("("), trimmed.hasSuffix(")") { return true }
        }
        return false
    }

    /// Parses whatever numbered-option prompt is currently on screen for an
    /// AskUserQuestion pane — real per-question screens ("1. Apple" / "2.
    /// Banana" / ...) and the final review screen ("1. Submit answers" /
    /// "2. Cancel") share the same shape, so one parser covers both. Reads
    /// ground truth from the pane rather than the (stale, whole-question-
    /// set) hook payload.
    /// If `line` is an "N. Label" option line (optionally "❯"-prefixed),
    /// returns (number, label). Shared by the main scan and the
    /// description-line lookahead below, so both agree on what counts as
    /// an option line.
    private func matchOptionLine(_ line: String) -> (number: Int, label: String)? {
        var trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("❯") {
            trimmed = trimmed.dropFirst().trimmingCharacters(in: .whitespaces)
        }
        guard let dotIndex = trimmed.firstIndex(of: ".") else { return nil }
        let numPart = trimmed[trimmed.startIndex..<dotIndex]
        guard !numPart.isEmpty, numPart.allSatisfy({ $0.isNumber }), let num = Int(numPart) else { return nil }
        let label = trimmed[trimmed.index(after: dotIndex)...].trimmingCharacters(in: .whitespaces)
        guard !label.isEmpty else { return nil }
        return (num, label)
    }

    func parseCurrentPrompt(_ paneId: String) async -> ParsedPrompt? {
        let out = await runShellAsync(tmuxPath, ["capture-pane", "-t", paneId, "-p"])
        guard !out.isEmpty else { return nil }
        var lines = out.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)

        // The full pane buffer includes scrollback — AskUserQuestion often
        // generates its own prose that contains a numbered list ("Two
        // options: 1. X 2. Y"), which looks identical to a real option line
        // to the matcher below. Caught live: a commit-message question
        // showed 4 options instead of 2 because earlier prose got parsed
        // right alongside the real dialog. "☐ <header>" is the live box's
        // own header marker (from tool_input's `header` field) and never
        // appears in prose — anchor to its last occurrence and look only at
        // what's after it.
        if let headerIndex = lines.lastIndex(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("☐") }) {
            lines = Array(lines[headerIndex...])
        }

        // A horizontal separator (the box's own border, e.g. between the
        // last real option and "Chat about this") is neither an option nor
        // a description — caught live: it got misread as "Type
        // something."'s description, then wrapped into several visual rows
        // of solid dashes at description font size.
        func isBorderLine(_ line: String) -> Bool {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.count > 3 else { return false }
            return trimmed.allSatisfy { "─-—=".contains($0) }
        }

        var options: [ParsedPrompt.Option] = []
        var firstOptionIndex: Int?
        for (i, line) in lines.enumerated() {
            guard let (num, label) = matchOptionLine(line) else { continue }
            if firstOptionIndex == nil { firstOptionIndex = i }

            // The line right below an option is its description, when
            // present (real, often important context — e.g. "Trace
            // permission/business filtering logic...") — not the same as
            // the "Type something."/"Chat about this" built-ins, which
            // never have one. Must not be dropped just because our first
            // pass only looked at the option line itself.
            var description: String? = nil
            if i + 1 < lines.count {
                let next = lines[i + 1].trimmingCharacters(in: .whitespaces)
                if !next.isEmpty, matchOptionLine(next) == nil, !isBorderLine(next) {
                    description = next
                }
            }
            options.append(ParsedPrompt.Option(number: num, label: label, description: description))
        }
        guard let firstIndex = firstOptionIndex, !options.isEmpty else { return nil }

        // Question text: nearest non-blank line above the first option.
        var question = ""
        var i = firstIndex - 1
        while i >= 0 {
            let t = lines[i].trimmingCharacters(in: .whitespaces)
            if !t.isEmpty { question = t; break }
            i -= 1
        }
        return ParsedPrompt(question: question, options: options)
    }

    /// The live pane capture is truncated by Claude Code's own terminal UI
    /// to fit the pane's column width before we ever see it — caught live:
    /// two genuinely different commit-message options both got cut at the
    /// same character count and rendered visually identical, looking like a
    /// duplicate-parsing bug when it wasn't one. `tool_input.questions` is
    /// the untruncated source of truth for the SAME data; match the parsed
    /// (possibly-truncated) real options against it by count + prefix to
    /// find which question is currently active, then swap in the real full
    /// text — keeping the parsed numbering as-is, since that must exactly
    /// match what tmux send-keys expects (including the "Type
    /// something."/"Chat about this" built-ins, which aren't part of
    /// tool_input at all).
    static func resolveFullText(_ parsed: ParsedPrompt, questions: [SessionStatus.AskQuestion]?) -> ParsedPrompt {
        guard let questions, !questions.isEmpty else { return parsed }

        func isBuiltin(_ label: String) -> Bool {
            isFreeTextOption(label) || label == "Chat about this"
        }
        func cleaned(_ s: String) -> String {
            var t = s
            for suffix in ["...", "…"] where t.hasSuffix(suffix) { t.removeLast(suffix.count) }
            return t
        }

        let realParsed = parsed.options.filter { !isBuiltin($0.label) }
        for q in questions {
            guard q.options.count == realParsed.count else { continue }
            let allMatch = zip(q.options, realParsed).allSatisfy { real, p in
                let c = cleaned(p.label)
                return real.label.hasPrefix(c) || c.hasPrefix(real.label)
            }
            guard allMatch else { continue }

            var rebuilt: [ParsedPrompt.Option] = []
            var realIdx = 0
            for opt in parsed.options {
                if isBuiltin(opt.label) {
                    rebuilt.append(opt)
                } else {
                    let real = q.options[realIdx]
                    rebuilt.append(ParsedPrompt.Option(number: opt.number, label: real.label, description: real.description))
                    realIdx += 1
                }
            }
            return ParsedPrompt(question: q.question, options: rebuilt)
        }
        return parsed
    }

    func selectOption(_ paneId: String, number: Int) async {
        await runShellAsync(tmuxPath, ["send-keys", "-t", paneId, "\(number)"])
        // Collapsing here (like Approve/Deny) was wrong: AskUserQuestion is
        // multi-step, so it forced re-opening the row after every single
        // question in a multi-question flow. Stay expanded — the panel
        // just updates in place to the next question on the next refresh.
        // The original problem this was trying to fix (a real click on
        // "Chat about this" landing 3x as "444") is instead handled by a
        // brief per-row click cooldown in RowView.
    }

    /// Only "Type something." opens an inline text-entry mode. Verified
    /// live that "Chat about this" is NOT the same kind of option, despite
    /// being grouped together visually — pressing its bare digit alone
    /// (before any text is typed) already declines the whole question and
    /// immediately starts a new working turn ("Transmuting…" appeared with
    /// zero typed input). It's a complete one-shot action like a regular
    /// option, not a text-entry launcher — treating it as one (the original
    /// bug) showed a text field that implied you could still type an answer
    /// to the question, when the question had already been declined the
    /// moment you clicked it.
    static func isFreeTextOption(_ label: String) -> Bool {
        label.hasPrefix("Type something")
    }

    func beginFreeText(paneId: String, sessionId: String, number: Int) async {
        await runShellAsync(tmuxPath, ["send-keys", "-t", paneId, "\(number)"])
        textEntryFor = sessionId
    }

    /// Literal flag (`-l`) matters here — without it tmux tries to interpret
    /// the string as key *names*, not literal characters, which is wrong
    /// for arbitrary free text.
    func sendFreeText(paneId: String, text: String) async {
        await runShellAsync(tmuxPath, ["send-keys", "-t", paneId, "-l", text])
        await runShellAsync(tmuxPath, ["send-keys", "-t", paneId, "Enter"])
        textEntryFor = nil
        expandedId = nil
    }

    /// Verified live: Esc from free-text mode declines the *whole*
    /// question, not just this option — not what "go back" means. An arrow
    /// key instead moves off the "Type something" row, discarding whatever
    /// was typed, and returns to normal option selection without declining
    /// anything (confirmed: typed partial text, pressed Up, selected a
    /// different real option, it worked cleanly).
    func cancelFreeText(paneId: String) async {
        await runShellAsync(tmuxPath, ["send-keys", "-t", paneId, "Up"])
        textEntryFor = nil
    }

    /// Drops (and deletes the status file for) any session whose tmux pane
    /// has no attached client anymore — i.e. the window was actually closed,
    /// not just that the pane technically still exists on the tmux server.
    /// Non-tmux sessions can't be confirmed alive at all, so they age out
    /// past a time threshold instead.
    func liveSessions(rawSessions: [(status: SessionStatus, file: String)], paneMap: [String: PaneInfo], attachedSessions: Set<String>, processTable: [Int32: ProcInfo] = [:]) async -> [SessionStatus] {
        let fm = FileManager.default
        let now = Int(Date().timeIntervalSince1970)
        var kept: [(status: SessionStatus, file: String)] = []
        // Subagent-tagged files are handled separately by liveSubagents() —
        // excluded here so they don't collide in the per-pane dedup below
        // (a subagent shares its parent's tmux_pane, so without this filter
        // the pane-reuse dedup could delete one of parent/subagent thinking
        // it found a duplicate occupant of the same pane).
        for (rawStatus, file) in rawSessions where rawStatus.agent_id == nil {
            var status = rawStatus
            if status.state == "waiting" {
                // Once the dialog clears (answered directly in the terminal
                // or via our own Approve/Deny), the tool is now actually
                // *running* — not idle. Reported live 3-4 times: forcing
                // "idle" here raced ahead of the real hook-driven state
                // (the next PreToolUse/Stop hasn't fired yet), so approving
                // something showed idle for a moment while it was still
                // genuinely executing. "working" is the correct default the
                // instant a prompt resolves; a real Stop will still correct
                // it to idle within ~1s if the turn actually did end.
                if let pane = status.tmux_pane, let stillWaiting = await paneStillShowsPrompt(pane) {
                    if !stillWaiting { status.state = "working" }
                } else if (now - status.updated_at) >= WAITING_WATCHDOG_STALE_SECONDS {
                    status.state = "working"
                }
            }
            let isLive: Bool
            if let pane = status.tmux_pane {
                isLive = paneMap[pane].map { attachedSessions.contains($0.sessionName) } ?? false
                // Attachment only proves the pane/window is still open, not
                // that claude is still running in it — see
                // hasLiveClaudeProcess. Skip when processTable is empty
                // (not fetched this tick, see refresh()) so this never
                // fires on stale/incomplete data.
                if isLive, status.state != "idle", !processTable.isEmpty,
                   let info = paneMap[pane], !hasLiveClaudeProcess(panePid: info.pid, table: processTable) {
                    status.state = "idle"
                }
                // Process being alive isn't enough — an interrupted tool
                // (Ctrl+C/Esc) leaves claude alive but back at its own idle
                // prompt with no hook ever firing to say so. Read the
                // spinner ground truth directly; nil (pane unreadable)
                // means don't guess, leave the hook-driven state alone.
                if isLive, status.state == "working", (now - status.updated_at) >= WORKING_SPINNER_GRACE_SECONDS,
                   let activelyWorking = await paneShowsActiveSpinner(pane), !activelyWorking {
                    status.state = "idle"
                }
            } else {
                isLive = (now - status.updated_at) < NON_TMUX_STALE_SECONDS
            }
            if isLive {
                kept.append((status, file))
            } else {
                try? fm.removeItem(atPath: "\(statusDir)/\(file)")
            }
        }

        // A pane gets reused across multiple `claude` invocations over time
        // (restarts, /clear, etc.) — each leaves its own status file behind,
        // all sharing one still-live pane. Only the newest per pane is the
        // actual current occupant; the rest are ghosts from finished runs.
        var newestByPane: [String: (status: SessionStatus, file: String)] = [:]
        var noPane: [(status: SessionStatus, file: String)] = []
        for entry in kept {
            guard let pane = entry.status.tmux_pane else { noPane.append(entry); continue }
            if let existing = newestByPane[pane], existing.status.updated_at >= entry.status.updated_at {
                try? fm.removeItem(atPath: "\(statusDir)/\(entry.file)")
            } else {
                if let existing = newestByPane[pane] {
                    try? fm.removeItem(atPath: "\(statusDir)/\(existing.file)")
                }
                newestByPane[pane] = entry
            }
        }

        return (noPane + Array(newestByPane.values)).map { $0.status }
    }

    /// Subagent-tagged files (Task-tool spawns), grouped by parent
    /// session_id. Dropped if stale (SUBAGENT_STALE_SECONDS — no clean
    /// "done" event exists, see comment above) or orphaned (parent session
    /// no longer live, e.g. its window closed).
    func liveSubagents(rawSessions: [(status: SessionStatus, file: String)], mainSessionIds: Set<String>) -> [String: [SessionStatus]] {
        let fm = FileManager.default
        let now = Int(Date().timeIntervalSince1970)
        var bySession: [String: [SessionStatus]] = [:]
        for (status, file) in rawSessions where status.agent_id != nil {
            let stale = (now - status.updated_at) >= SUBAGENT_STALE_SECONDS
            let orphan = !mainSessionIds.contains(status.session_id)
            if stale || orphan {
                try? fm.removeItem(atPath: "\(statusDir)/\(file)")
                continue
            }
            bySession[status.session_id, default: []].append(status)
        }
        for key in bySession.keys {
            bySession[key]?.sort { $0.updated_at > $1.updated_at }
        }
        return bySession
    }

    func refresh() async {
        // Reading the status dir is a local FS stat, not a subprocess — cheap
        // regardless. But `panes()`/`clientPidBySession()` each fork+exec
        // tmux, with a whole Pipe/thread/semaphore apparatus around it (see
        // runShell above). Doing that twice a second forever, even with zero
        // sessions, was the sustained idle-CPU cost. Read the dir once and
        // skip both subprocess round trips entirely when there's nothing to
        // resolve pane/client info for.
        let rawSessions = readSessions()
        let paneMap: [String: PaneInfo]
        let attachedSessions: Set<String>
        var procTable: [Int32: ProcInfo] = [:]
        if rawSessions.contains(where: { $0.status.agent_id == nil }) {
            paneMap = await panes()
            attachedSessions = Set(await clientPidBySession().keys)
            // Only fork+exec `ps` when some tmux session actually claims to
            // be non-idle — matches the existing idle-CPU discipline above
            // (skip subprocess round trips whenever there's nothing to
            // resolve), and this check only ever matters for non-idle state.
            if rawSessions.contains(where: { $0.status.agent_id == nil && $0.status.state != "idle" }) {
                procTable = await processTable()
            }
        } else {
            paneMap = [:]
            attachedSessions = []
        }
        let newSessions = await liveSessions(rawSessions: rawSessions, paneMap: paneMap, attachedSessions: attachedSessions, processTable: procTable)

        let now = Date()
        for s in newSessions {
            if s.state == "working" {
                if workingSince[s.session_id] == nil { workingSince[s.session_id] = now }
            } else {
                workingSince[s.session_id] = nil
            }
            if s.state == "idle" {
                if idleSinceMap[s.session_id] == nil { idleSinceMap[s.session_id] = now }
            } else {
                idleSinceMap[s.session_id] = nil
            }
        }
        workingSince = workingSince.filter { id, _ in newSessions.contains { $0.session_id == id } }
        idleSinceMap = idleSinceMap.filter { id, _ in newSessions.contains { $0.session_id == id } }

        // Stable manual order, not a priority resort — reordering out from
        // under someone mid-review is dangerous (a new "waiting" arrival
        // jumping to top right as they click Approve is a wrong-row
        // misclick risk) and was, per direct user feedback, "very
        // annoying." New sessions append at the end; drag (moveSession)
        // and pin-to-top are the only things that move a row now.
        let newLiveIds = Set(newSessions.map { $0.session_id })
        manualOrder.removeAll { !newLiveIds.contains($0) }
        for s in newSessions where !manualOrder.contains(s.session_id) {
            manualOrder.append(s.session_id)
        }
        let byId = Dictionary(uniqueKeysWithValues: newSessions.map { ($0.session_id, $0) })
        let orderedIds = manualOrder.filter { pinnedIds.contains($0) } + manualOrder.filter { !pinnedIds.contains($0) }
        sessions = orderedIds.compactMap { byId[$0] }

        pinnedIds = pinnedIds.filter { id in sessions.contains { $0.session_id == id } }
        if let expanded = expandedId, !sessions.contains(where: { $0.session_id == expanded }) {
            expandedId = nil
        }
        if let textEntry = textEntryFor, !sessions.contains(where: { $0.session_id == textEntry }) {
            textEntryFor = nil
        }
        let liveIds = Set(sessions.map { $0.session_id })
        customNames = customNames.filter { liveIds.contains($0.key) }
        diffCache = diffCache.filter { liveIds.contains($0.key) }

        var newParsed: [String: ParsedPrompt] = [:]
        for s in sessions where s.state == "waiting" && s.tool == "AskUserQuestion" {
            if let pane = s.tmux_pane, let parsed = await parseCurrentPrompt(pane) {
                newParsed[s.session_id] = Self.resolveFullText(parsed, questions: s.tool_input?.questions)
            }
        }
        parsedPrompts = newParsed

        subagentsBySession = liveSubagents(rawSessions: rawSessions, mainSessionIds: Set(sessions.map { $0.session_id }))
        if let expandedSub = expandedSubagentId,
           !subagentsBySession.values.contains(where: { $0.contains { $0.id == expandedSub } }) {
            expandedSubagentId = nil
        }

        if aggregateState == "idle" {
            if aggregateIdleSince == nil { aggregateIdleSince = now }
        } else {
            aggregateIdleSince = nil
        }

        await notifyIfNewlyWaiting()
    }
}
